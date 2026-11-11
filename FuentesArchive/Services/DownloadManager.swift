import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum DownloadEvent {
    case progress(Double, Int64, Int64, Int, Int)
    case finished(URL, String)
    case failed(String, Int?)
    case paused
}

final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    static let sessionID = "com.local.fuentesarchive.downloads"
    static let segmentAttempts = 4

    var onEvent: ((String, DownloadEvent) -> Void)?
    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var taskNotes: [Int: TaskNote] = [:]
    private var handledTasks: Set<Int> = []
    private let maxInFlight = 3
    private var backgroundCompletion: (() -> Void)?
    private var sessionEventsFinished = false
    private var minimumGeneration: [String: Int] = [:]
    private let assembly = DispatchQueue(label: "archive.assembly", qos: .utility)

    private struct Job {
        var segments: [URL]
        var ext: String
        var quality: String
        var nextIndex: Int
        var inFlight: Int
        var retries: [Int: Int]
        var retryIndexes: [Int]
        var singleFile: Bool
        var failed: Bool
        var allowCellular: Bool
        var generation: Int
        var busy: Set<Int>
    }

    private struct TaskNote: Codable {
        var videoID: String
        var index: Int?
        var generation: Int
    }

    private struct Manifest: Codable {
        var urls: [String]
        var ext: String
        var quality: String
    }

    func reconnect() {
        if session != nil { return }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// If the system already finished delivering events before the relaunch handler was stored, call it now.
    func setBackgroundCompletion(_ handler: @escaping () -> Void) {
        lock.lock()
        let alreadyDone = sessionEventsFinished
        if !alreadyDone { backgroundCompletion = handler }
        lock.unlock()
        if alreadyDone { handler() }
    }

    struct LiveTask {
        var videoID: String
        var index: Int?
        var generation: Int
    }

    func liveTasks(_ completion: @escaping ([LiveTask]) -> Void) {
        reconnect()
        session.getAllTasks { tasks in
            var live: [LiveTask] = []
            for task in tasks {
                if let note = self.note(for: task) {
                    live.append(LiveTask(videoID: note.videoID, index: note.index, generation: note.generation))
                    self.lock.lock()
                    self.taskNotes[task.taskIdentifier] = note
                    self.lock.unlock()
                }
            }
            let finished = live
            DispatchQueue.main.async { completion(finished) }
        }
    }

    func begin(videoID: String, title: String, variant: Variant, capHeight: Int?, allowCellular: Bool) {
        reconnect()
        lock.lock()
        let generation = (jobs[videoID]?.generation ?? minimumGeneration[videoID] ?? 0) + 1
        minimumGeneration[videoID] = generation
        jobs[videoID] = nil
        lock.unlock()
        let quality = "\(variant.height)p \(variant.kind.uppercased())"
        if variant.kind == "mp4" || variant.kind == "webm" {
            guard let url = URL(string: variant.url) else {
                emit(videoID, .failed("The stream URL was invalid.", nil))
                return
            }
            if !hasRoom(for: variant.size) {
                emit(videoID, .failed(RumbleError.diskSpace.localizedDescription, nil))
                return
            }
            let ext = variant.kind == "webm" ? "webm" : "mp4"
            lock.lock()
            jobs[videoID] = Job(segments: [], ext: ext, quality: quality, nextIndex: 0, inFlight: 1, retries: [:], retryIndexes: [], singleFile: true, failed: false, allowCellular: allowCellular, generation: generation, busy: [])
            lock.unlock()
            startFile(videoID: videoID, url: url, allowCellular: allowCellular, generation: generation)
            return
        }
        guard let playlistURL = URL(string: variant.url) else {
            emit(videoID, .failed("The stream URL was invalid.", nil))
            return
        }
        Task {
            do {
                let client = RumbleClient()
                var playlist = HLSPlaylist.parse(try await client.text(playlistURL), baseURL: playlistURL)
                if playlist.encrypted { throw RumbleError.encrypted }
                if playlist.master {
                    guard let chosen = HLSPlaylist.select(playlist.variants, capHeight: capHeight) else { throw RumbleError.noStream }
                    playlist = HLSPlaylist.parse(try await client.text(chosen.url), baseURL: chosen.url)
                }
                if playlist.encrypted { throw RumbleError.encrypted }
                guard !playlist.segments.isEmpty else { throw RumbleError.noStream }
                let estimate = playlist.segments.reduce(Int64(0)) { $0 + (HLSPlaylist.byteLength(of: $1.url) ?? 0) }
                let bytes = estimate > 0 ? estimate : variant.size
                // Segments and the MP4 exist at the same time until the pieces are deleted.
                if !self.hasRoom(for: bytes * 2) { throw RumbleError.diskSpace }
                let folder = LibraryStore.shared.partialURL(videoID)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls = playlist.segments.map(\.url)
                if let map = playlist.mapURL { urls.insert(map, at: 0) }
                let manifest = Manifest(urls: urls.map(\.absoluteString), ext: "mp4", quality: quality)
                try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
                guard self.isCurrent(videoID, generation) else { return }
                self.enqueueSegments(videoID: videoID, urls: urls, ext: "mp4", quality: quality, allowCellular: allowCellular, generation: generation, alreadyRunning: [])
            } catch {
                self.emit(videoID, .failed(error.localizedDescription, (error as? RumbleError).flatMap(Self.statusCode)))
            }
        }
    }

    @discardableResult
    func resume(videoID: String, allowCellular: Bool, adopted: [LiveTask] = []) -> Bool {
        reconnect()
        let folder = LibraryStore.shared.partialURL(videoID)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            let urls = manifest.urls.compactMap(URL.init(string:))
            guard !urls.isEmpty else { return false }
            let generation = adopted.map(\.generation).max() ?? 1
            let busy = Set(adopted.compactMap(\.index))
            enqueueSegments(videoID: videoID, urls: urls, ext: manifest.ext, quality: manifest.quality, allowCellular: allowCellular, generation: generation, alreadyRunning: busy)
            return true
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("resume.data")) {
            lock.lock()
            jobs[videoID] = Job(segments: [], ext: "mp4", quality: "video", nextIndex: 0, inFlight: 1, retries: [:], retryIndexes: [], singleFile: true, failed: false, allowCellular: allowCellular, generation: 1, busy: [])
            lock.unlock()
            let task = session.downloadTask(withResumeData: data)
            remember(task, TaskNote(videoID: videoID, index: nil, generation: 1))
            task.resume()
            return true
        }
        return false
    }

    func pause(videoID: String) {
        reconnect()
        lock.lock()
        jobs[videoID]?.failed = true
        let generation = jobs[videoID]?.generation ?? -1
        lock.unlock()
        session.getAllTasks { tasks in
            for task in tasks {
                guard let note = self.note(for: task), note.videoID == videoID, note.generation == generation else { continue }
                task.cancel()
            }
        }
        emit(videoID, .paused)
    }

    func cancel(videoID: String) {
        reconnect()
        lock.lock()
        let generation = (jobs[videoID]?.generation ?? minimumGeneration[videoID] ?? 0) + 1
        minimumGeneration[videoID] = generation
        jobs[videoID] = nil
        lock.unlock()
        session.getAllTasks { tasks in
            for task in tasks {
                guard let note = self.note(for: task), note.videoID == videoID, note.generation < generation else { continue }
                task.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let note = note(for: downloadTask), note.generation == generation(of: note.videoID) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let folder = LibraryStore.shared.partialURL(note.videoID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(note.index.map { String(format: "seg-%05d.part", $0) } ?? "file.bin")
        if !(200..<300).contains(status) {
            markHandled(downloadTask.taskIdentifier)
            noteFailure(note, status: status)
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            noteFailure(note, status: nil)
            return
        }
        markHandled(downloadTask.taskIdentifier)
        if note.index == nil {
            finishFile(videoID: note.videoID, temp: dest)
        } else {
            segmentFinished(videoID: note.videoID, index: note.index ?? 0)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let note = note(for: downloadTask), note.index == nil, totalBytesExpectedToWrite > 0 else { return }
        emit(note.videoID, .progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), totalBytesWritten, totalBytesExpectedToWrite, 0, 0))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let note = note(for: task) else { return }
        lock.lock()
        taskNotes[task.taskIdentifier] = nil
        let already = handledTasks.contains(task.taskIdentifier)
        if already { handledTasks.remove(task.taskIdentifier) }
        lock.unlock()
        guard let error, !already else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        if note.index == nil, let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let url = LibraryStore.shared.partialURL(note.videoID).appendingPathComponent("resume.data")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? resume.write(to: url, options: .atomic)
        }
        noteFailure(note, status: (task.response as? HTTPURLResponse)?.statusCode)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        sessionEventsFinished = true
        let handler = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    private func enqueueSegments(videoID: String, urls: [URL], ext: String, quality: String, allowCellular: Bool, generation: Int, alreadyRunning: Set<Int>) {
        guard isCurrent(videoID, generation) else { return }
        var next = 0
        let folder = LibraryStore.shared.partialURL(videoID)
        while next < urls.count && (alreadyRunning.contains(next) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "seg-%05d.part", next)).path)) {
            next += 1
        }
        lock.lock()
        jobs[videoID] = Job(segments: urls, ext: ext, quality: quality, nextIndex: next, inFlight: alreadyRunning.count, retries: [:], retryIndexes: [], singleFile: false, failed: false, allowCellular: allowCellular, generation: generation, busy: alreadyRunning)
        lock.unlock()
        if next >= urls.count {
            assemble(videoID: videoID)
            return
        }
        emit(videoID, .progress(Double(next) / Double(max(urls.count, 1)), 0, 0, next, urls.count))
        fill(videoID: videoID)
    }

    private func fill(videoID: String) {
        lock.lock()
        guard var job = jobs[videoID], !job.failed, !job.singleFile else { lock.unlock(); return }
        var started: [(Int, URL)] = []
        while job.inFlight < maxInFlight {
            let index: Int
            if !job.retryIndexes.isEmpty {
                index = job.retryIndexes.removeFirst()
            } else if job.nextIndex < job.segments.count {
                index = job.nextIndex
                job.nextIndex += 1
            } else {
                break
            }
            if job.busy.contains(index) { continue }
            let file = LibraryStore.shared.partialURL(videoID).appendingPathComponent(String(format: "seg-%05d.part", index))
            if FileManager.default.fileExists(atPath: file.path) { continue }
            job.inFlight += 1
            started.append((index, job.segments[index]))
        }
        jobs[videoID] = job
        let generation = job.generation
        let allowCellular = job.allowCellular
        lock.unlock()
        for (index, url) in started {
            var request = URLRequest(url: url)
            request.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
            request.allowsCellularAccess = allowCellular
            let task = session.downloadTask(with: request)
            remember(task, TaskNote(videoID: videoID, index: index, generation: generation))
            task.resume()
        }
    }

    private func segmentFinished(videoID: String, index: Int) {
        lock.lock()
        guard var job = jobs[videoID], !job.failed else { lock.unlock(); return }
        job.inFlight = max(0, job.inFlight - 1)
        job.busy.remove(index)
        let total = job.segments.count
        jobs[videoID] = job
        lock.unlock()
        let folder = LibraryStore.shared.partialURL(videoID)
        let done = (0..<total).filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "seg-%05d.part", $0)).path) }.count
        emit(videoID, .progress(total == 0 ? 1 : Double(done) / Double(total), 0, 0, done, total))
        if done >= total {
            assemble(videoID: videoID)
        } else {
            fill(videoID: videoID)
        }
    }

    private func noteFailure(_ note: TaskNote, status: Int?) {
        guard note.generation == generation(of: note.videoID) else { return }
        if note.index == nil {
            emit(note.videoID, .failed(status.map { "Download failed with HTTP \($0)." } ?? "The download was interrupted.", status))
            return
        }
        lock.lock()
        guard var job = jobs[note.videoID], !job.failed else { lock.unlock(); return }
        job.inFlight = max(0, job.inFlight - 1)
        let attempts = (job.retries[note.index!] ?? 0) + 1
        job.retries[note.index!] = attempts
        let giveUp = attempts >= Self.segmentAttempts || status == 404 || status == 410
        if giveUp {
            job.failed = true
            jobs[note.videoID] = job
            lock.unlock()
            emit(note.videoID, .failed(status.map { "A piece failed with HTTP \($0)." } ?? "A piece of the video failed.", status))
        } else {
            job.retryIndexes.append(note.index!)
            jobs[note.videoID] = job
            lock.unlock()
            fill(videoID: note.videoID)
        }
    }

    private func assemble(videoID: String) {
        lock.lock()
        guard let job = jobs[videoID], !job.failed else { lock.unlock(); return }
        jobs[videoID]?.failed = true
        let snapshot = job
        lock.unlock()
        assembly.async {
            let folder = LibraryStore.shared.partialURL(videoID)
            let pieces = snapshot.segments.indices.map { folder.appendingPathComponent(String(format: "seg-%05d.part", $0)) }
            guard pieces.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                self.emit(videoID, .failed("Some pieces of the video never arrived.", nil))
                return
            }
            let title = LibraryStore.shared.snapshot().videos[videoID]?.title ?? "video"
            let mp4 = Paths.videoFile(title: title, id: videoID, ext: "mp4")
            do {
                _ = try TSRemuxer.remux(files: pieces, to: mp4)
                try? FileManager.default.removeItem(at: folder)
                self.emit(videoID, .finished(mp4, snapshot.quality))
            } catch {
                try? FileManager.default.removeItem(at: mp4)
                let ts = Paths.videoFile(title: title, id: videoID, ext: "ts")
                do {
                    try self.concatenate(pieces, to: ts)
                    try? FileManager.default.removeItem(at: folder)
                    self.emit(videoID, .finished(ts, snapshot.quality + " (TS)"))
                } catch {
                    self.emit(videoID, .failed("Could not assemble the video file.", nil))
                }
            }
        }
    }

    private func concatenate(_ pieces: [URL], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for piece in pieces {
            let input = try FileHandle(forReadingFrom: piece)
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try input.close()
            try? FileManager.default.removeItem(at: piece)
        }
    }

    private func startFile(videoID: String, url: URL, allowCellular: Bool, generation: Int) {
        var request = URLRequest(url: url)
        request.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        request.allowsCellularAccess = allowCellular
        let task = session.downloadTask(with: request)
        remember(task, TaskNote(videoID: videoID, index: nil, generation: generation))
        task.resume()
    }

    private func finishFile(videoID: String, temp: URL) {
        let title = LibraryStore.shared.snapshot().videos[videoID]?.title ?? "video"
        let ext = jobsLocked(videoID)?.ext ?? "mp4"
        let quality = jobsLocked(videoID)?.quality ?? "video"
        let destination = Paths.videoFile(title: title, id: videoID, ext: ext)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            try? FileManager.default.removeItem(at: LibraryStore.shared.partialURL(videoID))
            lock.lock()
            jobs[videoID] = nil
            lock.unlock()
            emit(videoID, .finished(destination, quality))
        } catch {
            emit(videoID, .failed("Could not move the video into Files.", nil))
        }
    }

    private func isCurrent(_ videoID: String, _ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation >= (minimumGeneration[videoID] ?? 0)
    }

    private func generation(of videoID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs[videoID]?.generation ?? -1
    }

    private func jobsLocked(_ id: String) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]
    }

    private func markHandled(_ identifier: Int) {
        lock.lock()
        handledTasks.insert(identifier)
        lock.unlock()
    }

    private func remember(_ task: URLSessionDownloadTask, _ note: TaskNote) {
        if let data = try? JSONEncoder().encode(note) {
            task.taskDescription = String(decoding: data, as: UTF8.self)
        }
        lock.lock()
        taskNotes[task.taskIdentifier] = note
        lock.unlock()
    }

    private func note(for task: URLSessionTask) -> TaskNote? {
        lock.lock()
        let cached = taskNotes[task.taskIdentifier]
        lock.unlock()
        if let cached { return cached }
        guard let raw = task.taskDescription?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TaskNote.self, from: raw) else { return nil }
        return decoded
    }

    private func hasRoom(for estimate: Int64) -> Bool {
        guard estimate > 0 else { return true }
        let values = try? Paths.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > estimate + 64 * 1024 * 1024
    }

    private func emit(_ id: String, _ event: DownloadEvent) {
        let callback = onEvent
        DispatchQueue.main.async { callback?(id, event) }
    }

    private static func statusCode(_ error: RumbleError) -> Int? {
        if case .http(let status) = error { return status }
        return nil
    }
}

import Foundation

enum DownloadEvent {
    case progress(Double, Int64, Int64, Int, Int)
    case finished(URL, String)
    case failed(String, Int?)
}

final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    static let sessionID = "com.local.fuentesarchive.downloads"

    var onEvent: ((String, DownloadEvent) -> Void)?
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var taskNotes: [Int: TaskNote] = [:]
    private let maxInFlight = 3
    private var cellularAllowed = true

    private struct Job {
        var segments: [URL]
        var ext: String
        var quality: String
        var nextIndex: Int
        var inFlight: Int
        var singleFile: Bool
        var failed: Bool
    }

    private struct TaskNote: Codable {
        var videoID: String
        var index: Int?
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
        configuration.timeoutIntervalForResource = 60 * 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func begin(videoID: String, title: String, variant: Variant, capHeight: Int?, allowCellular: Bool) {
        reconnect()
        cellularAllowed = allowCellular
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
            let destination = Paths.videoFile(title: title, id: videoID, ext: ext)
            lock.lock()
            jobs[videoID] = Job(segments: [], ext: ext, quality: quality, nextIndex: 0, inFlight: 0, singleFile: true, failed: false)
            lock.unlock()
            startFile(videoID: videoID, url: url, destination: destination)
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
                if !self.hasRoom(for: estimate > 0 ? estimate : variant.size) { throw RumbleError.diskSpace }
                let folder = LibraryStore.shared.partialURL(videoID)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls = playlist.segments.map(\.url)
                if let map = playlist.mapURL { urls.insert(map, at: 0) }
                let manifest = Manifest(urls: urls.map(\.absoluteString), ext: playlist.mapURL == nil ? "ts" : "mp4", quality: quality)
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
                self.enqueueSegments(videoID: videoID, urls: urls, ext: manifest.ext, quality: quality)
            } catch {
                self.emit(videoID, .failed(error.localizedDescription, (error as? RumbleError).flatMap(Self.statusCode)))
            }
        }
    }

    @discardableResult
    func resume(videoID: String, title: String, allowCellular: Bool) -> Bool {
        reconnect()
        cellularAllowed = allowCellular
        let folder = LibraryStore.shared.partialURL(videoID)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            let urls = manifest.urls.compactMap(URL.init(string:))
            enqueueSegments(videoID: videoID, urls: urls, ext: manifest.ext, quality: manifest.quality)
            return true
        }
        let resumeURL = folder.appendingPathComponent("resume.data")
        if let data = try? Data(contentsOf: resumeURL) {
            lock.lock()
            jobs[videoID] = Job(segments: [], ext: "mp4", quality: title, nextIndex: 0, inFlight: 1, singleFile: true, failed: false)
            lock.unlock()
            let task = session.downloadTask(withResumeData: data)
            remember(task, TaskNote(videoID: videoID, index: nil))
            task.resume()
            return true
        }
        return false
    }

    func cancel(videoID: String) {
        reconnect()
        session.getAllTasks { tasks in
            for task in tasks where self.note(for: task)?.videoID == videoID {
                task.cancel()
            }
        }
        lock.lock()
        jobs[videoID] = nil
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let note = note(for: downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let folder = LibraryStore.shared.partialURL(note.videoID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest: URL
        if let index = note.index {
            dest = folder.appendingPathComponent(String(format: "seg-%05d.ts", index))
        } else {
            dest = folder.appendingPathComponent("file.bin")
        }
        if !(200..<300).contains(status) {
            emit(note.videoID, .failed("Download failed with HTTP \(status).", status))
            markFailed(note.videoID)
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            emit(note.videoID, .failed("Could not save a downloaded piece.", nil))
            markFailed(note.videoID)
            return
        }
        if note.index == nil {
            finishFile(videoID: note.videoID, temp: dest)
        } else {
            segmentFinished(videoID: note.videoID)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let note = note(for: downloadTask), note.index == nil, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        emit(note.videoID, .progress(fraction, totalBytesWritten, totalBytesExpectedToWrite, 0, 0))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let note = note(for: task) else { return }
        taskNotes[task.taskIdentifier] = nil
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        if let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, note.index == nil {
            let url = LibraryStore.shared.partialURL(note.videoID).appendingPathComponent("resume.data")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? resume.write(to: url, options: .atomic)
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        lock.lock()
        let job = jobs[note.videoID]
        if var job, !job.failed {
            job.inFlight = max(0, job.inFlight - 1)
            job.failed = true
            jobs[note.videoID] = job
        }
        lock.unlock()
        if job?.failed == true || note.index == nil {
            emit(note.videoID, .failed(error.localizedDescription, status))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }

    private func enqueueSegments(videoID: String, urls: [URL], ext: String, quality: String) {
        var next = 0
        let folder = LibraryStore.shared.partialURL(videoID)
        while next < urls.count {
            let file = folder.appendingPathComponent(String(format: "seg-%05d.ts", next))
            if !FileManager.default.fileExists(atPath: file.path) { break }
            next += 1
        }
        lock.lock()
        jobs[videoID] = Job(segments: urls, ext: ext, quality: quality, nextIndex: next, inFlight: 0, singleFile: false, failed: false)
        lock.unlock()
        if next >= urls.count {
            concat(videoID: videoID)
            return
        }
        emit(videoID, .progress(Double(next) / Double(urls.count), 0, 0, next, urls.count))
        fill(videoID: videoID)
    }

    private func fill(videoID: String) {
        lock.lock()
        guard var job = jobs[videoID], !job.failed, !job.singleFile else { lock.unlock(); return }
        var started: [(Int, URL)] = []
        while job.inFlight < maxInFlight && job.nextIndex < job.segments.count {
            let index = job.nextIndex
            let file = LibraryStore.shared.partialURL(videoID).appendingPathComponent(String(format: "seg-%05d.ts", index))
            job.nextIndex += 1
            if FileManager.default.fileExists(atPath: file.path) { continue }
            job.inFlight += 1
            started.append((index, job.segments[index]))
        }
        let done = job.segments.indices.filter { index in
            FileManager.default.fileExists(atPath: LibraryStore.shared.partialURL(videoID).appendingPathComponent(String(format: "seg-%05d.ts", index)).path)
        }.count
        jobs[videoID] = job
        let total = job.segments.count
        lock.unlock()
        emit(videoID, .progress(total == 0 ? 0 : Double(done) / Double(total), 0, 0, done, total))
        for (index, url) in started {
            var request = URLRequest(url: url)
            request.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
            request.allowsCellularAccess = cellularAllowed
            let task = session.downloadTask(with: request)
            remember(task, TaskNote(videoID: videoID, index: index))
            task.resume()
        }
    }

    private func segmentFinished(videoID: String) {
        lock.lock()
        guard var job = jobs[videoID] else { lock.unlock(); return }
        job.inFlight = max(0, job.inFlight - 1)
        jobs[videoID] = job
        let total = job.segments.count
        lock.unlock()
        let done = (0..<total).filter { index in
            FileManager.default.fileExists(atPath: LibraryStore.shared.partialURL(videoID).appendingPathComponent(String(format: "seg-%05d.ts", index)).path)
        }.count
        emit(videoID, .progress(total == 0 ? 1 : Double(done) / Double(total), 0, 0, done, total))
        if done >= total {
            concat(videoID: videoID)
        } else {
            fill(videoID: videoID)
        }
    }

    private func concat(videoID: String) {
        lock.lock()
        let job = jobs[videoID]
        jobs[videoID] = nil
        lock.unlock()
        guard let job else { return }
        let folder = LibraryStore.shared.partialURL(videoID)
        let pieces = job.segments.indices.map { folder.appendingPathComponent(String(format: "seg-%05d.ts", $0)) }
        guard pieces.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            emit(videoID, .failed("Some pieces of the video never arrived.", nil))
            return
        }
        let title = LibraryStore.shared.snapshot().videos[videoID]?.title ?? "video"
        let destination = Paths.videoFile(title: title, id: videoID, ext: job.ext)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: destination)
        } catch { /* no previous file */ }
        do {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            for piece in pieces {
                let input = try FileHandle(forReadingFrom: piece)
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try input.close()
            }
            try output.close()
            try? FileManager.default.removeItem(at: folder)
            emit(videoID, .finished(destination, job.quality))
        } catch {
            emit(videoID, .failed("Could not assemble the video file.", nil))
        }
    }

    private func startFile(videoID: String, url: URL, destination: URL) {
        var request = URLRequest(url: url)
        request.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        request.allowsCellularAccess = cellularAllowed
        let task = session.downloadTask(with: request)
        remember(task, TaskNote(videoID: videoID, index: nil))
        lock.lock()
        taskNotes[task.taskIdentifier]?.index = nil
        lock.unlock()
        task.resume()
    }

    private func finishFile(videoID: String, temp: URL) {
        let title = LibraryStore.shared.snapshot().videos[videoID]?.title ?? "video"
        let ext = jobsLocked(videoID)?.ext ?? "mp4"
        let quality = jobsLocked(videoID)?.quality ?? "video"
        let destination = Paths.videoFile(title: title, id: videoID, ext: ext)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
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

    private func jobsLocked(_ id: String) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]
    }

    private func markFailed(_ id: String) {
        lock.lock()
        jobs[id]?.failed = true
        jobs[id]?.inFlight = 0
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
        lock.lock()
        taskNotes[task.taskIdentifier] = decoded
        lock.unlock()
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

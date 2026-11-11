import Foundation
import Network
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshot = LibraryState()
    @Published private(set) var syncing = false
    @Published private(set) var onWiFi = true
    @Published var sort: LibrarySort = .newest
    @Published var filter: LibraryFilter = .all
    @Published var search = ""

    private let client = RumbleClient()
    private let monitor = NWPathMonitor()
    private var activeSync: Task<Void, Never>?
    private var lastProgressWrite: [String: Date] = [:]

    private init() {
        snapshot = LibraryStore.shared.snapshot()
        LibraryStore.shared.onChange = { [weak self] in
            Task { @MainActor in
                self?.snapshot = LibraryStore.shared.snapshot()
            }
        }
        DownloadManager.shared.onEvent = { [weak self] id, event in
            Task { @MainActor in
                self?.handle(id, event)
            }
        }
        DownloadManager.shared.reconnect()
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                self?.onWiFi = unmetered
                self?.pump()
            }
        }
        monitor.start(queue: DispatchQueue(label: "archive.network"))
        resumeInterrupted()
    }

    var settings: Settings { snapshot.settings }

    func videos() -> [VideoRecord] {
        let ignored = Set(snapshot.ignoredIDs)
        var items = snapshot.videos.values.filter { !ignored.contains($0.id) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter {
                $0.title.lowercased().contains(query) || $0.permalink.lowercased().contains(query)
            }
        }
        switch filter {
        case .all: break
        case .downloading: items = items.filter { $0.status == .downloading || $0.status == .queued }
        case .saved: items = items.filter { $0.status == .downloaded }
        case .failed: items = items.filter { $0.status == .failed }
        case .waiting: items = items.filter { $0.status == .waiting || $0.status == .waitingForWiFi || $0.status == .skipped }
        case .notSaved: items = items.filter { $0.status != .downloaded }
        }
        switch sort {
        case .newest: items.sort { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        case .oldest: items.sort { ($0.published ?? .distantFuture) < ($1.published ?? .distantFuture) }
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .duration: items.sort { ($0.duration ?? 0) > ($1.duration ?? 0) }
        case .size: items.sort { ($0.bytesExpected) > ($1.bytesExpected) }
        case .status: items.sort { $0.status.rawValue < $1.status.rawValue }
        }
        return items
    }

    func video(_ id: String) -> VideoRecord? { snapshot.videos[id] }

    func syncIfStale() {
        let last = snapshot.lastSync ?? .distantPast
        if Date().timeIntervalSince(last) < 90, snapshot.baselineReady { return }
        sync(trigger: "launch")
    }

    func sync(trigger: String) {
        guard activeSync == nil, !syncing else { return }
        activeSync = Task { [weak self] in
            await self?.performSync(trigger: trigger)
            await MainActor.run { self?.activeSync = nil }
        }
    }

    func syncAndWait(trigger: String) async {
        if syncing || activeSync != nil {
            if let activeSync { await activeSync.value }
            return
        }
        await performSync(trigger: trigger)
    }

    func download(_ id: String, resetAttempts: Bool = false) {
        guard let record = snapshot.videos[id] else { return }
        guard record.disposition == .downloadable else { return }
        LibraryStore.shared.update { state in
            guard var record = state.videos[id] else { return }
            if resetAttempts { record.attemptCount = 0 }
            record.errorMessage = nil
            record.status = .queued
            record.updatedAt = Date()
            state.videos[id] = record
        }
        pump()
    }

    func downloadNewest(_ count: Int) {
        let ids = videos()
            .filter { $0.disposition == .downloadable && $0.status != .downloaded && $0.status != .downloading }
            .prefix(count)
            .map(\.id)
        ids.forEach { download($0, resetAttempts: true) }
        log(source: "manual", message: "Queued \(ids.count) videos from the catalog.", level: "info")
    }

    func deleteFile(_ id: String) {
        guard let record = snapshot.videos[id] else { return }
        DownloadManager.shared.cancel(videoID: id)
        if let path = record.relativePath {
            try? FileManager.default.removeItem(at: LibraryStore.shared.fileURL(relativePath: path))
        }
        try? FileManager.default.removeItem(at: LibraryStore.shared.partialURL(id))
        LibraryStore.shared.update { state in
            state.videos[id]?.status = .catalogued
            state.videos[id]?.relativePath = nil
            state.videos[id]?.progress = 0
            state.videos[id]?.bytesWritten = 0
            state.videos[id]?.errorMessage = nil
            state.videos[id]?.updatedAt = Date()
        }
    }

    func hide(_ id: String) {
        deleteFile(id)
        LibraryStore.shared.update { state in
            if !state.ignoredIDs.contains(id) { state.ignoredIDs.append(id) }
            state.videos[id] = nil
        }
    }

    func restoreHidden() {
        LibraryStore.shared.update { $0.ignoredIDs = [] }
        sync(trigger: "restore")
    }

    func deleteAllFiles() {
        for id in snapshot.videos.keys { deleteFile(id) }
    }

    func updateSettings(_ body: (inout Settings) -> Void) {
        LibraryStore.shared.update { body(&$0.settings) }
        pump()
    }

    func dismissIntro() {
        updateSettings { $0.dismissedIntro = true }
    }

    func exportFeed() -> URL? {
        let items = videos().map(listed)
        let xml = FeedBuilder.rss(items: items, generatedAt: ISO8601DateFormatter().string(from: Date()))
        let url = Paths.documents.appendingPathComponent("nickjfuentes-videos.xml")
        do {
            try xml.data(using: .utf8)?.write(to: url, options: .atomic)
            log(source: "rss", message: "Wrote a local Videos-tab feed to Files.", level: "info")
            return url
        } catch {
            log(source: "rss", message: error.localizedDescription, level: "error")
            return nil
        }
    }

    func clearLog() {
        LibraryStore.shared.update { $0.log = [] }
    }

    func storageBytes() -> Int64 {
        snapshot.videos.values.reduce(0) { total, record in
            guard let path = record.relativePath else { return total }
            let url = LibraryStore.shared.fileURL(relativePath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    func performSync(trigger: String) async {
        syncing = true
        defer { syncing = false }
        log(source: trigger, message: "Looking for new videos on the Videos tab.", level: "info")
        let previouslyKnown = Set(snapshot.videos.keys)
        let baseline = !snapshot.baselineReady
        var pageURL = Channel.videosPage
        var pageIndex = 0
        var maxPublished: Date?
        let pageLimit = min(10, max(1, snapshot.settings.maxPages))
        do {
            while pageIndex < pageLimit {
                if Task.isCancelled { return }
                let html = try await client.fetchListing(pageURL)
                let page = ListingParser.parse(html: html, pageURL: pageURL)
                if page.challenged { throw RumbleError.cloudflare }
                if page.items.isEmpty { break }
                let watermark = snapshot.watermark.map { ISO8601DateFormatter().string(from: $0) }
                for item in page.items where !snapshot.ignoredIDs.contains(item.id) {
                    let isNew = snapshot.videos[item.id] == nil
                    let previous = snapshot.videos[item.id]
                    upsert(item)
                    if item.disposition == .downloadable, let date = AutoQueue.parse(item.published ?? "") {
                        maxPublished = max(maxPublished ?? date, date)
                    }
                    if AutoQueue.shouldQueue(
                        isNew: isNew,
                        pageIndex: pageIndex,
                        published: item.published,
                        disposition: item.disposition,
                        baseline: baseline,
                        autoOn: snapshot.settings.autoDownload,
                        watermark: watermark
                    ) {
                        download(item.id)
                    } else if previous?.status == .waiting, item.disposition == .downloadable, !baseline, snapshot.settings.autoDownload {
                        download(item.id)
                    }
                }
                let knownPage = page.items.allSatisfy { previouslyKnown.contains($0.id) }
                pageIndex += 1
                guard let next = page.nextURL, !knownPage else { break }
                pageURL = next
            }
            LibraryStore.shared.update { state in
                if !state.baselineReady {
                    state.baselineReady = true
                    state.watermark = max(maxPublished ?? Date(), Date())
                } else if let maxPublished {
                    state.watermark = max(state.watermark ?? maxPublished, maxPublished)
                }
                state.lastSync = Date()
                state.lastError = nil
            }
            if baseline, snapshot.settings.backfillCount > 0 {
                downloadNewest(snapshot.settings.backfillCount)
            }
            retryDue()
            log(source: trigger, message: "Sync finished.", level: "info")
        } catch {
            LibraryStore.shared.update { $0.lastError = error.localizedDescription }
            log(source: trigger, message: error.localizedDescription, level: "error")
        }
        BackgroundScheduler.scheduleAll()
    }

    private func upsert(_ item: ListedVideo) {
        LibraryStore.shared.update { state in
            var record = state.videos[item.id] ?? VideoRecord(
                id: item.id,
                permalink: item.permalink,
                title: item.title,
                watchURL: item.watch,
                thumbnailURL: item.thumb,
                published: AutoQueue.parse(item.published ?? ""),
                duration: item.duration,
                views: item.views,
                channelName: item.channel,
                disposition: item.disposition,
                status: status(for: item.disposition),
                progress: 0,
                bytesWritten: 0,
                bytesExpected: 0,
                relativePath: nil,
                qualityLabel: nil,
                errorMessage: nil,
                attemptCount: 0,
                nextRetryAt: nil,
                segmentTotal: 0,
                segmentDone: 0,
                updatedAt: Date()
            )
            record.title = item.title
            record.permalink = item.permalink
            record.watchURL = item.watch
            record.thumbnailURL = item.thumb ?? record.thumbnailURL
            record.published = AutoQueue.parse(item.published ?? "") ?? record.published
            record.duration = item.duration ?? record.duration
            record.views = item.views ?? record.views
            record.channelName = item.channel ?? record.channelName
            record.disposition = item.disposition
            if record.status == .catalogued || record.status == .waiting || record.status == .skipped {
                record.status = status(for: item.disposition)
            }
            record.updatedAt = Date()
            state.videos[item.id] = record
        }
    }

    private func status(for disposition: Disposition) -> DownloadStatus {
        switch disposition {
        case .downloadable: return .catalogued
        case .members: return .skipped
        case .premiere, .processing: return .waiting
        case .live, .short, .ignored: return .skipped
        }
    }

    private func pump() {
        let allow = !snapshot.settings.wifiOnly || onWiFi
        for record in snapshot.videos.values {
            if record.status == .waitingForWiFi, allow {
                start(record.id)
            } else if record.status == .queued {
                start(record.id)
            }
        }
    }

    private func start(_ id: String) {
        guard var record = snapshot.videos[id], record.disposition == .downloadable else { return }
        let allow = !snapshot.settings.wifiOnly || onWiFi
        if !allow {
            LibraryStore.shared.update { state in
                state.videos[id]?.status = .waitingForWiFi
                state.videos[id]?.errorMessage = "Waiting for Wi-Fi."
            }
            return
        }
        if record.status == .downloading { return }
        LibraryStore.shared.update { state in
            state.videos[id]?.status = .downloading
            state.videos[id]?.errorMessage = nil
            state.videos[id]?.updatedAt = Date()
        }
        record.status = .downloading
        let cap = snapshot.settings.quality.capHeight
        Task {
            do {
                guard let watch = URL(string: record.watchURL) else { throw RumbleError.noStream }
                let variant = try await client.resolve(watch: watch, capHeight: cap)
                DownloadManager.shared.begin(
                    videoID: id,
                    title: record.title,
                    variant: variant,
                    capHeight: cap,
                    allowCellular: !self.snapshot.settings.wifiOnly
                )
                LibraryStore.shared.update { state in
                    state.videos[id]?.qualityLabel = "\(variant.height)p"
                    state.videos[id]?.bytesExpected = variant.size
                }
            } catch let error as RumbleError {
                if case .members = error {
                    LibraryStore.shared.update { state in
                        state.videos[id]?.status = .skipped
                        state.videos[id]?.disposition = .members
                        state.videos[id]?.errorMessage = error.localizedDescription
                    }
                } else {
                    fail(id, message: error.localizedDescription, status: nil)
                }
            } catch {
                fail(id, message: error.localizedDescription, status: nil)
            }
        }
    }

    private func handle(_ id: String, _ event: DownloadEvent) {
        switch event {
        case let .progress(fraction, written, expected, done, total):
            let now = Date()
            if fraction < 0.999, let last = lastProgressWrite[id], now.timeIntervalSince(last) < 0.5 { return }
            lastProgressWrite[id] = now
            LibraryStore.shared.update { state in
                state.videos[id]?.status = .downloading
                state.videos[id]?.progress = fraction
                if written > 0 { state.videos[id]?.bytesWritten = written }
                if expected > 0 { state.videos[id]?.bytesExpected = expected }
                state.videos[id]?.segmentDone = done
                state.videos[id]?.segmentTotal = total
            }
        case let .finished(url, quality):
            let relative = "Videos/" + url.lastPathComponent
            LibraryStore.shared.update { state in
                state.videos[id]?.status = .downloaded
                state.videos[id]?.progress = 1
                state.videos[id]?.relativePath = relative
                state.videos[id]?.qualityLabel = quality
                state.videos[id]?.errorMessage = nil
                state.videos[id]?.attemptCount = 0
                state.videos[id]?.updatedAt = Date()
            }
            log(source: "download", message: "Saved \(snapshot.videos[id]?.title ?? id).", level: "info")
            if snapshot.settings.notify {
                NotificationService.notify(title: "Video saved", body: snapshot.videos[id]?.title ?? "Download finished")
            }
            if snapshot.settings.saveToPhotos {
                PhotosSaver.save(url) { result in
                    Task { @MainActor in
                        if case let .failure(error) = result {
                            self.log(source: "photos", message: error.localizedDescription, level: "error")
                        }
                    }
                }
            }
        case let .failed(message, status):
            fail(id, message: message, status: status)
        }
    }

    private func fail(_ id: String, message: String, status: Int?) {
        LibraryStore.shared.update { state in
            guard var record = state.videos[id] else { return }
            record.attemptCount += 1
            record.errorMessage = message
            if RetryPolicy.shouldRetry(httpStatus: status, attempt: record.attemptCount) {
                record.status = .failed
                record.nextRetryAt = Date().addingTimeInterval(RetryPolicy.delay(for: record.attemptCount - 1))
            } else {
                record.status = .failed
                record.nextRetryAt = nil
            }
            record.updatedAt = Date()
            state.videos[id] = record
        }
        log(source: "download", message: "\(snapshot.videos[id]?.title ?? id): \(message)", level: "error")
    }

    private func retryDue() {
        let now = Date()
        for record in snapshot.videos.values where record.status == .failed {
            if let when = record.nextRetryAt, when <= now {
                download(record.id)
            }
        }
    }

    private func resumeInterrupted() {
        for record in snapshot.videos.values where record.status == .downloading {
            let resumed = DownloadManager.shared.resume(videoID: record.id, title: record.title, allowCellular: !snapshot.settings.wifiOnly)
            if !resumed {
                LibraryStore.shared.update { $0.videos[record.id]?.status = .queued }
            }
        }
        pump()
    }

    private func listed(_ record: VideoRecord) -> ListedVideo {
        ListedVideo(
            id: record.id,
            permalink: record.permalink,
            title: record.title,
            watch: record.watchURL,
            thumb: record.thumbnailURL,
            published: record.published.map { ISO8601DateFormatter().string(from: $0) },
            duration: record.duration,
            views: record.views,
            disposition: record.disposition,
            channel: record.channelName,
            channelURL: Channel.videosPage.absoluteString
        )
    }

    private func log(source: String, message: String, level: String) {
        LibraryStore.shared.update { state in
            state.log.append(LogEntry(id: UUID().uuidString, date: Date(), source: source, message: message, level: level))
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, title, duration, size, status
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .title: return "Title"
        case .duration: return "Duration"
        case .size: return "Size"
        case .status: return "Status"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, downloading, saved, failed, waiting, notSaved
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Active"
        case .saved: return "Saved"
        case .failed: return "Failed"
        case .waiting: return "Waiting"
        case .notSaved: return "Not saved"
        }
    }
}

enum NotificationService {
    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum PhotosSaver {
    static func save(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PhotosLibrary.addVideo(url, completion: completion)
    }
}

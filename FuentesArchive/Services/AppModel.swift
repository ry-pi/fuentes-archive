import Foundation
import Network
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshot = LibraryState()
    @Published private(set) var syncing = false
    @Published private(set) var onWiFi = false
    @Published var sort: LibrarySort = .newest
    @Published var filter: LibraryFilter = .all
    @Published var search = ""

    private let client = RumbleClient()
    private let monitor = NWPathMonitor()
    private var activeSync: Task<Void, Never>?
    private var lastProgressWrite: [String: Date] = [:]
    private var lastDebugSample: [String: Date] = [:]
    private var pathReady = false
    private var retryWork: DispatchWorkItem?

    private init() {
        snapshot = LibraryStore.shared.snapshot()
        LibraryStore.shared.onChange = { [weak self] in
            let apply = {
                self?.snapshot = LibraryStore.shared.snapshot()
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(apply)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(apply) }
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
                guard let self else { return }
                let first = !self.pathReady
                self.pathReady = true
                self.onWiFi = unmetered
                if first {
                    self.resumeInterrupted()
                } else if self.snapshot.settings.wifiOnly && !unmetered {
                    self.pauseForNetwork()
                } else {
                    self.pump()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "archive.network"))
        scheduleRetries()
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
            record.request = nil
            record.status = .queued
            record.updatedAt = Date()
            state.videos[id] = record
        }
        pump()
    }

    func download(_ id: String, choice: DownloadChoice) {
        guard let record = snapshot.videos[id], record.disposition == .downloadable else { return }
        DownloadManager.shared.cancel(videoID: id)
        LibraryStore.shared.update { state in
            guard var record = state.videos[id] else { return }
            record.request = DownloadRequest(
                url: choice.url,
                kind: choice.kind,
                height: choice.height,
                audioOnly: choice.audioOnly,
                container: choice.container,
                bytes: choice.bytes,
                label: choice.title + " · " + choice.detail
            )
            record.qualityLabel = record.request?.label
            record.bytesExpected = choice.bytes
            record.errorMessage = nil
            record.attemptCount = 0
            record.progress = 0
            record.bytesWritten = 0
            record.segmentDone = 0
            record.segmentTotal = 0
            record.status = .queued
            record.updatedAt = Date()
            state.videos[id] = record
        }
        pump()
    }

    var activeDownloadCount: Int {
        snapshot.videos.values.filter { $0.status == .downloading || $0.status == .queued }.count
    }

    func downloadRows() -> [VideoRecord] {
        let order: [DownloadStatus] = [.downloading, .queued, .paused, .waitingForWiFi, .failed, .downloaded]
        return snapshot.videos.values.filter { order.contains($0.status) }.sorted { left, right in
            let leftIndex = order.firstIndex(of: left.status) ?? 0
            let rightIndex = order.firstIndex(of: right.status) ?? 0
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return left.updatedAt > right.updatedAt
        }
    }

    func pauseDownload(_ id: String) {
        LibraryStore.shared.update { state in
            guard var record = state.videos[id] else { return }
            guard record.status == .downloading || record.status == .queued || record.status == .waitingForWiFi else { return }
            record.status = .paused
            record.bytesPerSecond = 0
            record.errorMessage = nil
            record.updatedAt = Date()
            state.videos[id] = record
        }
        DownloadManager.shared.pause(videoID: id, user: true)
    }

    func resumeDownload(_ id: String) {
        guard let record = snapshot.videos[id] else { return }
        guard record.status == .paused || record.status == .waitingForWiFi || record.status == .failed else { return }
        if settings.wifiOnly && pathReady && !onWiFi {
            LibraryStore.shared.update { state in
                guard var record = state.videos[id] else { return }
                record.status = .waitingForWiFi
                record.errorMessage = "Waiting for Wi-Fi."
                record.updatedAt = Date()
                state.videos[id] = record
            }
            return
        }
        LibraryStore.shared.update { state in
            guard var record = state.videos[id] else { return }
            record.status = .downloading
            record.errorMessage = nil
            record.updatedAt = Date()
            state.videos[id] = record
        }
        let resumed = DownloadManager.shared.resume(videoID: id, allowCellular: !settings.wifiOnly)
        if !resumed {
            LibraryStore.shared.update { state in
                guard var record = state.videos[id] else { return }
                record.status = .queued
                state.videos[id] = record
            }
            start(id)
        }
    }

    func offers(for video: VideoRecord) async throws -> [DownloadChoice] {
        guard let watch = URL(string: video.watchURL) else { throw RumbleError.noStream }
        let variants = try await client.variants(for: watch)
        var choices = DownloadOffers.build(variants: variants, duration: video.duration)
        for index in choices.indices where choices[index].estimated && DownloadOffers.isDirectFile(choices[index].url) {
            let choice = choices[index]
            guard let url = URL(string: choice.url) else { continue }
            if let length = await client.contentLength(url) {
                choices[index] = DownloadOffers.applyingPlaylistBytes(choice, playlistBytes: length)
            }
        }
        let summary = choices.map { item in
            let mark = item.estimated ? "~" : ""
            return "\(item.title) \(item.detail) \(item.kind) \(mark)\(item.bytes)"
        }.joined(separator: "; ")
        DebugLog.event("formats \(video.id) \(summary)")
        return choices
    }

    func pauseAll() {
        for record in snapshot.videos.values where record.status == .downloading || record.status == .queued {
            pauseDownload(record.id)
        }
    }

    func resumeAll() {
        let ids = snapshot.videos.values.filter { $0.status == .paused || $0.status == .waitingForWiFi }.map(\.id)
        for id in ids { resumeDownload(id) }
    }

    func stopDownload(_ id: String) {
        let saved = snapshot.videos[id]?.relativePath
        DownloadManager.shared.cancel(videoID: id)
        try? FileManager.default.removeItem(at: LibraryStore.shared.partialURL(id))
        LibraryStore.shared.update { state in
            guard var record = state.videos[id] else { return }
            record.progress = saved == nil ? 0 : 1
            record.bytesWritten = 0
            record.bytesPerSecond = 0
            record.segmentDone = 0
            record.segmentTotal = 0
            record.errorMessage = nil
            record.status = saved == nil ? .catalogued : .downloaded
            record.updatedAt = Date()
            state.videos[id] = record
        }
    }

    func downloadNewest(_ count: Int) {
        let ignored = Set(snapshot.ignoredIDs)
        let ids = snapshot.videos.values
            .filter { !ignored.contains($0.id) && $0.disposition == .downloadable && $0.status != .downloaded && $0.status != .downloading }
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
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
            state.videos[id]?.segmentDone = 0
            state.videos[id]?.segmentTotal = 0
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
        if snapshot.settings.wifiOnly && pathReady && !onWiFi {
            pauseForNetwork()
        } else {
            pump()
        }
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
        let baseline = !snapshot.baselineReady
        DebugLog.event("sync \(trigger) start baseline=\(baseline)")
        var pageURL = Channel.videosPage
        var maxPublished: Date?
        let pageLimit = min(10, max(1, snapshot.settings.maxPages))
        let known = Set(snapshot.knownIDs)
        do {
            var pages: [[ListedVideo]] = []
            while pages.count < pageLimit {
                if Task.isCancelled { return }
                let html = try await client.fetchListing(pageURL)
                let page = ListingParser.parse(html: html, pageURL: pageURL)
                if page.challenged { throw RumbleError.cloudflare }
                if page.items.isEmpty { break }
                pages.append(page.items)
                let seen = known.union(pages.dropLast().flatMap { $0.map(\.id) })
                if page.items.allSatisfy({ seen.contains($0.id) }) { break }
                guard let next = page.nextURL else { break }
                pageURL = next
            }
            let decision = AutoQueue.plan(
                pages: pages.map { $0.map { SyncVideo(id: $0.id, disposition: $0.disposition) } },
                known: known,
                baseline: baseline,
                autoOn: snapshot.settings.autoDownload,
                maxPages: pageLimit
            )
            let ignored = Set(snapshot.ignoredIDs)
            for item in pages.flatMap({ $0 }) where !ignored.contains(item.id) {
                let previous = snapshot.videos[item.id]
                upsert(item)
                if item.disposition == .downloadable, let date = AutoQueue.parse(item.published ?? "") {
                    maxPublished = max(maxPublished ?? date, date)
                }
                if previous?.status == .waiting, item.disposition == .downloadable, !baseline, snapshot.settings.autoDownload,
                   !decision.queue.contains(item.id) {
                    download(item.id)
                }
            }
            for id in decision.queue where !ignored.contains(id) {
                download(id)
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
            DebugLog.event("sync \(trigger) finished pages=\(pages.count) queued=\(decision.queue.count)")
        } catch {
            LibraryStore.shared.update { $0.lastError = error.localizedDescription }
            log(source: trigger, message: error.localizedDescription, level: "error")
            DebugLog.event("sync \(trigger) error \(error.localizedDescription)")
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
            if !state.knownIDs.contains(item.id) {
                state.knownIDs.append(item.id)
            }
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
        guard pathReady else { return }
        let allow = !snapshot.settings.wifiOnly || onWiFi
        let candidates = snapshot.videos.values.filter {
            ($0.status == .waitingForWiFi && allow) || $0.status == .queued
        }.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        for record in candidates {
            let active = snapshot.videos.values.filter { $0.status == .downloading }.count
            if active >= 2 { break }
            start(record.id)
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
        DownloadManager.shared.allowStart(id)
        let cap = snapshot.settings.quality.capHeight
        let request = record.request
        Task {
            do {
                let variant: Variant
                let audioOnly: Bool
                let container: String
                if let request {
                    variant = Variant(kind: request.kind, height: request.height, bitrate: 0, size: request.bytes, url: request.url, timeline: false, audioOnly: request.audioOnly)
                    audioOnly = request.audioOnly
                    container = request.container
                } else {
                    guard let watch = URL(string: record.watchURL) else { throw RumbleError.noStream }
                    variant = try await client.resolve(watch: watch, capHeight: cap)
                    audioOnly = false
                    container = "mp4"
                }
                guard self.snapshot.videos[id]?.status != .paused else { return }
                DebugLog.event("chosen \(id) \(variant.kind) \(variant.height)p bytes=\(variant.size) direct=\(DownloadOffers.isDirectFile(variant.url))")
                DownloadManager.shared.begin(
                    videoID: id,
                    title: record.title,
                    variant: variant,
                    capHeight: cap,
                    allowCellular: !self.snapshot.settings.wifiOnly,
                    audioOnly: audioOnly,
                    container: container
                )
                let label = request?.label ?? "\(variant.height)p"
                let bytes = request?.bytes ?? variant.size
                LibraryStore.shared.update { state in
                    guard var record = state.videos[id] else { return }
                    if record.qualityLabel == nil { record.qualityLabel = label }
                    if bytes > 0 { record.bytesExpected = bytes }
                    state.videos[id] = record
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
                guard var record = state.videos[id] else { return }
                if record.status == .paused { return }
                let previousBytes = record.bytesWritten
                let elapsed = Date().timeIntervalSince(record.updatedAt)
                record.status = .downloading
                record.progress = fraction
                if written > 0 { record.bytesWritten = written }
                if expected > 0 { record.bytesExpected = expected }
                record.segmentDone = done
                record.segmentTotal = total
                if written > previousBytes, elapsed > 0.3 {
                    record.bytesPerSecond = Double(written - previousBytes) / elapsed
                }
                record.updatedAt = Date()
                state.videos[id] = record
            }
            if written > 0, lastDebugSample[id].map({ now.timeIntervalSince($0) >= 3 }) ?? true {
                lastDebugSample[id] = now
                let megabytes = (snapshot.videos[id]?.bytesPerSecond ?? 0) / (1024 * 1024)
                DebugLog.detail(String(format: "progress %@ %.2f MB/s written %lld/%lld segments %d/%d", id, megabytes, written, expected, done, total))
            }
        case let .finished(url, quality):
            let relative = "Videos/" + url.lastPathComponent
            LibraryStore.shared.update { state in
                guard var record = state.videos[id] else { return }
                record.status = .downloaded
                record.progress = 1
                record.relativePath = relative
                record.qualityLabel = quality
                record.errorMessage = nil
                record.attemptCount = 0
                record.segmentDone = record.segmentTotal
                record.updatedAt = Date()
                state.videos[id] = record
            }
            log(source: "download", message: "Saved \(snapshot.videos[id]?.title ?? id).", level: "info")
            DebugLog.event("download finished \(id) \(quality) \(url.lastPathComponent)")
            pump()
            if snapshot.settings.notify {
                NotificationService.notify(title: "Video saved", body: snapshot.videos[id]?.title ?? "Download finished")
            }
            if snapshot.settings.saveToPhotos {
                if url.pathExtension.lowercased() == "mp4" {
                    PhotosSaver.save(url) { result in
                        Task { @MainActor in
                            if case let .failure(error) = result {
                                self.log(source: "photos", message: error.localizedDescription, level: "error")
                            }
                        }
                    }
                } else {
                    log(source: "photos", message: "Photos only receives an MP4. This copy is in Files and plays in the app.", level: "error")
                }
            }
        case let .paused(user):
            LibraryStore.shared.update { state in
                guard var record = state.videos[id] else { return }
                if record.status == .paused { return }
                if user {
                    record.status = .paused
                    record.errorMessage = nil
                } else if record.status == .downloading || record.status == .queued {
                    record.status = .waitingForWiFi
                    record.errorMessage = "Waiting for Wi-Fi."
                } else {
                    return
                }
                record.bytesPerSecond = 0
                record.updatedAt = Date()
                state.videos[id] = record
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
        DebugLog.event("download error \(id) \(message)")
        scheduleRetries()
        pump()
    }

    private func retryDue() {
        let now = Date()
        for record in snapshot.videos.values where record.status == .failed {
            if let when = record.nextRetryAt, when <= now {
                download(record.id)
            }
        }
    }

    private func pauseForNetwork() {
        for record in snapshot.videos.values where record.status == .downloading || record.status == .queued {
            DownloadManager.shared.pause(videoID: record.id, user: false)
        }
    }

    private func resumeInterrupted() {
        let allow = !snapshot.settings.wifiOnly || onWiFi
        DownloadManager.shared.liveTasks { [weak self] live in
            Task { @MainActor in
                guard let self else { return }
                let grouped = Dictionary(grouping: live, by: \.videoID)
                for record in self.snapshot.videos.values where record.status == .downloading {
                    if !allow {
                        if grouped[record.id] == nil {
                            LibraryStore.shared.update { $0.videos[record.id]?.status = .waitingForWiFi }
                        }
                        continue
                    }
                    if !DownloadManager.shared.resume(videoID: record.id, allowCellular: !self.snapshot.settings.wifiOnly, adopted: grouped[record.id] ?? []) {
                        LibraryStore.shared.update { $0.videos[record.id]?.status = .queued }
                    }
                }
                self.pump()
            }
        }
    }

    private func scheduleRetries() {
        retryWork?.cancel()
        let next = snapshot.videos.values.compactMap { record -> Date? in
            guard record.status == .failed, let when = record.nextRetryAt else { return nil }
            return when
        }.min()
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.retryDue() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow), execute: work)
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

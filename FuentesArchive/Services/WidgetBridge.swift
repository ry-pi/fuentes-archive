import ActivityKit
import Foundation
import WidgetKit

final class WidgetBridge {
    static let shared = WidgetBridge()
    private var lastSnapshot = Date.distantPast
    private var lastActivity = Date.distantPast
    private var wasDownloading = false
    private var snapshotGeneration = 0
    private let thumbs = URLSession(configuration: .ephemeral)

    func handle(videoID: String, event: DownloadEvent) {
        switch event {
        case .finished, .failed, .paused:
            refreshSnapshot(force: true)
            syncActivity(force: true)
            wasDownloading = LibraryStore.shared.snapshot().videos.values.contains { $0.status == .downloading }
        case .progress:
            let starting = !wasDownloading
            wasDownloading = true
            refreshSnapshot(force: starting)
            syncActivity(force: starting)
        }
    }

    func refreshSnapshot(force: Bool) {
        if !force, Date().timeIntervalSince(lastSnapshot) < 8 { return }
        lastSnapshot = Date()
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let state = LibraryStore.shared.snapshot()
        DispatchQueue.global(qos: .utility).async {
            let footprint = DiskUsage.current()
            let saved = state.videos.values
                .filter { $0.status == .downloaded && $0.relativePath != nil }
                .sorted { ($0.published ?? $0.updatedAt) > ($1.published ?? $1.updatedAt) }
            let active = state.videos.values
                .filter { $0.status == .downloading }
                .sorted { $0.updatedAt > $1.updatedAt }
            let queued = state.videos.values.filter { $0.status == .queued || $0.status == .downloading }
            let current = active.first
            let root = AppGroup.containerURL()
            let videos = saved.prefix(8).map { record in
                SnapshotVideo(
                    id: record.id,
                    title: record.title,
                    published: record.published,
                    duration: record.duration,
                    isAudio: record.isAudio,
                    hasThumbnail: root.map { FileManager.default.fileExists(atPath: SnapshotStore.thumbnailURL(id: record.id, root: $0).path) } ?? false
                )
            }
            let snapshot = ArchiveSnapshot(
                updatedAt: Date(),
                lastSync: state.lastSync,
                videoCount: saved.count,
                downloadCount: queued.count,
                appBytes: footprint.app,
                downloadBytes: footprint.downloads,
                activeTitle: current?.title ?? "",
                activePercent: current?.progress ?? 0,
                activeBytesWritten: current?.bytesWritten ?? 0,
                activeBytesExpected: current?.bytesExpected ?? 0,
                activeSpeed: current?.bytesPerSecond ?? 0,
                queueCount: queued.count,
                videos: Array(videos)
            )
            DispatchQueue.main.async {
                guard generation == self.snapshotGeneration else { return }
                SnapshotStore.save(snapshot)
                WidgetCenter.shared.reloadAllTimelines()
                self.fetchThumbnails(Array(saved.prefix(6)))
            }
        }
    }

    func syncActivity(force: Bool) {
        guard #available(iOS 16.2, *) else { return }
        if !force, Date().timeIntervalSince(lastActivity) < 2 { return }
        lastActivity = Date()
        let state = LibraryStore.shared.snapshot()
        let active = state.videos.values
            .filter { $0.status == .downloading }
            .sorted { $0.updatedAt > $1.updatedAt }
        let queue = state.videos.values.filter { $0.status == .queued || $0.status == .downloading }.count
        guard let current = active.first else {
            LiveDownloadActivity.end()
            return
        }
        let content = DownloadActivityAttributes.ContentState(
            title: current.title,
            percent: min(max(current.progress, 0), 1),
            bytesWritten: current.bytesWritten,
            bytesExpected: current.bytesExpected,
            bytesPerSecond: current.bytesPerSecond,
            queueCount: queue
        )
        LiveDownloadActivity.sync(videoID: current.id, state: content)
    }

    private func fetchThumbnails(_ videos: [VideoRecord]) {
        guard let root = AppGroup.containerURL() else { return }
        let folder = root.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for video in videos {
            let destination = SnapshotStore.thumbnailURL(id: video.id, root: root)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            guard let text = video.thumbnailURL, let url = URL(string: text) else { continue }
            thumbs.dataTask(with: url) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, (200..<300).contains(status) else { return }
                try? data.write(to: destination, options: .atomic)
                DispatchQueue.main.async { WidgetCenter.shared.reloadAllTimelines() }
            }.resume()
        }
    }
}

@available(iOS 16.2, *)
enum LiveDownloadActivity {
    private static var current: Activity<DownloadActivityAttributes>?
    private static var last = DownloadActivityAttributes.ContentState(
        title: "Download finished",
        percent: 1,
        bytesWritten: 0,
        bytesExpected: 0,
        bytesPerSecond: 0,
        queueCount: 0
    )

    static func sync(videoID: String, state: DownloadActivityAttributes.ContentState) {
        last = state
        if current == nil || current?.activityState != .active {
            current = Activity<DownloadActivityAttributes>.activities.first { $0.activityState == .active }
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let current, current.activityState == .active {
            Task { await current.update(content) }
            return
        }
        do {
            current = try Activity.request(
                attributes: DownloadActivityAttributes(videoID: videoID),
                content: content,
                pushType: nil
            )
            DebugLog.event("live activity started \(videoID)")
        } catch {
            DebugLog.event("live activity failed \(error.localizedDescription)")
        }
    }

    static func end() {
        let activities = Activity<DownloadActivityAttributes>.activities
        current = nil
        guard !activities.isEmpty else { return }
        let state = last
        for activity in activities {
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
        }
        DebugLog.event("live activity ended")
    }
}

import SwiftUI
import WidgetKit

struct GalleryWidgets: WidgetBundle {
    var body: some Widget {
        LatestThreeWidget()
        AdaptiveDownloadWidget()
        StatsWidget()
        ArchiveListWidget()
    }
}

@main
struct ArchiveWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LatestVideoWidget()
        DownloadRingWidget()
        GalleryWidgets().body
        LockScreenWidget()
        DownloadLiveActivity()
    }
}

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: ArchiveSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: SnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: SnapshotStore.load())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

enum WidgetColor {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    /// Accent. This slot was gold in 1.5.0; it is red now.
    static let gold = Color(red: 0.86, green: 0.16, blue: 0.20)
    static let muted = Color(white: 0.62)
}

extension View {
    func archiveWidgetBackground() -> some View {
        containerBackground(WidgetColor.background, for: .widget)
    }
}

extension ArchiveSnapshot {
    static let placeholder = ArchiveSnapshot(
        updatedAt: Date(),
        lastSync: Date(),
        videoCount: 12,
        downloadCount: 4,
        appBytes: 24_000_000,
        downloadBytes: 3_400_000_000,
        activeTitle: "Nick Fuentes on the Alex Jones Show",
        activePercent: 0.42,
        activeBytesWritten: 420_000_000,
        activeBytesExpected: 1_000_000_000,
        activeSpeed: 1_500_000,
        queueCount: 2,
        videos: [
            SnapshotVideo(id: "1", title: "Nick Fuentes on the Alex Jones Show", published: Date(), duration: 4023, isAudio: false, hasThumbnail: false),
            SnapshotVideo(id: "2", title: "Trump CUCKS on Deportations", published: Date(), duration: 3575, isAudio: false, hasThumbnail: false),
            SnapshotVideo(id: "3", title: "I WAS RIGHT ABOUT EVERYTHING!!!", published: Date(), duration: 1800, isAudio: true, hasThumbnail: false)
        ]
    )

    var syncLine: String {
        guard let lastSync else { return "No successful sync yet" }
        return "Last successful sync \(SnapshotBytes.clock(lastSync))"
    }
}

extension SnapshotBytes {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        return formatter.string(from: date)
    }
}

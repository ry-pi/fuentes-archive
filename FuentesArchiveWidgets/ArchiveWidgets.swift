import SwiftUI
import UIKit
import WidgetKit

struct LatestVideoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "latest-video", provider: SnapshotProvider()) { entry in
            LatestVideoView(video: entry.snapshot.videos.first)
                .archiveWidgetBackground()
        }
        .configurationDisplayName("Latest video")
        .description("The newest item in the archive.")
        .supportedFamilies([.systemSmall])
    }
}

struct DownloadRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "download-ring", provider: SnapshotProvider()) { entry in
            DownloadRingView(snapshot: entry.snapshot)
                .widgetURL(ArchiveLink.downloads)
                .archiveWidgetBackground()
        }
        .configurationDisplayName("Download")
        .description("Progress of the current download.")
        .supportedFamilies([.systemSmall])
    }
}

struct LatestThreeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "latest-three", provider: SnapshotProvider()) { entry in
            LatestThreeView(videos: Array(entry.snapshot.videos.prefix(3)))
                .archiveWidgetBackground()
        }
        .configurationDisplayName("Latest three")
        .description("The three newest saved videos.")
        .supportedFamilies([.systemMedium])
    }
}

struct StatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "archive-stats", provider: SnapshotProvider()) { entry in
            StatsView(snapshot: entry.snapshot)
                .widgetURL(ArchiveLink.videos)
                .archiveWidgetBackground()
        }
        .configurationDisplayName("Archive stats")
        .description("How many videos are saved, and when the last sync succeeded.")
        .supportedFamilies([.systemMedium])
    }
}

struct ArchiveListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "archive-list", provider: SnapshotProvider()) { entry in
            ArchiveListView(videos: Array(entry.snapshot.videos.prefix(6)))
                .archiveWidgetBackground()
        }
        .configurationDisplayName("Recent videos")
        .description("A short list of the archive.")
        .supportedFamilies([.systemLarge])
    }
}

struct AdaptiveDownloadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "adaptive-download", provider: SnapshotProvider()) { entry in
            AdaptiveDownloadView(snapshot: entry.snapshot)
                .archiveWidgetBackground()
        }
        .configurationDisplayName("Now and recent")
        .description("Download progress while something is saving, otherwise the three newest videos.")
        .supportedFamilies([.systemMedium])
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "archive-lock", provider: SnapshotProvider()) { entry in
            LockScreenView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Archive")
        .description("Download progress, the last sync, and how many videos are saved.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LatestVideoView: View {
    var video: SnapshotVideo?

    var body: some View {
        Group {
            if let video {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnail(video)
                    Text(video.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(video.isAudio ? "Audio" : "Video")
                        .font(.caption2)
                        .foregroundStyle(WidgetColor.gold)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(ArchiveLink.video(video.id))
            } else {
                Text("No saved videos yet")
                    .font(.caption)
                    .foregroundStyle(WidgetColor.muted)
                    .widgetURL(ArchiveLink.videos)
            }
        }
    }
}

struct DownloadRingView: View {
    var snapshot: ArchiveSnapshot

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(max(snapshot.activePercent, 0), 1))
                    .stroke(WidgetColor.gold, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(snapshot.activePercent * 100))%")
                    .font(.headline.monospacedDigit())
            }
            .padding(6)
            Text(snapshot.queueCount > 0 ? snapshot.activeTitle : "Idle")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(WidgetColor.muted)
        }
    }
}

struct LatestThreeView: View {
    var videos: [SnapshotVideo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest")
                .font(.caption.weight(.bold))
                .foregroundStyle(WidgetColor.gold)
            if videos.isEmpty {
                Text("Nothing saved yet")
                    .foregroundStyle(WidgetColor.muted)
            } else {
                ForEach(videos) { video in
                    Link(destination: ArchiveLink.video(video.id)) {
                        HStack {
                            Text(video.title).lineLimit(1)
                            Spacer()
                            Text(video.isAudio ? "Audio" : "Video")
                                .font(.caption2)
                                .foregroundStyle(WidgetColor.gold)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct StatsView: View {
    var snapshot: ArchiveSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(snapshot.videoCount) saved")
                .font(.headline)
            Text(snapshot.syncLine)
                .font(.caption2)
                .foregroundStyle(WidgetColor.muted)
            bar("App", bytes: snapshot.appBytes, total: max(snapshot.appBytes + snapshot.downloadBytes, 1))
            bar("Downloads", bytes: snapshot.downloadBytes, total: max(snapshot.appBytes + snapshot.downloadBytes, 1))
            Text("Total \(SnapshotBytes.string(snapshot.appBytes + snapshot.downloadBytes))")
                .font(.caption2)
                .foregroundStyle(WidgetColor.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bar(_ title: String, bytes: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(SnapshotBytes.string(bytes))
            }
            .font(.caption2)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(WidgetColor.gold)
                        .scaleEffect(x: CGFloat(bytes) / CGFloat(total), anchor: .leading)
                }
                .clipShape(Capsule())
        }
    }
}

struct ArchiveListView: View {
    var videos: [SnapshotVideo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(WidgetColor.gold)
            if videos.isEmpty {
                Text("The archive is empty.")
                    .foregroundStyle(WidgetColor.muted)
            } else {
                ForEach(videos) { video in
                    Link(destination: ArchiveLink.video(video.id)) {
                        HStack {
                            Text(video.title).lineLimit(1)
                            Spacer()
                            Text(video.isAudio ? "Audio" : "Video")
                                .font(.caption2)
                                .foregroundStyle(WidgetColor.muted)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AdaptiveDownloadView: View {
    var snapshot: ArchiveSnapshot

    var body: some View {
        if snapshot.queueCount > 0, !snapshot.activeTitle.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.activeTitle)
                    .font(.headline)
                    .lineLimit(1)
                ProgressView(value: min(max(snapshot.activePercent, 0), 1))
                    .tint(WidgetColor.gold)
                HStack {
                    Text(SnapshotBytes.progress(written: snapshot.activeBytesWritten, expected: snapshot.activeBytesExpected))
                    Spacer()
                    Text(snapshot.queueCount == 1 ? "1 in queue" : "\(snapshot.queueCount) in queue")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(WidgetColor.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(ArchiveLink.downloads)
        } else {
            HStack(spacing: 8) {
                ForEach(Array(snapshot.videos.prefix(3))) { video in
                    Link(destination: ArchiveLink.video(video.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            thumbnail(video)
                            Text(video.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(2)
                        }
                    }
                }
                if snapshot.videos.isEmpty {
                    Text("No saved videos yet")
                        .font(.caption)
                        .foregroundStyle(WidgetColor.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct LockScreenView: View {
    @Environment(\.widgetFamily) private var family
    var snapshot: ArchiveSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: min(max(snapshot.activePercent, 0), 1)) {
                Image(systemName: "arrow.down")
            } currentValueLabel: {
                Text("\(Int(snapshot.activePercent * 100))")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetURL(ArchiveLink.downloads)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(snapshot.syncLine).lineLimit(1)
                Text("\(snapshot.videoCount) saved · \(snapshot.queueCount) in queue").lineLimit(1)
            }
            .font(.caption2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(ArchiveLink.videos)
        default:
            Text("\(snapshot.videoCount) saved")
                .widgetURL(ArchiveLink.videos)
        }
    }
}

@ViewBuilder
func thumbnail(_ video: SnapshotVideo) -> some View {
    if video.hasThumbnail, let root = AppGroup.containerURL(),
       let data = try? Data(contentsOf: SnapshotStore.thumbnailURL(id: video.id, root: root)),
       let image = UIImage(data: data) {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: 72)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
    } else {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.08))
            .frame(height: 72)
            .overlay {
                Image(systemName: video.isAudio ? "waveform" : "play.fill")
                    .foregroundStyle(WidgetColor.gold)
            }
    }
}

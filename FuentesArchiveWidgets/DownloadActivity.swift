import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color(red: 0.93, green: 0.76, blue: 0.31))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.percent * 100))%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Color(red: 0.93, green: 0.76, blue: 0.31))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(max(context.state.percent, 0), 1))
                            .tint(Color(red: 0.93, green: 0.76, blue: 0.31))
                        Text(detail(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text("\(Int(context.state.percent * 100))%")
                    .font(.caption2.monospacedDigit())
            } compactTrailing: {
                Text(context.state.queueCount > 1 ? "\(context.state.queueCount)" : "↓")
                    .font(.caption2)
            } minimal: {
                Text("\(Int(context.state.percent * 100))")
                    .font(.caption2.monospacedDigit())
            }
        }
    }

    private func lockScreen(_ state: DownloadActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.title)
                .font(.headline)
                .lineLimit(1)
            ProgressView(value: min(max(state.percent, 0), 1))
                .tint(Color(red: 0.93, green: 0.76, blue: 0.31))
            Text(detail(state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func detail(_ state: DownloadActivityAttributes.ContentState) -> String {
        let written = SnapshotBytes.string(state.bytesWritten)
        let expected = state.bytesExpected > 0 ? SnapshotBytes.string(state.bytesExpected) : ""
        let size = expected.isEmpty ? written : "\(written) / \(expected)"
        let remaining = max(state.bytesExpected - state.bytesWritten, 0)
        let eta = SnapshotBytes.eta(remaining: remaining, rate: state.bytesPerSecond)
        let speed = state.bytesPerSecond > 1 ? SnapshotBytes.string(Int64(state.bytesPerSecond)) + "/s" : ""
        let queue = state.queueCount > 1 ? "\(state.queueCount) in queue" : ""
        return [size, speed, eta, queue].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

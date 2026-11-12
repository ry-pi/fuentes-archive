import AVKit
import SwiftUI

struct PlayerTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selected: VideoRecord?
    @State private var shareURL: URL?

    private var rows: [VideoRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.playable().filter { video in
            needle.isEmpty || video.title.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to play yet",
                    systemImage: "headphones",
                    description: Text("Finished downloads show up here. Queued, partial, and failed items stay on the Downloads tab.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(rows) { video in
                    PlayerRow(video: video) { selected = video }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.deleteFile(video.id) } label: {
                                Label("Delete file", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if video.fileURL != nil {
                                Button { shareURL = video.fileURL } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(Theme.gold)
                            }
                        }
                }
            }
        }
        .navigationTitle("Player")
        .searchable(text: $query, prompt: "Search saved files")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .fullScreenCover(item: $selected) { video in
            ArchivePlayer(video: video)
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareSheet(url: shareURL)
            }
        }
    }
}

struct PlayerRow: View {
    let video: VideoRecord
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(video.isAudio ? "Audio" : "Video")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.gold.opacity(0.18))
                    .foregroundStyle(Theme.gold)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var meta: String {
        var parts = [Format.relative(video.published), Format.clock(video.duration)]
        if let url = video.fileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(Format.bytes(Int64(size)))
        }
        if video.playbackSeconds > 3 { parts.append("Resume \(Format.clock(video.playbackSeconds))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ArchivePlayer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord
    @StateObject private var engine: PlayingItem

    init(video: VideoRecord) {
        self.video = video
        let url = video.fileURL ?? URL(fileURLWithPath: "/dev/null")
        _engine = StateObject(wrappedValue: PlayingItem(url: url, title: video.title, audioOnly: video.isAudio, resume: video.playbackSeconds))
    }

    var body: some View {
        Group {
            if video.fileURL == nil {
                missing
            } else if video.isAudio {
                audioBody
            } else {
                videoBody
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard video.fileURL != nil else { return }
            engine.onPosition = { seconds in
                model.rememberPlayback(video.id, seconds: seconds)
            }
            engine.start()
        }
        .onDisappear { engine.stop() }
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Text("This file is no longer on the phone.")
            Button("Close") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var videoBody: some View {
        ZStack(alignment: .topLeading) {
            VideoPlayer(player: engine.player)
                .ignoresSafeArea()
            closeButton
            if !engine.message.isEmpty {
                Text(engine.message)
                    .font(.footnote)
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .padding(.top, 64)
            }
        }
    }

    private var audioBody: some View {
        VStack(spacing: 22) {
            HStack {
                closeButton
                Spacer()
                Button(speedText(engine.speed)) { engine.cycleSpeed() }
                    .buttonStyle(.bordered)
            }
            AsyncImage(url: video.thumbnailURL.flatMap(URL.init(string:))) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.gold)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.card)
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(video.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if !engine.message.isEmpty {
                Text(engine.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
            VStack(spacing: 6) {
                Slider(value: $engine.current, in: 0...max(engine.duration, 1)) { editing in
                    engine.setScrubbing(editing)
                }
                .tint(Theme.gold)
                HStack {
                    Text(Format.clock(engine.current))
                    Spacer()
                    Text(Format.clock(engine.duration > 0 ? engine.duration : video.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 28) {
                Button { engine.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.gold)
                }
                Button { engine.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .padding(10)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func speedText(_ speed: Float) -> String {
        if abs(speed - 1) < 0.01 { return "1x" }
        if abs(speed - 2) < 0.01 { return "2x" }
        return String(format: "%.2fx", speed)
    }
}

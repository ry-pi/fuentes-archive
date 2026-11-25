import AVKit
import SwiftUI

struct PlayerTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var sort: LibrarySort = .newest
    @State private var selected: VideoRecord?
    @State private var shareURL: URL?

    private var rows: [VideoRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = model.playable().filter { video in
            needle.isEmpty || video.title.localizedCaseInsensitiveContains(needle)
        }
        return LibrarySort.ordered(filtered, sort)
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
        .listStyle(.plain)
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .toolbar(content: playerToolbar)
        .fullScreenCover(item: $selected) { video in
            ArchivePlayer(video: video)
        }
        .onChange(of: model.pendingPlayID) { _, id in
            guard let id, let video = model.video(id) else { return }
            selected = video
            model.pendingPlayID = nil
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareSheet(url: shareURL)
            }
        }
    }

    @ToolbarContentBuilder
    private func playerToolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            SortMenu(sort: $sort)
        }
    }
}

struct PlayerLayerHost: UIViewRepresentable {
    var player: AVPlayer
    var pip: PiPController

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    var automatic: Bool

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        pip.attach(layer: view.playerLayer, automatic: automatic)
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else { return AVPlayerLayer() }
        return layer
    }
}

struct PiPButton: View {
    @ObservedObject var pip: PiPController

    var body: some View {
        Button { pip.toggle() } label: {
            Image(systemName: pip.active ? "pip.exit" : "pip.enter")
                .padding(10)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Picture in Picture")
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
        if video.manuallyAdded { parts.append("Added") }
        if video.playbackSeconds > 3 { parts.append("Resume \(Format.clock(video.playbackSeconds))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ArchivePlayer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let video: VideoRecord
    @StateObject private var engine: PlayingItem

    init(video: VideoRecord) {
        self.video = video
        let url = video.fileURL ?? URL(fileURLWithPath: "/dev/null")
        _engine = StateObject(wrappedValue: PlayingItem(url: url, title: video.title, audioOnly: video.isAudio, resume: video.playbackSeconds, artworkURL: video.thumbnailURL))
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
            engine.interfaceVisible = true
            guard video.fileURL != nil else { return }
            engine.onPosition = { seconds in
                model.rememberPlayback(video.id, seconds: seconds)
            }
            engine.pip.onStop = { [weak engine] in
                guard let engine else { return }
                if !engine.interfaceVisible {
                    engine.stop()
                }
            }
            engine.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard !model.settings.backgroundAudio, !engine.pip.active else { return }
            if phase == .background {
                engine.setBackgroundHold(true)
            } else if phase == .active {
                engine.setBackgroundHold(false)
            }
        }
        .onChange(of: model.settings.backgroundAudio) { _, enabled in
            engine.applyBackgroundPolicy(enabled)
        }
        .onDisappear {
            engine.interfaceVisible = false
            if scenePhase == .active, !engine.pip.active {
                engine.stop()
            }
        }
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
        VStack(spacing: 16) {
            ZStack(alignment: .top) {
                PlayerLayerHost(
                    player: engine.player,
                    pip: engine.pip,
                    automatic: model.settings.backgroundAudio && model.settings.autoPictureInPicture
                )
                    .background(.black)
                HStack {
                    PiPButton(pip: engine.pip)
                    Spacer()
                    closeButton
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !engine.message.isEmpty {
                Text(engine.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
            transport
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var transport: some View {
        VStack(spacing: 12) {
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
            HStack(spacing: 28) {
                Button { engine.skip(-engine.skipAmount) } label: { Image(systemName: skipSymbol(seconds: model.settings.skipSeconds, forward: false)).font(.title2) }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.gold)
                }
                Button { engine.skip(engine.skipAmount) } label: { Image(systemName: skipSymbol(seconds: model.settings.skipSeconds, forward: true)).font(.title2) }
            }
            .buttonStyle(.plain)
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
                Button { engine.skip(-engine.skipAmount) } label: { Image(systemName: skipSymbol(seconds: model.settings.skipSeconds, forward: false)).font(.title2) }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.gold)
                }
                Button { engine.skip(engine.skipAmount) } label: { Image(systemName: skipSymbol(seconds: model.settings.skipSeconds, forward: true)).font(.title2) }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var closeButton: some View {
        Button {
            engine.stop()
            dismiss()
        } label: {
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

    private func skipSymbol(seconds: Int, forward: Bool) -> String {
        let base = forward ? "goforward" : "gobackward"
        switch seconds {
        case 10, 15, 30: return "\(base).\(seconds)"
        default: return base
        }
    }
}

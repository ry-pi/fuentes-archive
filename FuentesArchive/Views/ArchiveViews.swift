import AVKit
import SwiftUI
import UIKit

enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.125)
    static let line = Color.white.opacity(0.08)
    static let gold = Color(red: 0.93, green: 0.76, blue: 0.31)
    static let muted = Color(white: 0.62)
    static let danger = Color(red: 0.90, green: 0.36, blue: 0.32)
    static let ok = Color(red: 0.45, green: 0.74, blue: 0.52)
}

enum Format {
    static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func views(_ count: Int?) -> String {
        guard let count else { return "" }
        if count >= 1_000_000 { return String(format: "%.1fM views", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK views", Double(count) / 1_000) }
        return "\(count) views"
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func eta(remaining bytes: Int64, rate: Double) -> String {
        guard rate > 1, bytes > 0 else { return "" }
        let seconds = Int(Double(bytes) / rate)
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m left" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s left" }
        return "\(seconds)s left"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension VideoRecord {
    var statusLabel: String {
        switch status {
        case .catalogued: return disposition == .downloadable ? "Not saved" : disposition.rawValue
        case .queued: return "Queued"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .downloading:
            return "Downloading \(Int(progress * 100))%"
        case .paused: return "Paused"
        case .downloaded: return "Saved"
        case .failed: return "Failed"
        case .waiting: return disposition == .premiere ? "Premiere" : "Processing"
        case .skipped: return disposition == .members ? "Members only" : "Skipped"
        }
    }

    var statusColor: Color {
        switch status {
        case .downloaded: return Theme.ok
        case .failed: return Theme.danger
        case .downloading, .queued, .paused: return Theme.gold
        case .waitingForWiFi, .waiting, .skipped: return Theme.muted
        case .catalogued: return Theme.muted
        }
    }

    var fileURL: URL? {
        guard let relativePath else { return nil }
        return LibraryStore.shared.fileURL(relativePath: relativePath)
    }
}

struct ActiveBadge: ViewModifier {
    var count: Int
    func body(content: Content) -> some View {
        if count > 0 {
            content.badge(count)
        } else {
            content
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String?

    var body: some View {
        TabView {
            NavigationStack { library }
                .tabItem { Label("Videos", systemImage: "play.rectangle.on.rectangle") }
            NavigationStack { DownloadsView() }
                .modifier(ActiveBadge(count: model.activeDownloadCount))
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
    }

    private var library: some View {
        LibraryView(selection: $selection)
    }

}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: String?
    @State private var optionsID: String?

    var body: some View {
        let items = model.videos()
        List(selection: $selection) {
            Section {
                header
                if let error = model.snapshot.lastError { errorBanner(error) }
                if showIntro { intro }
                filters
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            if items.isEmpty {
                empty
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(items) { video in
                    Button {
                        selection = video.id
                        optionsID = video.id
                    } label: {
                        VideoRow(video: video)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.card)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.hide(video.id) } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                        if video.relativePath != nil {
                            Button(role: .destructive) { model.deleteFile(video.id) } label: {
                                Label("Delete file", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if video.status != .downloaded && video.disposition == .downloadable {
                            Button { model.download(video.id, resetAttempts: true) } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .tint(Theme.gold)
                        }
                    }
                    .contextMenu {
                        if video.disposition == .downloadable && video.status != .downloading {
                            Button("Download") { model.download(video.id, resetAttempts: true) }
                        }
                        if video.relativePath != nil {
                            Button("Delete file", role: .destructive) { model.deleteFile(video.id) }
                        }
                        Button("Hide from library", role: .destructive) { model.hide(video.id) }
                    }
                    .tag(video.id)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Fuentes Archive")
        .sheet(isPresented: Binding(get: { optionsID != nil }, set: { if !$0 { optionsID = nil } })) {
            if let optionsID {
                DownloadOptionsSheet(videoID: optionsID)
            }
        }
        .searchable(text: $model.search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles")
        .refreshable { model.sync(trigger: "pull") }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(LibrarySort.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.sync(trigger: "manual") } label: {
                    if model.syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(model.syncing)
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
    }

    private var showIntro: Bool {
        model.snapshot.baselineReady && !model.snapshot.settings.dismissedIntro && model.snapshot.videos.values.allSatisfy { $0.status != .downloaded }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nicholas J. Fuentes")
                .font(.title2.weight(.semibold))
            Text("Videos tab only · rumble.com/c/nickjfuentes/videos")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            if let last = model.snapshot.lastSync {
                Text("Last sync \(Format.relative(last))")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New uploads will download on their own.")
                .font(.subheadline.weight(.semibold))
            Text("Videos already on the channel are listed here and are not downloaded until you ask. The first sync is only a baseline.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            HStack {
                Button("Download newest 5") { model.downloadNewest(5) }
                Button("Newest 10") { model.downloadNewest(10) }
                Spacer()
                Button("Dismiss") { model.dismissIntro() }
                    .foregroundStyle(Theme.muted)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(Theme.gold)
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { item in
                    Button {
                        model.filter = item
                    } label: {
                        Text(item.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(model.filter == item ? Theme.gold : Theme.card)
                            .foregroundStyle(model.filter == item ? Color.black : Color.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            if model.syncing {
                ProgressView("Checking the Videos tab")
            } else if model.snapshot.lastError != nil {
                Text("The last sync did not finish.")
                    .foregroundStyle(Theme.muted)
                Button("Try again") { model.sync(trigger: "manual") }
            } else {
                Text(model.search.isEmpty ? "No videos yet" : "No titles match")
                    .font(.headline)
                Text(model.search.isEmpty ? "Pull to refresh to read the Videos tab." : "Try a shorter search.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct VideoRow: View {
    let video: VideoRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: video.thumbnailURL.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        Theme.line
                    }
                }
                .frame(width: 112, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(Format.clock(video.duration))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text([Format.relative(video.published), Format.views(video.views)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(video.statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(video.statusColor)
                    if let quality = video.qualityLabel {
                        Text(quality)
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                if video.status == .downloading {
                    ProgressView(value: video.progress)
                        .tint(Theme.gold)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct VideoDetailView: View {
    @EnvironmentObject private var model: AppModel
    let video: VideoRecord
    @State private var playing = false

    private var current: VideoRecord { model.video(video.id) ?? video }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: current.thumbnailURL.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Theme.card
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(current.title)
                    .font(.title3.weight(.semibold))
                Text([Format.clock(current.duration), Format.views(current.views), Format.relative(current.published)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                statusBlock
                actions
                if let error = current.errorMessage, current.status == .failed || current.status == .skipped {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
                Text(current.watchURL)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Video")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $playing) {
            if let url = current.fileURL {
                PlayerScreen(url: url)
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.statusLabel)
                .font(.headline)
                .foregroundStyle(current.statusColor)
            if current.status == .downloading {
                ProgressView(value: current.progress)
                    .tint(Theme.gold)
                if current.segmentTotal > 0 {
                    Text("Piece \(current.segmentDone) of \(current.segmentTotal)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                } else if current.bytesExpected > 0 {
                    Text("\(Format.bytes(current.bytesWritten)) of \(Format.bytes(current.bytesExpected))")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            if current.status == .downloaded, current.fileURL != nil {
                Button { playing = true } label: { label("Play", "play.fill") }
                if let url = current.fileURL {
                    ShareLink(item: url) { label("Share file", "square.and.arrow.up") }
                }
                Button(role: .destructive) { model.deleteFile(current.id) } label: { label("Delete file", "trash") }
            } else if current.disposition == .downloadable {
                Button { model.download(current.id, resetAttempts: true) } label: {
                    label(current.status == .failed ? "Retry download" : "Download", "arrow.down.circle")
                }
                .disabled(current.status == .downloading || current.status == .queued)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.gold)
        .foregroundStyle(.black)
    }

    private func label(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity)
    }
}

struct PlayerScreen: View {
    let url: URL
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .padding(10)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .padding()
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var feedURL: URL?

    var body: some View {
        Form {
            Section("Downloads") {
                Toggle("Auto-download new videos", isOn: binding(\.autoDownload))
                Toggle("Wi-Fi only", isOn: binding(\.wifiOnly))
                Toggle("Save a copy to Photos", isOn: binding(\.saveToPhotos))
                Toggle("Notify when a download finishes", isOn: binding(\.notify))
                Picker("Quality", selection: binding(\.quality)) {
                    ForEach(Quality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                Stepper(value: binding(\.maxPages), in: 1...10) {
                    Text("Pages checked each sync: \(model.settings.maxPages)")
                }
                Stepper(value: binding(\.backfillCount), in: 0...25) {
                    Text("On first sync, also download newest \(model.settings.backfillCount)")
                }
            }
            Section("Library") {
                LabeledContent("Saved files", value: Format.bytes(model.storageBytes()))
                NavigationLink("Storage") { StorageView() }
                NavigationLink("Background refresh log") { RefreshLogView() }
                Button("Write a local RSS file") { feedURL = model.exportFeed() }
                Button("Download newest 5 now") { model.downloadNewest(5) }
                Button("Restore hidden videos") { model.restoreHidden() }
            }
            Section("Channel") {
                Text("https://rumble.com/c/nickjfuentes/videos")
                    .font(.footnote)
                    .textSelection(.enabled)
                Text("Shorts, livestreams, and the All tab are not requested. Rumble does not publish an RSS feed for this channel; /feeds/c/nickjfuentes returns 410 Gone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            Section("About") {
                Text("Fuentes Archive 1.0.0")
                Text("Files land in On My iPhone → Fuentes Archive. iOS decides when background refresh actually runs.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .sheet(isPresented: Binding(get: { feedURL != nil }, set: { if !$0 { feedURL = nil } })) {
            if let feedURL {
                ShareSheet(url: feedURL)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in model.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }
}

struct StorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirm = false

    var body: some View {
        List {
            Section {
                LabeledContent("Used", value: Format.bytes(model.storageBytes()))
                Button("Delete all saved files", role: .destructive) { confirm = true }
            }
            Section("Files") {
                let saved = model.videos().filter { $0.relativePath != nil }
                if saved.isEmpty {
                    Text("Nothing saved yet.")
                        .foregroundStyle(Theme.muted)
                }
                ForEach(saved) { video in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).font(.subheadline.weight(.semibold))
                        if let path = video.relativePath {
                            let size = (try? LibraryStore.shared.fileURL(relativePath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                            Text(Format.bytes(Int64(size)))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.deleteFile(video.id) }
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .confirmationDialog("Delete every file in the archive?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete files", role: .destructive) { model.deleteAllFiles() }
        } message: {
            Text("The video list stays. You can download them again.")
        }
    }
}

struct RefreshLogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.snapshot.log.isEmpty {
                Text("Syncs and download events will show up here, including background refresh attempts.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(model.snapshot.log.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.source.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(entry.level == "error" ? Theme.danger : Theme.gold)
                        Spacer()
                        Text(Format.relative(entry.date))
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                    Text(entry.message)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Refresh log")
        .toolbar {
            Button("Clear") { model.clearLog() }
        }
    }
}

struct DownloadOptionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let videoID: String
    @State private var choices: [DownloadChoice] = []
    @State private var loading = true
    @State private var error: String?
    @State private var play = false

    private var video: VideoRecord? { model.video(videoID) }

    var body: some View {
        NavigationStack {
            List {
                if let video, video.status == .downloaded, video.fileURL != nil {
                    Section("Saved on this iPhone") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(video.qualityLabel ?? "Saved file")
                                .font(.headline)
                            if let url = video.fileURL {
                                Text(Format.bytes(Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        Button("Play") { play = true }
                        Button("Delete saved file", role: .destructive) { model.deleteFile(videoID) }
                    }
                }
                Section("Download another copy") {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading available qualities…")
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await load() } }
                    } else if choices.isEmpty {
                        Text("No downloadable renditions were published for this video.")
                            .foregroundStyle(Theme.muted)
                    } else {
                        ForEach(choices) { choice in
                            Button {
                                model.download(videoID, choice: choice)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.title)
                                        Text(choice.detail)
                                            .font(.caption)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Text(choice.sizeLabel)
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(Theme.gold)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(video?.title ?? "Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .task { await load() }
        .fullScreenCover(isPresented: $play) {
            if let video { PlayerScreen(video: video) }
        }
    }

    private func load() async {
        guard let video else {
            error = "This video is no longer in the library."
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            choices = try await model.offers(for: video)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let rows = model.downloadRows()
        List {
            if rows.isEmpty {
                ContentUnavailableView("No downloads yet", systemImage: "arrow.down.circle", description: Text("Open a video and pick a quality. Active, paused, failed, and finished items stay here."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    HStack {
                        Button("Pause all") { model.pauseAll() }
                            .disabled(!rows.contains { $0.status == .downloading || $0.status == .queued })
                        Spacer()
                        Button("Resume all") { model.resumeAll() }
                            .disabled(!rows.contains { $0.status == .paused || $0.status == .waitingForWiFi })
                    }
                }
                ForEach(rows) { video in
                    DownloadRow(video: video)
                }
            }
        }
        .navigationTitle("Downloads")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var model: AppModel
    let video: VideoRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(video.title).font(.headline).lineLimit(2)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            if video.status == .downloading || video.status == .paused {
                ProgressView(value: min(max(video.progress, 0), 1))
                    .tint(Theme.gold)
            }
            HStack {
                if video.status == .paused || video.status == .failed || video.status == .waitingForWiFi {
                    Button("Resume") { model.resumeDownload(video.id) }
                } else if video.status == .downloading || video.status == .queued {
                    Button("Pause") { model.pauseDownload(video.id) }
                }
                if video.status != .downloaded {
                    Button("Stop", role: .destructive) { model.stopDownload(video.id) }
                }
                Spacer()
                Text(sizeLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String {
        var parts = [video.status.label]
        if let label = video.qualityLabel { parts.append(label) }
        if video.status == .downloading {
            let speed = Format.rate(video.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            let remaining = max(video.bytesExpected - video.bytesWritten, 0)
            let eta = Format.eta(remaining: remaining, rate: video.bytesPerSecond)
            if !eta.isEmpty { parts.append(eta) }
        }
        if let error = video.errorMessage, video.status == .failed { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private var sizeLine: String {
        if video.bytesExpected > 0 {
            return Format.bytes(video.bytesWritten) + " / " + Format.bytes(video.bytesExpected)
        }
        return Format.bytes(video.bytesWritten)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

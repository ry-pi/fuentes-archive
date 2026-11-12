import AVFoundation
import MediaPlayer

enum PlaybackSession {
    static func activate(audioOnly: Bool) {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = audioOnly ? .default : .moviePlayback
        do {
            try session.setCategory(.playback, mode: mode)
            try session.setActive(true)
            DebugLog.event("audio session .playback \(audioOnly ? "audio" : "video")")
        } catch {
            DebugLog.event("audio session failed \(error.localizedDescription)")
        }
    }
}

struct MediaReport {
    var duration: Double
    var audioTracks: Int
    var videoTracks: Int
    var problem: String?
}

enum MediaCheck {
    static func inspect(url: URL, requireAudio: Bool) -> MediaReport {
        let gate = DispatchSemaphore(value: 0)
        var report = MediaReport(duration: 0, audioTracks: 0, videoTracks: 0, problem: "The file could not be checked.")
        Task {
            report = await load(url, requireAudio: requireAudio)
            gate.signal()
        }
        if gate.wait(timeout: .now() + 20) == .timedOut {
            report.problem = "Checking the file timed out."
        }
        return report
    }

    static func load(url: URL, requireAudio: Bool) async -> MediaReport {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let seconds = duration.seconds
            let audio = tracks.filter { $0.mediaType == .audio }.count
            let video = tracks.filter { $0.mediaType == .video }.count
            let names = tracks.map { $0.mediaType.rawValue }.joined(separator: ",")
            DebugLog.event("media \(url.lastPathComponent) \(String(format: "%.1f", seconds.isFinite ? seconds : 0))s tracks=\(names.isEmpty ? "none" : names)")
            var problem: String?
            if !seconds.isFinite || seconds < 0.2 {
                problem = "The saved file has no playable duration."
            } else if requireAudio && audio == 0 {
                problem = "The audio file has no audio track."
            } else if audio == 0 && video == 0 {
                problem = "The saved file has no audio or video track."
            }
            if !requireAudio && audio == 0 && video > 0 {
                DebugLog.event("warning \(url.lastPathComponent) has video and no audio track")
            }
            return MediaReport(duration: seconds, audioTracks: audio, videoTracks: video, problem: problem)
        } catch {
            DebugLog.event("media \(url.lastPathComponent) error \(error.localizedDescription)")
            return MediaReport(duration: 0, audioTracks: 0, videoTracks: 0, problem: error.localizedDescription)
        }
    }
}

final class NowPlayingController {
    static let shared = NowPlayingController()
    private weak var player: AVPlayer?
    private var title = ""
    private var installed = false

    func attach(player: AVPlayer, title: String) {
        self.player = player
        self.title = title
        install()
        refresh()
    }

    func detach() {
        player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func refresh() {
        guard let player else { return }
        let elapsed = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Fuentes Archive",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate
        ]
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.player?.rate = self?.player?.defaultRate ?? 1
            self?.refresh()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.refresh()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(15)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(-15)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(position.positionTime)
            return .success
        }
    }

    private func skip(_ delta: Double) {
        let now = player?.currentTime().seconds ?? 0
        seek(max(0, (now.isFinite ? now : 0) + delta))
    }

    private func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        refresh()
    }
}

@MainActor
final class PlayingItem: ObservableObject {
    let player: AVPlayer
    let audioOnly: Bool
    let title: String
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var speed: Float = 1
    @Published var message = ""
    private var token: Any?
    private var statusWatch: NSKeyValueObservation?
    private var lastSaved: Double = -1
    var onPosition: ((Double) -> Void)?
    private var scrubbing = false

    init(url: URL, title: String, audioOnly: Bool, resume: Double) {
        self.title = title
        self.audioOnly = audioOnly
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.volume = 1
        player.isMuted = false
        player.defaultRate = 1
        current = resume
    }

    func start() {
        PlaybackSession.activate(audioOnly: audioOnly)
        player.volume = 1
        player.isMuted = false
        watchStatus()
        if current > 1 {
            player.seek(to: CMTime(seconds: current, preferredTimescale: 600))
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        player.play()
        player.rate = speed
        playing = true
        NowPlayingController.shared.attach(player: player, title: title)
        Task { await logTracks() }
    }

    func stop() {
        if let token { player.removeTimeObserver(token) }
        token = nil
        statusWatch = nil
        player.pause()
        playing = false
        NowPlayingController.shared.detach()
        store(current)
    }

    func toggle() {
        if playing {
            player.pause()
            playing = false
        } else {
            player.play()
            player.rate = speed
            playing = true
        }
        NowPlayingController.shared.refresh()
    }

    func skip(_ delta: Double) {
        let next = min(max(0, current + delta), duration > 0 ? duration : current + delta)
        seek(next)
    }

    func seek(_ seconds: Double) {
        let target = max(0, seconds)
        current = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        NowPlayingController.shared.refresh()
        store(target)
    }

    func setScrubbing(_ active: Bool) {
        scrubbing = active
        if !active { seek(current) }
    }

    func cycleSpeed() {
        let steps: [Float] = [1, 1.25, 1.5, 2]
        speed = steps.first { $0 > speed + 0.01 } ?? 1
        player.defaultRate = speed
        if playing { player.rate = speed }
        NowPlayingController.shared.refresh()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if !scrubbing { current = seconds }
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
        playing = player.rate > 0.05
        if Int(seconds) % 5 == 0 { store(seconds) }
        NowPlayingController.shared.refresh()
    }

    private func store(_ seconds: Double) {
        guard seconds.isFinite, abs(seconds - lastSaved) > 1 else { return }
        lastSaved = seconds
        onPosition?(seconds)
    }

    private func watchStatus() {
        statusWatch = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                if status == .failed {
                    self?.message = message ?? "Playback failed."
                    DebugLog.event("playback failed \(message ?? "unknown")")
                } else if status == .readyToPlay {
                    DebugLog.event("playback ready")
                }
            }
        }
    }

    private func logTracks() async {
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return }
        _ = await MediaCheck.load(url: url, requireAudio: audioOnly)
    }
}

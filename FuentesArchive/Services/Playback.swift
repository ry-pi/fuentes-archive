import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit

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

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
            report = await load(url: url, requireAudio: requireAudio)
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
    private var artwork: UIImage?
    private var installed = false
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onSkip: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    private(set) var skipSeconds: Double = 15

    func attach(player: AVPlayer, title: String) {
        self.player = player
        self.title = title
        install()
        setCommands(enabled: true)
        applySkip(Int(skipSeconds))
        refresh()
    }

    func applySkip(_ seconds: Int) {
        let chosen = [10, 15, 30].contains(seconds) ? seconds : 15
        skipSeconds = Double(chosen)
        let numbers = [NSNumber(value: chosen)]
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = numbers
        center.skipBackwardCommand.preferredIntervals = numbers
    }

    func setArtwork(_ image: UIImage) {
        artwork = image
        refresh()
    }

    func detach() {
        player = nil
        artwork = nil
        onPlay = nil
        onPause = nil
        onSkip = nil
        onSeek = nil
        setCommands(enabled: false)
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
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: player.defaultRate
        ]
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        applySkip(Int(skipSeconds))
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let play = self.onPlay
            DispatchQueue.main.async {
                if let play { play() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let pause = self.onPause
            DispatchQueue.main.async {
                if let pause { pause() }
            }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let seconds = self.skipSeconds
            let skip = self.onSkip
            DispatchQueue.main.async {
                if let skip { skip(seconds) }
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let seconds = self.skipSeconds
            let skip = self.onSkip
            DispatchQueue.main.async {
                if let skip { skip(-seconds) }
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seek = self.onSeek
            let seconds = position.positionTime
            DispatchQueue.main.async {
                if let seek { seek(seconds) }
            }
            return .success
        }
    }

    private func setCommands(enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
    }
}

final class PiPController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published var active = false
    @Published var possible = false
    private var pip: AVPictureInPictureController?
    var onRestore: (() -> Void)?
    var onStop: (() -> Void)?

    func attach(layer: AVPlayerLayer, automatic: Bool) {
        if pip?.playerLayer === layer {
            pip?.canStartPictureInPictureAutomaticallyFromInline = automatic
            possible = pip?.isPictureInPicturePossible ?? false
            return
        }
        pip?.delegate = nil
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else {
            pip = nil
            possible = false
            return
        }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = automatic
        pip = controller
        possible = controller.isPictureInPicturePossible
    }

    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
            return
        }
        guard pip.isPictureInPicturePossible else { return }
        pip.startPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let stop = onStop
        DispatchQueue.main.async {
            self.active = false
            if let stop { stop() }
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let restore = onRestore
        DispatchQueue.main.async {
            if let restore { restore() }
            completionHandler(true)
        }
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
    let pip = PiPController()
    var interfaceVisible = false
    private var token: Any?
    private var statusWatch: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var lastSaved: Double = -1
    var onPosition: ((Double) -> Void)?
    private var scrubbing = false
    private var resumeAfterInterruption = false
    private var started = false
    private var acceptingRemote = false
    private let artworkURL: String?

    init(url: URL, title: String, audioOnly: Bool, resume: Double, artworkURL: String? = nil) {
        self.title = title
        self.audioOnly = audioOnly
        self.artworkURL = artworkURL
        let settings = AppModel.shared.settings
        let rate = Float(settings.playbackSpeed)
        let startAt = settings.rememberPlayback ? resume : 0
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.volume = 1
        player.isMuted = false
        speed = rate
        player.defaultRate = rate
        player.audiovisualBackgroundPlaybackPolicy = settings.backgroundAudio ? .continuesIfPossible : .pauses
        current = startAt
    }

    func start() {
        if started { return }
        started = true
        acceptingRemote = true
        PlaybackSession.activate(audioOnly: audioOnly)
        player.volume = 1
        player.isMuted = false
        watchStatus()
        watchSession()
        if current > 1 {
            player.seek(to: CMTime(seconds: current, preferredTimescale: 600))
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self else { return }
                self.tick(seconds)
            }
        }
        player.play()
        player.rate = speed
        playing = true
        let remote = NowPlayingController.shared
        remote.onPlay = { [weak self] in
            guard let self else { return }
            self.playFromRemote()
        }
        remote.onPause = { [weak self] in
            guard let self else { return }
            self.pauseFromRemote()
        }
        remote.onSkip = { [weak self] delta in
            guard let self else { return }
            self.skip(delta)
        }
        remote.onSeek = { [weak self] seconds in
            guard let self else { return }
            self.seek(seconds)
        }
        remote.attach(player: player, title: title)
        remote.applySkip(AppModel.shared.settings.skipSeconds)
        loadArtwork()
        Task { await logTracks() }
    }

    func stop() {
        acceptingRemote = false
        if let token { player.removeTimeObserver(token) }
        token = nil
        statusWatch = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        player.pause()
        playing = false
        NowPlayingController.shared.detach()
        if !pip.active {
            PlaybackSession.deactivate()
        }
        started = false
        store(current)
    }

    func playFromRemote() {
        guard acceptingRemote else { return }
        PlaybackSession.activate(audioOnly: audioOnly)
        player.play()
        player.rate = speed
        playing = true
        NowPlayingController.shared.refresh()
    }

    func pauseFromRemote() {
        player.pause()
        playing = false
        NowPlayingController.shared.refresh()
    }

    var skipAmount: Double { Double(AppModel.shared.settings.skipSeconds) }

    func applyBackgroundPolicy(_ enabled: Bool) {
        player.audiovisualBackgroundPlaybackPolicy = enabled ? .continuesIfPossible : .pauses
    }

    func toggle() {
        if playing {
            player.pause()
            playing = false
        } else {
            PlaybackSession.activate(audioOnly: audioOnly)
            player.play()
            player.rate = speed
            playing = true
        }
        NowPlayingController.shared.refresh()
    }

    func setBackgroundHold(_ held: Bool) {
        if held {
            pauseFromRemote()
            acceptingRemote = false
            PlaybackSession.deactivate()
            return
        }
        guard started else { return }
        acceptingRemote = true
        PlaybackSession.activate(audioOnly: audioOnly)
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

    private func watchSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                guard let self, let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
                if type == .began {
                    self.resumeAfterInterruption = self.playing
                    self.pauseFromRemote()
                } else if type == .ended {
                    let shouldResume = AppModel.shared.settings.resumeAfterInterruption && options.contains(.shouldResume)
                    if shouldResume, self.resumeAfterInterruption {
                        self.playFromRemote()
                    }
                    self.resumeAfterInterruption = false
                }
            }
        }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                if reason == .oldDeviceUnavailable, AppModel.shared.settings.pauseOnDisconnect {
                    self.pauseFromRemote()
                }
            }
        }
        observers.append(interruption)
        observers.append(route)
    }

    private func loadArtwork() {
        guard let artworkURL, let url = URL(string: artworkURL) else { return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status), let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                NowPlayingController.shared.setArtwork(image)
            }
        }.resume()
    }

    private func logTracks() async {
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return }
        _ = await MediaCheck.load(url: url, requireAudio: audioOnly)
    }
}

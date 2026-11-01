import EVPCore
import Foundation
import MediaPlayer

/// F7, F8 and F9 through the system's remote-command centre, which needs no permission. The system sends them here only
/// while this app publishes now-playing information, so EVP publishes it while a video is open (playing or paused, so F8
/// resumes what it paused) and the keys are not decoupled. Decoupled, or with no video open, the keys go to whatever
/// else wants them.
final class MediaKeys {
    private let center = MPRemoteCommandCenter.shared()
    private let decoupled: () -> Bool
    /// The window the keys act on, playing or paused: nil when no video window is open.
    private let target: () -> PlayerWindowController?
    private var commands: [MPRemoteCommand] {
        [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand, center.previousTrackCommand, center.nextTrackCommand]
    }

    init(decoupled: @escaping () -> Bool, target: @escaping () -> PlayerWindowController?) {
        (self.decoupled, self.target) = (decoupled, target)
        // The system sends play while EVP reports paused and pause while it reports playing, so each one toggles.
        let actions: [Action] = [.playPause, .playPause, .playPause, .seekBackLong, .seekForwardLong]
        for (command, action) in zip(commands, actions) {
            command.addTarget { [weak self] _ in self?.run(action) ?? .noActionableNowPlayingItem }
        }
        refresh()
    }

    /// The system may call from any thread; the windows, the engine and the state live on the main one.
    private func run(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { run(action) } }
        guard !decoupled(), let window = target() else { return .noActionableNowPlayingItem }
        window.perform(.action(action))
        return .success
    }

    /// Call whenever a window starts or stops playing, opens or closes, or the decoupling changes.
    func refresh() {
        let window = decoupled() ? nil : target()
        commands.forEach { $0.isEnabled = window != nil }
        let info = MPNowPlayingInfoCenter.default()
        guard let window else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        let playing = window.isPlaying
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "Ergonomic Video Player", MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        info.playbackState = playing ? .playing : .paused
    }
}

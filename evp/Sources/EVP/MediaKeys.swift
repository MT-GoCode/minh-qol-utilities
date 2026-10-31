import EVPCore
import MediaPlayer

/// F7, F8 and F9 through the system's remote-command centre, which needs no permission. The system sends them here only
/// while this app publishes now-playing information, so EVP publishes it only while a window is playing and the keys are
/// not decoupled. Decoupled, or with nothing playing, the keys go to whatever else wants them.
final class MediaKeys {
    private let center = MPRemoteCommandCenter.shared()
    /// The window the keys act on: nil when no window is playing.
    private let target: () -> PlayerWindowController?

    var decoupled: Bool {
        didSet { refresh() }
    }

    init(decoupled: Bool, target: @escaping () -> PlayerWindowController?) {
        (self.decoupled, self.target) = (decoupled, target)
        let bindings: [(MPRemoteCommand, Action)] = [
            (center.togglePlayPauseCommand, .playPause), (center.pauseCommand, .playPause),
            (center.previousTrackCommand, .seekBackLong), (center.nextTrackCommand, .seekForwardLong),
        ]
        for (command, action) in bindings {
            _ = command.addTarget { [weak self] _ in self?.run(action) ?? .noActionableNowPlayingItem }
        }
        refresh()
    }

    private func run(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard !decoupled, let window = target() else { return .noActionableNowPlayingItem }
        window.perform(.action(action))
        return .success
    }

    /// Call whenever a window starts or stops playing, opens or closes.
    func refresh() {
        let active = !decoupled && target() != nil
        for command in [center.togglePlayPauseCommand, center.pauseCommand, center.previousTrackCommand, center.nextTrackCommand] {
            command.isEnabled = active
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = active ? [MPMediaItemPropertyTitle: "Ergonomic Video Player", MPNowPlayingInfoPropertyPlaybackRate: 1.0] : nil
        info.playbackState = active ? .playing : .stopped
    }
}

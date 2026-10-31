import EVPCore
import Foundation
import MediaPlayer

/// F7, F8 and F9 through the system's remote-command centre, which needs no permission. The system sends them here only
/// while this app publishes now-playing information, so EVP publishes it only while a window is playing and the keys are
/// not decoupled. Decoupled, or with nothing playing, the keys go to whatever else wants them.
final class MediaKeys {
    private let center = MPRemoteCommandCenter.shared()
    private let decoupled: () -> Bool
    /// The window the keys act on: nil when no window is playing.
    private let target: () -> PlayerWindowController?
    private var commands: [MPRemoteCommand] {
        [center.togglePlayPauseCommand, center.pauseCommand, center.previousTrackCommand, center.nextTrackCommand]
    }

    init(decoupled: @escaping () -> Bool, target: @escaping () -> PlayerWindowController?) {
        (self.decoupled, self.target) = (decoupled, target)
        let actions: [Action] = [.playPause, .playPause, .seekBackLong, .seekForwardLong]
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
        let active = !decoupled() && target() != nil
        commands.forEach { $0.isEnabled = active }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = active ? [MPMediaItemPropertyTitle: "Ergonomic Video Player", MPNowPlayingInfoPropertyPlaybackRate: 1.0] : nil
        info.playbackState = active ? .playing : .stopped
    }
}

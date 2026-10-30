import Foundation

extension MpvPlayer {
    public enum Outcome: Equatable {
        /// The command was for the interface (full screen, the bar), not the engine.
        case notAnEngineCommand
        /// Done; `feedback` is the short text the bar shows ("+5s", "Speed 1.3x").
        case done(feedback: String?)
    }

    /// Runs the playback commands. Step sizes come from `settings`.
    public func perform(_ command: Command, settings: Settings) throws -> Outcome {
        switch command {
        case .seekFraction(let fraction):
            try seek(toFraction: fraction)
            return .done(feedback: nil)
        case .setVolume(let volume):
            try setVolume(volume)
            return .done(feedback: nil)
        case .action(let action):
            return try perform(action, settings: settings)
        }
    }

    private func perform(_ action: Action, settings: Settings) throws -> Outcome {
        switch action {
        case .playPause:
            let pause = try property("pause") != "yes"
            try setPaused(pause)
            return .done(feedback: pause ? "Paused" : "Playing")
        case .seekBackShort: return try seekFeedback(-settings.seekShortSeconds)
        case .seekForwardShort: return try seekFeedback(settings.seekShortSeconds)
        case .seekBackLong: return try seekFeedback(-settings.seekLongSeconds)
        case .seekForwardLong: return try seekFeedback(settings.seekLongSeconds)
        case .speedUp: return try speedFeedback { try adjustSpeed(by: settings.speedStep) }
        case .speedDown: return try speedFeedback { try adjustSpeed(by: -settings.speedStep) }
        case .speedReset: return try speedFeedback { try setSpeed(settings.defaultSpeed) }
        case .volumeUp: return try volumeFeedback(settings.volumeStep)
        case .volumeDown: return try volumeFeedback(-settings.volumeStep)
        case .jump0, .jump1, .jump2, .jump3, .jump4, .jump5, .jump6, .jump7, .jump8, .jump9:
            let fraction = action.jumpFraction ?? 0
            try seek(toFraction: fraction)
            return .done(feedback: "\(Int((fraction * 100).rounded()))%")
        case .frameBack:
            try frameStep(-1)
            return .done(feedback: "-1 frame")
        case .frameForward:
            try frameStep(1)
            return .done(feedback: "+1 frame")
        case .mute:
            let muted = try property("mute") != "yes"
            try toggleMute()
            return .done(feedback: muted ? "Muted" : "Unmuted")
        case .fullscreen, .screenshot, .toggleBar, .pauseAll:
            return .notAnEngineCommand
        }
    }

    private func seekFeedback(_ seconds: Double) throws -> Outcome {
        try seek(by: seconds)
        return .done(feedback: String(format: "%+gs", seconds))
    }

    private func speedFeedback(_ change: () throws -> Void) throws -> Outcome {
        try change()
        return .done(feedback: String(format: "Speed %gx", try speed()))
    }

    private func volumeFeedback(_ delta: Double) throws -> Outcome {
        try adjustVolume(by: delta)
        return .done(feedback: String(format: "Volume %g%%", try volume()))
    }
}

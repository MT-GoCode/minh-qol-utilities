/// Every user operation. Keys, menu items, bar buttons and media keys all name one of these.
public enum Action: String, CaseIterable, Codable {
    case playPause
    case seekBackShort, seekForwardShort, seekBackLong, seekForwardLong
    case speedUp, speedDown, speedReset
    case volumeUp, volumeDown
    case jump0, jump1, jump2, jump3, jump4, jump5, jump6, jump7, jump8, jump9
    case frameBack, frameForward
    case mute, fullscreen, screenshot, toggleBar
    case pauseAll

    private static let jumps: [Action] = [.jump0, .jump1, .jump2, .jump3, .jump4, .jump5, .jump6, .jump7, .jump8, .jump9]

    /// For `jump0`...`jump9`: the fraction of the video to jump to (0 to 0.9).
    public var jumpFraction: Double? { Self.jumps.firstIndex(of: self).map { Double($0) / 10 } }

    /// Whether holding the key keeps repeating the action. Seeking, volume, speed and frame steps do; toggles and
    /// jumps act once per press.
    public var repeatsWhenHeld: Bool {
        switch self {
        case .seekBackShort, .seekForwardShort, .seekBackLong, .seekForwardLong, .volumeUp, .volumeDown, .speedUp, .speedDown,
             .frameBack, .frameForward:
            return true
        case .playPause, .speedReset, .jump0, .jump1, .jump2, .jump3, .jump4, .jump5, .jump6, .jump7, .jump8, .jump9,
             .mute, .fullscreen, .screenshot, .toggleBar, .pauseAll:
            return false
        }
    }

    /// Whether a key-down runs the action: a held key's repeats only count for the actions that repeat.
    public func runs(onRepeat isRepeat: Bool) -> Bool { !isRepeat || repeatsWhenHeld }

    /// Actions that work while EVP is not the frontmost app.
    public static let global: Set<Action> = [.pauseAll]
}

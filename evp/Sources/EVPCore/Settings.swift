/// User settings. Defaults: seek steps 5 s and 10 s and speed step 0.1 are Minh's; the volume step of 5, the
/// 100% default volume and the 1.0x default speed are decisions recorded in DECISIONS.md.
public struct Settings: Codable, Equatable {
    public var seekShortSeconds = 5.0
    public var seekLongSeconds = 10.0
    public var speedStep = 0.1
    public var volumeStep = 5.0
    public var defaultSpeed = 1.0
    public var defaultVolume = 100.0
    public var decoupleMediaKeys = false
    public var restoreWindowsOnLaunch = true
    public var keymap = Keymap.defaults

    public init() {}
}

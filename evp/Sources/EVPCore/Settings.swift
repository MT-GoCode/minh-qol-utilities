import Foundation

extension KeyedDecodingContainer {
    /// A missing key takes `fallback`, so a file written by an older version stays readable.
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

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

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seekShortSeconds = try c.value(.seekShortSeconds, default: seekShortSeconds)
        seekLongSeconds = try c.value(.seekLongSeconds, default: seekLongSeconds)
        speedStep = try c.value(.speedStep, default: speedStep)
        volumeStep = try c.value(.volumeStep, default: volumeStep)
        defaultSpeed = try c.value(.defaultSpeed, default: defaultSpeed)
        defaultVolume = try c.value(.defaultVolume, default: defaultVolume)
        decoupleMediaKeys = try c.value(.decoupleMediaKeys, default: decoupleMediaKeys)
        restoreWindowsOnLaunch = try c.value(.restoreWindowsOnLaunch, default: restoreWindowsOnLaunch)
        keymap = try c.value(.keymap, default: keymap)
    }
}

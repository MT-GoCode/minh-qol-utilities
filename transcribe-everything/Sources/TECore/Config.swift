public struct Config: Codable, Equatable, Sendable {
    // Values and their origins: DECISIONS.md.
    public var minSilence = 0.5, maxSegment = 12.0
    public var speakerThreshold = 0.35, speakerWindow = 2.0, speakerHop = 0.5, speakerConfirmWindows = 4
    public var windowSeconds = 20.0, expandedSeconds = 60.0
    public var fontSize = 22, fontSizeRange = 12...48
    public init() {}
}

public actor ConfigStore {
    public private(set) var current: Config
    public init(_ initial: Config = Config()) { current = initial }
    public func set(_ config: Config) { current = config }
}

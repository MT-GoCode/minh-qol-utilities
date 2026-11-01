import Foundation

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
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    public func set(_ config: Config) {
        guard config != current else { return }
        current = config
        for c in subscribers.values { c.yield() }
    }
    /// Yields after every change of `current`. One stream per caller.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, c) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        c.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        subscribers[id] = c
        return stream
    }
    private func drop(_ id: UUID) { subscribers[id] = nil }
}

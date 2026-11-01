import Foundation

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public struct Config: Codable, Equatable, Sendable {
    // Values and their origins: DECISIONS.md.
    public var minSilence = 0.5, maxSegment = 12.0
    public var speakerThreshold = 0.35, speakerWindow = 2.0, speakerHop = 0.5, speakerConfirmWindows = 4
    public var windowSeconds = 20.0, expandedSeconds = 60.0
    public var fontSize = 22, fontSizeRange = 12...48
    public init() {}

    /// The file is the boundary: values the pipeline cannot run with (a zero hop never advances the window loop) stop here, once.
    public func validate() throws {
        func fail(_ why: String) -> ConfigError { ConfigError(description: why) }
        guard fontSizeRange.contains(fontSize) else {
            throw fail("fontSize \(fontSize) is outside fontSizeRange \(fontSizeRange.lowerBound)...\(fontSizeRange.upperBound)")
        }
        for (name, v) in [("minSilence", minSilence), ("maxSegment", maxSegment), ("speakerWindow", speakerWindow),
                          ("speakerHop", speakerHop), ("windowSeconds", windowSeconds), ("expandedSeconds", expandedSeconds)] {
            guard v > 0 else { throw fail("\(name) must be above 0") }
        }
        guard speakerConfirmWindows >= 1 else { throw fail("speakerConfirmWindows must be at least 1") }
        guard windowSeconds <= expandedSeconds else { throw fail("windowSeconds must not exceed expandedSeconds") }
    }
}

/// Single owner of settings. With a file, the file is the truth: `set` writes it and every reader sees what a reload of it yields.
public actor ConfigStore {
    public private(set) var current: Config
    /// Why the file is not in use; nil while it is valid. `current` keeps the last valid value.
    public private(set) var error: String?
    private let file: URL?
    private var watcher: DirectoryWatcher?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// In memory, no file.
    public init(_ initial: Config = Config()) {
        current = initial
        file = nil
    }

    private init(file: URL) {
        current = Config()
        self.file = file
    }

    /// Writes the defaults on first run, then loads and watches the file. An invalid file does not throw: defaults run and `error` says why.
    public static func open(file: URL) async throws -> ConfigStore {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { try encode(Config()).write(to: file, options: .atomic) }
        let store = ConfigStore(file: file)
        await store.start(watching: file.deletingLastPathComponent())
        return store
    }

    /// Yields after every change of `current` or `error`; a reader redraws from them, so only "changed" matters. One stream per caller.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }

    /// Read and write as one step, so a file edit landing between them is not overwritten.
    public func update(_ change: (inout Config) -> Void) throws {
        var c = current
        change(&c)
        guard c != current else { return }
        try set(c)
    }

    public func set(_ new: Config) throws {
        try new.validate()
        guard let file else { return apply(new, nil) }
        if let error { throw ConfigError(description: "config.json is invalid (\(error)); fix it first") }
        try Self.encode(new).write(to: file, options: .atomic)
        reload()
    }

    private func start(watching directory: URL) {
        // Watching starts before the first load, so an edit in between is not lost.
        watcher = DirectoryWatcher(directory) { [weak self] in Task { await self?.reload() } }
        reload()
    }

    private func reload() {
        guard let file else { return }
        do {
            let c = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
            try c.validate()
            apply(c, nil)
        } catch { apply(current, Self.reason(error)) }
    }

    private func apply(_ c: Config, _ e: String?) {
        guard (c, e) != (current, error) else { return }
        (current, error) = (c, e)
        for s in subscribers.values { s.yield() }
    }

    private func drop(_ id: UUID) { subscribers[id] = nil }

    private static func encode(_ c: Config) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(c)
    }

    private static func reason(_ error: Error) -> String {
        guard let d = error as? DecodingError else { return "\(error)" }
        switch d {
        case .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return (c.codingPath.map(\.stringValue) + [c.debugDescription]).joined(separator: " ")
        @unknown default: return "\(d)"
        }
    }
}

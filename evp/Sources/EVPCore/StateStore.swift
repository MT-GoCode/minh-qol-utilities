import Foundation

public struct Frame: Codable, Equatable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

/// What is remembered per video file.
public struct FileState: Codable, Equatable {
    public var position: Double
    public var speed: Double
    public var volume: Double

    public init(position: Double, speed: Double, volume: Double) {
        (self.position, self.speed, self.volume) = (position, speed, volume)
    }
}

public struct WindowState: Codable, Equatable {
    /// Distinguishes two windows playing the same file.
    public var id: UUID
    public var path: String
    public var frame: Frame
    public var barHidden: Bool

    public init(id: UUID = UUID(), path: String, frame: Frame, barHidden: Bool) {
        (self.id, self.path, self.frame, self.barHidden) = (id, path, frame, barHidden)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        path = try c.decode(String.self, forKey: .path)
        frame = try c.decode(Frame.self, forKey: .frame)
        barHidden = try c.value(.barHidden, default: false)
    }
}

public struct State: Codable, Equatable {
    /// The file format version this build writes and the newest it can read.
    public static let currentVersion = 1

    public let version: Int
    /// Keyed by `StateStore.fileKey(for:)`.
    public var files: [String: FileState] = [:]
    /// The windows open right now, restored on launch.
    public var windows: [WindowState] = []
    /// Most recent first; every file ever opened, the menu decides how many to show.
    public var recents: [String] = []
    public var settings = Settings()

    public init() { version = Self.currentVersion }

    /// Fields missing from an older file take their defaults; a file from a newer version is refused so its data is
    /// never silently dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: 1)
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "state version \(version) is newer than this build reads (\(Self.currentVersion))"))
        }
        files = try c.value(.files, default: [:])
        windows = try c.value(.windows, default: [])
        recents = try c.value(.recents, default: [])
        settings = try c.value(.settings, default: Settings())
    }

    /// The remembered state of a file, or the defaults for one never opened.
    public func fileState(forKey key: String) -> FileState {
        files[key] ?? FileState(position: 0, speed: settings.defaultSpeed, volume: settings.defaultVolume)
    }
}

/// The single writer of `state.json`: main thread only. Changes reach disk at most `flushInterval` after the
/// first change of a batch (a steady stream of changes still flushes every interval), through an atomic replace,
/// so a kill at any instant leaves a complete file.
public final class StateStore {
    /// One second: Minh asked for the position to be saved "constantly"; this bounds the loss to about a second.
    public static let defaultFlushInterval: TimeInterval = 1

    public private(set) var state: State
    private let url: URL
    private let flushInterval: TimeInterval
    private let onFlushError: (Error) -> Void
    private var dirty = false
    private var flushScheduled = false

    /// A corrupt existing file throws: it is never silently replaced.
    public init(directory: URL, flushInterval: TimeInterval = StateStore.defaultFlushInterval, onFlushError: @escaping (Error) -> Void) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("state.json")
        self.flushInterval = flushInterval
        self.onFlushError = onFlushError
        state = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
    }

    deinit {
        do { try flushNow() } catch { onFlushError(error) }
    }

    public static func fileKey(for url: URL) -> String { url.resolvingSymlinksInPath().path }

    public func update(_ change: (inout State) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        change(&state)
        dirty = true
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            do { try self.flushNow() } catch { self.onFlushError(error) }
        }
    }

    public func flushNow() throws {
        guard dirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(state).write(to: url, options: .atomic)
        dirty = false
    }
}

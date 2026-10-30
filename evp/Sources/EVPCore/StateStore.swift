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
    public var path: String
    public var frame: Frame
    public var barHidden: Bool

    public init(path: String, frame: Frame, barHidden: Bool) {
        (self.path, self.frame, self.barHidden) = (path, frame, barHidden)
    }
}

public struct State: Codable, Equatable {
    /// Keyed by `StateStore.fileKey(for:)`.
    public var files: [String: FileState] = [:]
    /// The windows open right now, restored on launch.
    public var windows: [WindowState] = []
    /// Most recent first; every file ever opened, the menu decides how many to show.
    public var recents: [String] = []
    public var settings = Settings()

    public init() {}

    /// The remembered state of a file, or the defaults for one never opened.
    public func fileState(forKey key: String) -> FileState {
        files[key] ?? FileState(position: 0, speed: settings.defaultSpeed, volume: settings.defaultVolume)
    }
}

/// The single writer of `state.json`: main thread only. Changes reach disk at most `flushInterval` after the
/// first change of a batch, through an atomic replace, so a kill at any instant leaves a complete file.
public final class StateStore {
    public private(set) var state: State
    private let url: URL
    private let flushInterval: TimeInterval
    private let onFlushError: (Error) -> Void
    private var dirty = false
    private var flushScheduled = false

    /// A corrupt existing file throws: it is never silently replaced.
    public init(directory: URL, flushInterval: TimeInterval = 1, onFlushError: @escaping (Error) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("state.json")
        self.flushInterval = flushInterval
        self.onFlushError = onFlushError
        state = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
    }

    public static func fileKey(for url: URL) -> String { url.resolvingSymlinksInPath().path }

    public func update(_ change: (inout State) -> Void) {
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

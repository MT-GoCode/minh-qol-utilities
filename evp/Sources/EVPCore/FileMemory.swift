import Foundation

/// Remembers where a file was left (position, speed, volume) and puts it back when the file is opened again.
/// One instance per open file; feed it every player event.
public final class FileMemory {
    private let store: StateStore
    private let key: String
    private var recording = false
    private var resumedFromMemory = false

    public init(store: StateStore, file: URL) {
        self.store = store
        key = StateStore.fileKey(for: file)
    }

    /// What is remembered about this file (the defaults of the Settings for one never opened).
    public var saved: FileState { store.state.fileState(forKey: key) }

    /// Opens `file` in `player`: speed and volume as remembered, the position where it was left unless `start` says
    /// otherwise (an explicit start always wins), and the file goes to the top of the recents. Recording starts here, so
    /// the player's initial default values can never overwrite what was remembered before it is applied.
    public func open(_ file: URL, in player: MpvPlayer, start: Double? = nil) throws {
        let remembered = saved
        try player.setSpeed(remembered.speed)
        try player.setVolume(remembered.volume)
        resumedFromMemory = start == nil && remembered.position > 0
        try player.load(file, start: start ?? (remembered.position > 0 ? remembered.position : nil))
        recording = true
        store.update { $0.recents = [self.key] + $0.recents.filter { $0 != self.key } }
    }

    /// Call for every player event. Records position, speed and volume; once the file has loaded, a video that was left
    /// within `ResumePolicy.endMargin` of its end starts over.
    public func handle(_ event: MpvPlayer.Event, player: MpvPlayer) throws {
        guard recording else { return }
        switch event {
        case .fileLoaded:
            guard resumedFromMemory, let text = try player.property("duration"), let duration = Double(text) else { return }
            resumedFromMemory = false
            if ResumePolicy.startPosition(saved: saved.position, duration: duration) == 0 { try player.seek(to: 0) }
        case .time(let seconds) where seconds.isFinite:
            update { $0.position = seconds }
        case .speed(let speed):
            update { $0.speed = speed }
        case .volume(let volume):
            update { $0.volume = volume }
        default:
            break
        }
    }

    private func update(_ change: @escaping (inout FileState) -> Void) {
        store.update { state in
            var file = state.fileState(forKey: self.key)
            change(&file)
            state.files[self.key] = file
        }
    }
}

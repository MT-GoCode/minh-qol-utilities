import Foundation

/// Something that plays and can be paused: a player window.
public protocol Pausable: AnyObject {
    func isPaused() throws -> Bool
    func setPaused(_ paused: Bool) throws
}

extension MpvPlayer: Pausable {
    public func isPaused() throws -> Bool { try property("pause") == "yes" }
}

/// The global pause key: the first press pauses every video that is playing and remembers which; the next press resumes
/// exactly those, not videos the user paused by hand and not ones that were opened since. A resume that throws keeps
/// the whole set remembered, so the next press retries it.
public final class PauseAll {
    private struct Remembered {
        weak var player: Pausable?
    }

    private var remembered: [Remembered] = []

    public init() {}

    /// One press of the key over `players` (every open window's player).
    public func press(over players: [Pausable]) throws {
        let toResume = remembered.compactMap(\.player)
        if !toResume.isEmpty {
            for player in toResume { try player.setPaused(false) }
            remembered = []
            return
        }
        for player in players where try !player.isPaused() {
            try player.setPaused(true)
            remembered.append(Remembered(player: player))
        }
    }
}

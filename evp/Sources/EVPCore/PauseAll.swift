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
/// exactly those that are still paused, not videos the user paused by hand and not ones that were opened since. A
/// resume that throws keeps the whole set remembered, so the next press retries it. If the user already resumed all
/// of them by hand, the press pauses what plays, as if nothing were remembered. A video that cannot be paused does not
/// stop the others: the press pauses them all and then throws the first error.
public final class PauseAll {
    private struct Remembered {
        weak var player: Pausable?
    }

    private var remembered: [Remembered] = []

    public init() {}

    /// One press of the key over `players` (every open window's player).
    public func press(over players: [Pausable]) throws {
        let toResume = try remembered.compactMap(\.player).filter { try $0.isPaused() }
        if !toResume.isEmpty {
            for player in toResume { try player.setPaused(false) }
            remembered = []
            return
        }
        remembered = []
        var failure: Error?
        for player in players {
            do {
                guard try !player.isPaused() else { continue }
                try player.setPaused(true)
                remembered.append(Remembered(player: player))
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }
}

import Foundation
import os

/// Capture delivers buffers continuously, silence included, so a gap longer than `limit` means capture stopped.
public final class StallGuard: Sendable {
    public static let limit: Duration = .seconds(1)  // DECISIONS: 15× the largest measured gap
    public struct Stalled: Error, CustomStringConvertible {
        public let limit: Duration
        public var description: String { "no audio buffers for more than \(limit)" }
    }
    public let limit: Duration
    private let last = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    public init(limit: Duration = StallGuard.limit) { self.limit = limit }
    public func beat() { last.withLock { $0 = .now } }

    /// Counts from the call. Throws `Stalled` at the first gap of `limit`; returns when cancelled.
    public func watch() async throws {
        beat()
        while true {
            let seen = last.withLock { $0 }
            do { try await Task.sleep(until: seen.advanced(by: limit), clock: .continuous) } catch { return }  // only CancellationError
            if last.withLock({ $0 }) == seen { throw Stalled(limit: limit) }
        }
    }
}

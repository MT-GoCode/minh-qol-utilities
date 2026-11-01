import FluidAudio
import Foundation
import os

public final class FileSource: AudioSource {
    public let id: SourceID, tag: String
    private let samples: [Float]
    private let pacer: (@Sendable () -> @Sendable (Int) async throws -> Void)?
    private let continuation = OSAllocatedUnfairLock<AsyncThrowingStream<Chunk, Error>.Continuation?>(initialState: nil)

    public convenience init(url: URL, id: SourceID, tag: String) throws { try self.init(url, id, tag, nil) }

    public convenience init<C: Clock<Duration>>(url: URL, id: SourceID, tag: String, clock: C) throws {
        try self.init(url, id, tag) {
            let start = clock.now
            // Absolute deadlines: relative sleeps would accumulate overshoot and drift real-time bounds.
            return { i in try await clock.sleep(until: start.advanced(by: .seconds(Double(i) / Double(Chunk.sampleRate))), tolerance: nil) }
        }
    }

    private init(_ url: URL, _ id: SourceID, _ tag: String, _ pacer: (@Sendable () -> @Sendable (Int) async throws -> Void)?) throws {
        self.id = id
        self.tag = tag
        self.pacer = pacer
        samples = try AudioConverter().resampleAudioFile(url)
    }

    public func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            continuation.withLock { $0 = c }
            let task = Task {
                do {
                    let wait = pacer?()
                    for lo in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
                        try Task.checkCancellation()
                        try await wait?(lo)
                        c.yield(Chunk(samples: Array(samples[lo..<min(lo + VadManager.chunkSize, samples.count)]), index: lo))
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() { continuation.withLock { $0?.finish() } }
}

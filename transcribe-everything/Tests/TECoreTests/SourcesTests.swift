import AVFoundation
import TECore
import XCTest

final class RecordingClock: Clock, @unchecked Sendable {
    let now = ContinuousClock.now
    let minimumResolution = Duration.zero
    private let lock = NSLock()
    private var recorded: [ContinuousClock.Instant] = []
    var deadlines: [ContinuousClock.Instant] { lock.withLock { recorded } }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws { lock.withLock { recorded.append(deadline) } }
}

final class SourcesTests: XCTestCase {
    private let id = SourceID(rawValue: "f")

    func testChunksTileTheFileOnTheVadGrid() async throws {
        let url = Fixtures.turnWav(0)
        let chunks = try await collect(FileSource(url: url, id: id, tag: "t"))
        let n = try AVAudioFile(forReading: url).length
        for (k, c) in chunks.enumerated() { XCTAssertEqual(c.index, k * 4096) }
        for c in chunks.dropLast() { XCTAssertEqual(c.samples.count, 4096) }
        XCTAssertTrue((1...4096).contains(chunks.last!.samples.count))
        XCTAssertEqual(Int64(chunks.map(\.samples.count).reduce(0, +)), n)
    }

    func testPacedSourceWaitsForEachChunksAbsoluteDeadline() async throws {
        let clock = RecordingClock()
        let chunks = try await collect(FileSource(url: Fixtures.turnWav(0), id: id, tag: "t", clock: clock))
        let start = clock.now
        XCTAssertEqual(clock.deadlines, chunks.map { start.advanced(by: .seconds(Double($0.index) / 16000)) })
    }

    func testStopEndsTheStreamEarly() async throws {
        let source = try FileSource(url: Fixtures.turnWav(0), id: id, tag: "t", clock: ContinuousClock())
        var received = 0
        for try await _ in source.chunks() {
            received += 1
            if received == 1 { source.stop() }
        }
        XCTAssertLessThan(received, 12)
    }
}

import Foundation
import TECore
import XCTest

final class OracleTests: XCTestCase {
    func testEveryTurnIsTextIdenticalToTheFluidAudioCLI() async throws {
        let tr = try await Transcriber.load()
        let truth = try Fixtures.turns()
        XCTAssertEqual(truth.count, 12)
        var totalE = 0, totalW = 0
        var table = "| turn | truth | ours | errors/words |\n|---|---|---|---|\n"
        for i in truth.indices {
            let samples = try await collect(FileSource(url: Fixtures.turnWav(i), id: SourceID(rawValue: "turn\(i)"), tag: "t")).flatMap(\.samples)
            XCTAssertLessThan(samples.count, 480_000)  // over this the CLI takes its disk-backed path
            let ours = try await tr.transcribe(samples).text
            XCTAssertEqual(ours, try Fixtures.oracleText(i))
            let (e, w) = wer(ref: truth[i].text, hyp: ours)
            totalE += e
            totalW += w
            table += "| \(i) | \(truth[i].text) | \(ours) | \(e)/\(w) |\n"
        }
        table += "| corpus | | | \(totalE)/\(totalW) |\n"
        try table.write(to: resultsDir().appending(path: "oracle.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(totalE, 6)
        XCTAssertEqual(totalW, 242)
    }

    func testAudioUnderPointThreeSecondsIsPaddedNotRejected() async throws {
        let tr = try await Transcriber.load()
        _ = try await tr.transcribe([Float](repeating: 0, count: 1600))
    }

    func testWerOnKnownCases() {
        XCTAssertTrue(wer(ref: "The cat, sat!", hyp: "the dog sat") == (1, 3))
        XCTAssertTrue(wer(ref: "it's", hyp: "its") == (1, 1))
        XCTAssertTrue(wer(ref: "a b", hyp: "") == (2, 2))
    }
}

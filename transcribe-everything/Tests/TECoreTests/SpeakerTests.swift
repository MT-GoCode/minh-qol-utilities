import FluidAudio
import Foundation
import TECore
import XCTest

private func refs(rttm name: String) throws -> [SpeakerRef] {
    try String(contentsOf: Fixtures.dir.appending(path: name), encoding: .utf8).split(separator: "\n").map {
        let f = $0.split(separator: " ")
        return SpeakerRef(start: Double(f[3])!, end: Double(f[3])! + Double(f[4])!, spk: String(f[7]))
    }
}

final class SpeakerTests: XCTestCase {
    private let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]

    private func labels(_ t: CentroidTracker, _ windows: [[Float]]) async -> [Int] {
        var out: [Int] = []
        for w in windows { out.append(await t.assign(window: w, threshold: 0.35, confirmWindows: 4)) }
        return out
    }

    func testTrackerNeedsFourConsecutiveWindowsForANewSpeaker() async {
        let t = CentroidTracker()
        var previous = await t.previous
        XCTAssertEqual(previous, 1)
        var got = await labels(t, [a, a, a, a, b, b, b])
        XCTAssertEqual(got, [1, 1, 1, 1, 1, 1, 1])
        got = await labels(t, [b, a, b])
        XCTAssertEqual(got, [2, 1, 2])
        previous = await t.previous
        XCTAssertEqual(previous, 2)
        got = await labels(CentroidTracker(), [a, a, a, a, b, b, b, a, b, b, b, b])
        XCTAssertEqual(got, [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2])  // a match clears the pending run
    }

    func testWordsJoinToTheDecodeText() async throws {
        let tr = try await Models.transcriber.value
        for i in 0..<12 {
            let samples: [Float] = try await collect(FileSource(url: Fixtures.turnWav(i), id: SourceID(rawValue: "t"), tag: "t")).flatMap { $0.samples }
            let r = try await tr.transcribe(samples)
            XCTAssertEqual(buildWordTimings(from: r.tokenTimings!).map(\.word).joined(separator: " "), r.text)
        }
    }

    /// Per word, one-to-one mapping: a spurious speaker costs its words. Words come from one whole-file decode, independent of the pipeline.
    private func speakerCase(_ name: String, _ wav: URL, _ ref: [SpeakerRef], found ok: (Int) -> Bool, accuracy bound: Double) async throws {
        let id = SourceID(rawValue: name)
        let (lines, ends, file) = try await runToEnd([FileSource(url: wav, id: id, tag: name)], temporaryRoot(self))
        XCTAssertNil(ends[0].error)
        try? FileManager.default.removeItem(at: resultsDir().appending(path: "speakers-\(name).jsonl"))
        try FileManager.default.copyItem(at: file, to: resultsDir().appending(path: "speakers-\(name).jsonl"))
        let samples: [Float] = try await collect(FileSource(url: wav, id: id, tag: name)).flatMap { $0.samples }
        let words = buildWordTimings(from: try await Models.transcriber.value.transcribe(samples).tokenTimings!)
        let found = Set(lines.map(\.spk)).count
        let accuracy = speakerAccuracy(lines, midpoints: words.map { ($0.startTime + $0.endTime) / 2 }, truth: ref)
        let row = "| \(name) | \(found) | \(String(format: "%.1f%%", accuracy * 100)) | \(words.count) | \(Int(bound * 100))% |\n"
        try row.write(to: resultsDir().appending(path: "speakers-\(name).md"), atomically: true, encoding: .utf8)  // one file per clip: these tests run in parallel
        XCTAssertTrue(ok(found), "found \(found)")
        XCTAssertGreaterThanOrEqual(accuracy, bound)
    }

    // Bounds: DECISIONS measurement minus 2 points.
    func testConversation() async throws {
        let ref = try Fixtures.turns().map { SpeakerRef(start: $0.start, end: $0.end, spk: $0.speaker) }
        try await speakerCase("conversation", Fixtures.conversationWav, ref, found: { $0 == 3 }, accuracy: 0.92)
    }
    func testAmi() async throws { try await speakerCase("ami", Fixtures.dir.appending(path: "ami.wav"), refs(rttm: "ami.rttm"), found: { $0 <= 5 }, accuracy: 0.94) }
    func testVox2() async throws { try await speakerCase("vox2", Fixtures.dir.appending(path: "vox2.wav"), refs(rttm: "vox2.rttm"), found: { $0 <= 4 }, accuracy: 0.90) }
    func testVox3() async throws { try await speakerCase("vox3", Fixtures.dir.appending(path: "vox3.wav"), refs(rttm: "vox3.rttm"), found: { $0 == 3 }, accuracy: 0.97) }
    func testVox4() async throws { try await speakerCase("vox4", Fixtures.dir.appending(path: "vox4.wav"), refs(rttm: "vox4.rttm"), found: { $0 == 4 }, accuracy: 0.96) }
    func testVox6() async throws { try await speakerCase("vox6", Fixtures.dir.appending(path: "vox6.wav"), refs(rttm: "vox6.rttm"), found: { $0 == 6 }, accuracy: 0.91) }
    func testVox9() async throws { try await speakerCase("vox9", Fixtures.dir.appending(path: "vox9.wav"), refs(rttm: "vox9.rttm"), found: { $0 == 9 }, accuracy: 0.88) }

    func testReattachKeepsLabels() async throws {
        let id = SourceID(rawValue: "conv")
        let (engine, store) = try await makeEngine(temporaryRoot(self))
        await engine.attach(try FileSource(url: Fixtures.conversationWav, id: id, tag: "conv"))
        _ = await awaitEnds(engine, 1)
        let first = await store.snapshot().lines
        await engine.attach(try FileSource(url: Fixtures.conversationWav, id: id, tag: "conv"))
        _ = await awaitEnds(engine, 1)
        let second = Array(await store.snapshot().lines[first.count...])
        let turns = try Fixtures.turns()
        XCTAssertTrue(Set(second.map(\.spk)).isSubset(of: Set(first.map(\.spk))))
        XCTAssertLessThan(splits(second) { turnOf($0, turns) }, splits(first) { turnOf($0, turns) })  // known voices are recognized at once
    }
}

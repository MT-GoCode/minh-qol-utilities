import FluidAudio
import Foundation
import TECore
import XCTest

final class PipelineTests: XCTestCase {
    private let convID = SourceID(rawValue: "conv"), contID = SourceID(rawValue: "cont")
    private func conv() throws -> FileSource { try FileSource(url: Fixtures.conversationWav, id: convID, tag: "conv") }
    private func cont() throws -> FileSource { try FileSource(url: Fixtures.continuousWav, id: contID, tag: "cont") }
    private func cuts(_ lines: [Line]) -> Int { zip(lines, lines.dropFirst()).filter { $1.start == $0.end && $1.spk == $0.spk }.count }

    func testConversationBecomesFourteenLinesMappedToTheTwelveTurns() async throws {
        let (lines, ends, file) = try await runToEnd([conv()], temporaryRoot(self))
        let turns = try Fixtures.turns()
        XCTAssertEqual(ends.count, 1)
        XCTAssertNil(ends[0].error)
        XCTAssertTrue(lines.allSatisfy { $0.src == convID && $0.tag == "conv" && !$0.text.isEmpty })
        XCTAssertEqual(lines.count, 14 + splits(lines) { turnOf($0, turns) })
        XCTAssertEqual(cuts(lines), 2)

        var groups = [[Line]](repeating: [], count: turns.count)
        for l in lines {
            let mid = (l.start + l.end) / 2
            let i = try XCTUnwrap(turns.firstIndex { $0.start <= mid && mid <= $0.end }, "line outside every turn: \(l)")
            groups[i].append(l)
        }
        var table = "| turn | lines | start-end | errors (ours/oracle) | text |\n|---|---|---|---|---|\n"
        var sumE = 0, sumO = 0
        for (i, group) in groups.enumerated() {
            let g = try XCTUnwrap(group.first == nil ? nil : group, "turn \(i) has no line")
            let text = g.map(\.text).joined(separator: " ")
            let e = wer(ref: turns[i].text, hyp: text).errors, o = wer(ref: turns[i].text, hyp: try Fixtures.oracleText(i)).errors
            XCTAssertLessThanOrEqual(e, o + g.count, "turn \(i)")  // one framing word per line: DECISIONS
            sumE += e
            sumO += o
            let w = try Fixtures.oracleWords(i)
            XCTAssertLessThanOrEqual(abs(g.first!.start - (turns[i].start + w.first!.start)), 0.5, "turn \(i) start")
            XCTAssertLessThanOrEqual(abs(g.last!.end - (turns[i].start + w.last!.end)), 0.5, "turn \(i) end")
            table += "| \(i) | \(g.count) | \(g.first!.start)-\(g.last!.end) | \(e)/\(o) | \(text) |\n"
        }
        XCTAssertLessThanOrEqual(sumE, sumO + 2)
        table += "| corpus | \(lines.count) | | \(sumE)/\(sumO) | |\n"
        try table.write(to: resultsDir().appending(path: "pipeline.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: resultsDir().appending(path: "pipeline-conversation.jsonl"))
        try FileManager.default.copyItem(at: file, to: resultsDir().appending(path: "pipeline-conversation.jsonl"))
    }

    func testContinuousSpeechIsForceCutAndLosesNoWords() async throws {
        let (lines, _, _) = try await runToEnd([cont()], temporaryRoot(self))
        let samples: [Float] = try await collect(cont()).flatMap { $0.samples }
        let whole = try await Models.transcriber.value.transcribe(samples).text
        let truth = try Fixtures.continuousText()
        XCTAssertEqual(lines.count, 5 + splits(lines) { _ in 0 })
        XCTAssertEqual(cuts(lines), 4)
        XCTAssertTrue(lines.allSatisfy { $0.end - $0.start <= 12.0 + 4096.0 / 16000 && !$0.text.isEmpty })
        for (a, b) in zip(lines, lines.dropFirst()) { XCTAssertGreaterThanOrEqual(b.start, a.end) }
        let (e, w) = wer(ref: truth, hyp: lines.map(\.text).joined(separator: " "))
        XCTAssertEqual(w, 159)
        XCTAssertLessThanOrEqual(e, wer(ref: truth, hyp: whole).errors + 4)
    }

    func testVadGridDoesNotDependOnTheSourcesBufferSize() async throws {
        let (a, _, _) = try await runToEnd([conv()], temporaryRoot(self))
        let (b, _, _) = try await runToEnd([RechunkedSource(base: conv(), size: 3000)], temporaryRoot(self))
        XCTAssertEqual(segs(b, src: "conv"), segs(a, src: "conv"))
    }

    func testStreamEndingMidSpeechCommitsTheOpenSegment() async throws {
        let root = temporaryRoot(self)
        let last = try Fixtures.turns().last!
        let n = Int((last.end - 1.0) * 16000)
        let trunc = try truncated(Fixtures.conversationWav, frames: n, in: root)
        let (lines, ends, _) = try await runToEnd([FileSource(url: trunc, id: convID, tag: "conv")], root)
        XCTAssertNil(ends[0].error)
        let delivered = try await collect(FileSource(url: trunc, id: convID, tag: "conv")).map(\.samples.count).reduce(0, +)
        XCTAssertEqual(lines.last!.end, Double(delivered) / 16000)
        XCTAssertGreaterThanOrEqual(lines.last!.start, last.start - 0.5)
        XCTAssertFalse(lines.last!.text.isEmpty)
    }

    func testTwoSourcesOnOneEngineKeepTheirOwnLines() async throws {
        let a = segs(try await runToEnd([conv()], temporaryRoot(self)).lines, src: "conv")
        let b = segs(try await runToEnd([cont()], temporaryRoot(self)).lines, src: "cont")
        let (lines, ends, file) = try await runToEnd([conv(), cont()], temporaryRoot(self))
        XCTAssertTrue(ends.allSatisfy { $0.error == nil })
        XCTAssertEqual(segs(lines, src: "conv"), a)
        XCTAssertEqual(segs(lines, src: "cont"), b)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, lines.count)
    }

    func testDetachCommitsTheOpenSegmentAndReportsTheEnd() async throws {
        executionTimeAllowance = 30
        let (engine, store) = try await makeEngine(temporaryRoot(self))
        await engine.attach(try FileSource(url: Fixtures.conversationWav, id: convID, tag: "conv", clock: ContinuousClock()))
        try await Task.sleep(for: .seconds(1.5))
        await engine.detach(convID)
        let ends = await awaitEnds(engine, 1)
        XCTAssertNil(ends[0].error)
        XCTAssertEqual(ends[0].id, convID)
        let lines = await store.snapshot()
        XCTAssertEqual(lines.count, 1)  // under one window: one speaker
        XCTAssertTrue((1.0...1.9).contains(lines[0].end), "\(lines[0].end)")
    }

    func testSourceFailureCommitsTheOpenSegmentThenReportsTheFailure() async throws {
        let (lines, ends, _) = try await runToEnd([FailingSource(base: conv(), failAt: 32_000)], temporaryRoot(self))
        XCTAssertTrue(ends[0].error is Boom)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].end, 32_768.0 / 16000)
    }
}

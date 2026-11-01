import Foundation
import TECore
import XCTest

final class CaptureTests: XCTestCase {
    private func samples(_ url: URL) async throws -> [Float] {
        try await collect(FileSource(url: url, id: SourceID(rawValue: "f"), tag: "f")).flatMap(\.samples)
    }
    private func text(_ lines: [Line]) -> String { lines.map(\.text).joined(separator: " ") }

    func testBeatsCloserThanTheLimitNeverStall() async throws {
        try waitForIdleMachine()
        let g = StallGuard(limit: .seconds(0.5))
        let w = Task { try await g.watch() }
        for _ in 0..<8 {
            try await sleepSeconds(0.3)
            g.beat()
        }
        w.cancel()
        try await w.value
    }

    func testASilenceOverTheLimitThrowsStalledNotBeforeTheLimit() async throws {
        executionTimeAllowance = 60
        let g = StallGuard(limit: .seconds(0.5))
        let w = Task { try await g.watch() }
        for _ in 0..<3 {
            try await sleepSeconds(0.1)
            g.beat()
        }
        let t = Date()
        g.beat()
        do {
            try await w.value
            XCTFail("no stall")
        } catch let e as StallGuard.Stalled {
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t), 0.5)
            XCTAssertEqual(e.limit, .seconds(0.5))
        }
    }

    func testMutedRestoresThePreviousState() async throws {
        let initial = try AppHarness.isMuted()
        addTeardownBlock { try? AppHarness.setMuted(initial) }
        for start in [true, false] {
            try AppHarness.setMuted(start)
            try await AppHarness.muted { XCTAssertTrue(try AppHarness.isMuted()) }
            XCTAssertEqual(try AppHarness.isMuted(), start)
            do { try await AppHarness.muted { throw Boom() } } catch is Boom {}
            XCTAssertEqual(try AppHarness.isMuted(), start)
        }
    }

    func testQuickTimeConversationMatchesOracleThreeSpeakersAndLatency() async throws {
        executionTimeAllowance = 300
        try waitForIdleMachine()
        try await AppHarness.muted {
            let tr = try await Models.transcriber.value
            let conv = try await samples(Fixtures.conversationWav)
            let embedMax = try await measureEmbedMax(tr, try await Models.embedder.value, conv)
            let pid = try await QuickTime.open(Fixtures.conversationWav, self)
            let cap = try await runCapture(self, [appSource("qt", "QuickTime", pid)]) {
                try QuickTime.play()
                try await sleepSeconds(Double(conv.count) / 16000 + captureTail)
            }
            try cap.requireNoFailure()
            try requireIdleMachine()
            let report = cap.report, s = cap.samples["qt"]!, arrivals = report.sources["qt"]!.arrivals
            let off = Double(speechOnset(s) - speechOnset(conv)) / 16000
            let drift = maxClockDrift(arrivals)
            XCTAssertLessThanOrEqual(drift, 0.5)
            XCTAssertEqual(report.ended.count, 0, "\(report.ended)")

            let turns = try Fixtures.turns()
            let shifted = report.lines.map { l -> Line in
                var m = l
                m.start -= off
                m.end -= off
                return m
            }
            let groups = turns.indices.map { i in shifted.filter { turnOf($0, turns) == i } }
            var ours = 0, oracle = 0, allCuts = 0
            let lat = Latency(records: report.decodes)
            var table = "| turn | start–end | errors ours/oracle | first text s | bound | commit s | bound | text |\n|---|---|---|---|---|---|---|---|\n"
            for (j, turn) in turns.enumerated() {
                let group = groups[j]
                XCTAssertFalse(group.isEmpty, "turn \(j) has no line")
                let o = try Fixtures.oracleText(j)
                let e = wer(ref: turn.text, hyp: text(group)).errors, eo = wer(ref: turn.text, hyp: o).errors
                XCTAssertLessThanOrEqual(e, eo + cuts(group) + captureExcessPerTurn, "turn \(j): \(text(group))")
                ours += e
                oracle += eo
                allCuts += cuts(group)

                let w = try Fixtures.oracleWords(j)
                func sample(_ x: Double) -> Int { Int((off + turn.start + x) * 16000) }
                let lastWord = wallTime(of: sample(w.last!.end), arrivals), onset = wallTime(of: sample(w.first!.start), arrivals)
                let t = try XCTUnwrap(group.map(\.t).max())
                let c = try XCTUnwrap(report.decodes.filter { $0.priority == .commit && $0.finished <= t }.max { $0.finished < $1.finished })
                XCTAssertTrue(lat.ahead(c).allSatisfy { $0.priority == .commit }, "only commits are served ahead of a commit")
                let commit = t.timeIntervalSince(lastWord), commitBound = lat.commitBound(c, embedMax: embedMax, sources: 1) + drift  // a sample's wall time is only known to the clock drift measured here
                XCTAssertLessThanOrEqual(commit, commitBound, "turn \(j) commit")
                let earlier = groups[..<j].map(\.count).reduce(0, +)
                let first = try XCTUnwrap(report.shown.first { ($0.lines["qt"] ?? 0) >= earlier && $0.tails.contains("qt") && $0.t > onset }, "turn \(j) showed no text")
                let p = try XCTUnwrap(report.decodes.filter { $0.priority == .provisional && $0.finished <= first.t }.max { $0.finished < $1.finished })
                let firstLatency = first.t.timeIntervalSince(onset), firstBound = lat.firstBound(p) + drift
                XCTAssertLessThanOrEqual(firstLatency, firstBound, "turn \(j) first text")
                table += String(format: "| %d | %.1f–%.1f | %d/%d | %.3f | %.3f | %.3f | %.3f | %@ |\n", j, turn.start, turn.end, e, eo, firstLatency, firstBound, commit, commitBound, text(group))
            }
            XCTAssertLessThanOrEqual(ours, oracle + allCuts + captureExcessTotal)

            XCTAssertEqual(Set(report.lines.map(\.spk)).count, 3)
            let words = try turns.indices.flatMap { j in try Fixtures.oracleWords(j).map { turns[j].start + ($0.start + $0.end) / 2 } }
            let accuracy = speakerAccuracy(shifted, midpoints: words, truth: turns.map { SpeakerRef(start: $0.start, end: $0.end, spk: $0.speaker) })
            XCTAssertGreaterThanOrEqual(accuracy, 0.90)  // measured 91.7 to 95.0% across runs, minus 2 points as in SpeakerTests: a new voice keeps the old label until confirmed
            table += String(format: "\nmax clock drift %.3f s, clock offset %.3f s, speaker word accuracy %.1f%%\n", drift, off, accuracy * 100)
            try table.write(to: resultsDir().appending(path: "capture.md"), atomically: true, encoding: .utf8)
            try? FileManager.default.copyItem(at: cap.transcript, to: resultsDir().appending(path: "capture-conversation.jsonl"))
        }
    }

    func testTenSecondPauseKeepsBoundariesAndTheClockOnWallTime() async throws {
        executionTimeAllowance = 180
        try waitForIdleMachine()
        try await AppHarness.muted {
            let pid = try await QuickTime.open(Fixtures.turnWav(3), self)
            let cap = try await runCapture(self, [appSource("qt", "QuickTime", pid)]) {
                try QuickTime.play()
                try await sleepSeconds(3)
                try QuickTime.pause()
                try await sleepSeconds(10)
                try QuickTime.play()
                try await sleepSeconds(11.9 - 3 + captureTail)
            }
            try cap.requireNoFailure()
            let s = cap.samples["qt"]!, lines = cap.report.lines
            let hole = try XCTUnwrap(silentRuns(s).max { $0.end - $0.start < $1.end - $1.start })
            XCTAssertLessThanOrEqual(maxClockDrift(cap.report.sources["qt"]!.arrivals), 0.5)
            XCTAssertGreaterThanOrEqual(hole.end - hole.start, 9.5)
            XCTAssertTrue(lines.contains { abs($0.end - hole.start) <= 0.5 }, "\(hole) \(lines)")
            XCTAssertTrue(lines.contains { abs($0.start - hole.end) <= 0.5 }, "\(hole) \(lines)")
            XCTAssertEqual(cap.report.ended.count, 0, "\(cap.report.ended)")
        }
    }

    func testQuittingQuickTimeEndsTheSourceWithItsLastLineCommitted() async throws {
        executionTimeAllowance = 120
        try waitForIdleMachine()
        try await AppHarness.muted {
            let pid = try await QuickTime.open(Fixtures.conversationWav, self)
            let cap = try await runCapture(self, [appSource("qt", "QuickTime", pid)]) {
                try QuickTime.play()
                try await sleepSeconds(8)
                try await QuickTime.quit()
                try await sleepSeconds(captureTail)
            }
            try cap.requireNoFailure()
            let s = cap.samples["qt"]!
            XCTAssertEqual(cap.report.ended.map(\.id), ["qt"])
            XCTAssertNil(cap.report.ended.first?.error)
            let last = try XCTUnwrap(cap.report.lines.last)
            XCTAssertGreaterThanOrEqual(last.end, lastSpeechEnd(s) - 0.5)
            XCTAssertLessThanOrEqual(last.end, Double(s.count) / 16000)
        }
    }

    func testQuickTimeAndChromeTogetherKeepOnlyTheirOwnSpeech() async throws {
        executionTimeAllowance = 300
        try waitForIdleMachine()
        try await AppHarness.muted {
            let tr = try await Models.transcriber.value
            let cont = try await samples(Fixtures.continuousWav), conv = try await samples(Fixtures.conversationWav)
            let chromeWhole = try await tr.transcribe(cont).text
            let chrome = try await Chrome.launch(self, playing: Fixtures.continuousWav)
            let pid = try await QuickTime.open(Fixtures.conversationWav, self)
            let cap = try await runCapture(self, [appSource("qt", "QuickTime", pid), appSource("ch", "Chrome", chrome.pid)]) {
                try QuickTime.play()
                try chrome.go()
                try await sleepSeconds(Double(max(conv.count, cont.count)) / 16000 + captureTail)
            }
            try cap.requireNoFailure()
            try? FileManager.default.copyItem(at: cap.transcript, to: resultsDir().appending(path: "capture-two-apps.jsonl"))
            let r = cap.report
            XCTAssertEqual(r.ended.count, 0, "\(r.ended)")
            let qt = r.lines.filter { $0.src.rawValue == "qt" }, ch = r.lines.filter { $0.src.rawValue == "ch" }
            let turns = try Fixtures.turns()
            let truth = turns.map(\.text).joined(separator: " "), contTruth = try Fixtures.continuousText()
            let oracleErrors = try turns.indices.map { wer(ref: turns[$0].text, hyp: try Fixtures.oracleText($0)).errors }.reduce(0, +)
            XCTAssertLessThanOrEqual(wer(ref: truth, hyp: text(qt)).errors, oracleErrors + cuts(qt) + captureExcessTotal, text(qt))
            XCTAssertLessThanOrEqual(wer(ref: contTruth, hyp: text(ch)).errors, wer(ref: contTruth, hyp: chromeWhole).errors + cuts(ch) + captureExcessTotal, text(ch))
            for id in ["qt", "ch"] { XCTAssertLessThanOrEqual(maxClockDrift(r.sources[id]!.arrivals), 0.5) }
            let convWords = Set(normalize(truth)), contWords = Set(normalize(contTruth))
            XCTAssertEqual(Set(normalize(text(qt))).intersection(contWords.subtracting(convWords)), [])
            XCTAssertEqual(Set(normalize(text(ch))).intersection(convWords.subtracting(contWords)), [])
        }
    }

    /// The path a person takes: the real catalog finds the window, the row's target goes through the real Session and source lookup, and captions come out.
    func testAWindowFromTheCatalogAttachedThroughTheSessionGivesCaptions() async throws {
        executionTimeAllowance = 180
        try AppHarness.displayAwake.get()
        try await AppHarness.muted {
            _ = try await QuickTime.open(Fixtures.turnWav(3), self)
            let root = temporaryRoot(self)
            let stop = root.appending(path: "stop")
            addTeardownBlock { try? Data().write(to: stop) }
            let launch = Launch(root: root, steps: [["op": "session", "bundleId": "com.apple.QuickTimePlayerX"]])
            try await launch.ready(in: root)
            try QuickTime.play()
            try await sleepSeconds(11.9 + captureTail)
            try Data().write(to: stop)
            let r = (try await launch.report.value)["results"] as! [[String: Any]]
            let turn = try Fixtures.turns()[3], text = r[0]["text"] as! String
            XCTAssertLessThanOrEqual(wer(ref: turn.text, hyp: text).errors, wer(ref: turn.text, hyp: try Fixtures.oracleText(3)).errors + captureExcessPerTurn, text)
            XCTAssertEqual(r[0]["failures"] as? [String], [])
            XCTAssertEqual(r[0]["attached"] as? [String], [String((r[0]["title"] as! String).prefix(5))], "a stop keeps the checkmark")
            XCTAssertEqual(Set(r[0]["tags"] as! [String]), [String((r[0]["title"] as! String).prefix(5))])
        }
    }

    func testStallLimitBelowTheBufferCadenceFailsTheSourceWithTheReason() async throws {
        executionTimeAllowance = 120
        try await AppHarness.muted {
            let pid = try await QuickTime.open(Fixtures.turnWav(3), self)
            let cap = try await runCapture(self, [appSource("qt", "QuickTime", pid)], extra: ["stallLimit": 0.001]) {
                try await sleepSeconds(captureTail)
            }
            XCTAssertEqual(cap.report.ended.count, 1)
            XCTAssertTrue(cap.report.ended.first?.error?.contains("no audio buffers for more than") ?? false, "\(cap.report.ended)")
        }
    }
}

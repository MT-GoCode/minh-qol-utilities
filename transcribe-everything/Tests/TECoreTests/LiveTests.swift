import FluidAudio
import Foundation
import TECore
import XCTest
import os

private struct Busy: Error {}

/// Decode time tripled at load 26 on 16 cores (DECISIONS): above the core count the latency bounds do not apply.
private func requireIdleMachine() throws {
    var load = [0.0]
    getloadavg(&load, 1)
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    if load[0] > cores {
        XCTFail("machine load \(load[0]) exceeds \(cores) cores: latency bounds do not apply")
        throw Busy()
    }
}

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    precondition(kr == KERN_SUCCESS)
    return Double(info.phys_footprint) / 1_048_576
}

private func ran(_ d: Decode) -> Double { d.finished.timeIntervalSince(d.started) }

final class LiveTests: XCTestCase {
    private let convID = SourceID(rawValue: "conv")
    private func conv() throws -> FileSource { try FileSource(url: Fixtures.conversationWav, id: convID, tag: "conv") }

    func testCommitIsServedBeforeQueuedProvisionals() async throws {
        executionTimeAllowance = 60
        let tr = try await Models.transcriber.value
        let long: [Float] = try await collect(conv()).flatMap { $0.samples }
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        var tasks: [Task<Void, Error>] = []
        func submit(_ name: String, _ audio: [Float], _ p: Priority) {
            tasks.append(Task {
                _ = try await tr.transcribe(audio, priority: p)
                log.withLock { $0.append(name) }
            })
        }
        submit("P0", long, .provisional)
        for (name, p) in [("P1", Priority.provisional), ("P2", .provisional), ("C", .commit)] {
            while await tr.pending < tasks.count { await Task.yield() }
            submit(name, Array(long.prefix(16000)), p)
        }
        for t in tasks { try await t.value }
        XCTAssertEqual(log.withLock { $0 }, ["P0", "C", "P1", "P2"])
    }

    /// Runs up to `n`, waits for the tail to equal a fresh decode of `[s, fed)`, then detaches.
    private func assertTail(from s: Int, upTo n: Int, audio: [Float]) async throws {
        let fed = n / 4096 * 4096  // every sample the pipeline has sent to the VAD
        let expected = try await Models.transcriber.value.transcribe(Array(audio[s..<fed])).text
        let (engine, store) = try await makeEngine(temporaryRoot(self))
        await engine.attach(HangingSource(base: try conv(), upTo: n))
        let deadline = Date().addingTimeInterval(60)
        while await store.snapshot().tails.first?.text != expected {
            try await Task.sleep(for: .milliseconds(10))
            if Date() > deadline {
                let got = await store.snapshot().tails.first?.text ?? "<no tail>"
                XCTFail("tail never matched a fresh decode.\nexpected: \(expected)\ngot: \(got)")
                return
            }
        }
        let tail = await store.snapshot().tails.first!
        XCTAssertEqual(tail.src, convID)
        XCTAssertEqual(tail.tag, "conv")
        await engine.detach(convID)
        let ends = await awaitEnds(engine, 1)
        XCTAssertNil(ends[0].error)
        let after = await store.snapshot()
        XCTAssertEqual(after.tails, [])
        XCTAssertEqual(after.lines.last!.end, Double(fed) / 16000)
    }

    func testProvisionalIsAFreshDecodeOfTheOpenSegmentAndCommitClearsIt() async throws {
        executionTimeAllowance = 240
        let (lines, _, _) = try await runToEnd([conv()], temporaryRoot(self))
        let turns = try Fixtures.turns()
        let audio: [Float] = try await collect(conv()).flatMap { $0.samples }
        let turn9 = lines.filter { turnOf($0, turns) == 9 }
        let s = Int((turn9.first!.start * 16000).rounded())
        try await assertTail(from: s, upTo: s + 6 * 16000, audio: audio)
        // Past the force-cut: the tail belongs to the new segment, never to a late decode of the old one.
        let cut = zip(turn9, turn9.dropFirst()).first { $1.start == $0.end && $1.spk == $0.spk }!.1
        let c = Int((cut.start * 16000).rounded())
        try await assertTail(from: c, upTo: s + 13 * 16000, audio: audio)  // the cut is decided at 12 s, after the point it picks
    }

    func testThreeSourcesInRealTimeMeetTheLatencyBounds() async throws {
        executionTimeAllowance = 300
        try requireIdleMachine()
        let tr = try await Models.transcriber.value
        let embedder = try await Models.embedder.value
        let turns = try Fixtures.turns()
        let audio: [Float] = try await collect(conv()).flatMap { $0.samples }

        // Embed durations sampled while a decode runs, because they contend for the same hardware.
        let window = Array(audio.prefix(32000))
        let contention = Task { _ = try await tr.transcribe(audio) }
        var embedMax = 0.0
        for _ in 0..<30 {
            let t = Date()
            _ = try await embedder.embed(window)
            embedMax = max(embedMax, Date().timeIntervalSince(t))
        }
        _ = try await contention.value

        let recorded = OSAllocatedUnfairLock<[Decode]>(initialState: [])
        await tr.observe { d in recorded.withLock { $0.append(d) } }
        addTeardownBlock { await tr.observe(nil) }
        let (engine, store) = try await makeEngine(temporaryRoot(self))
        let seenLock = OSAllocatedUnfairLock<[(Date, Snapshot)]>(initialState: [])
        let watcher = Task {
            for await _ in store.changes {
                let s = await store.snapshot()
                seenLock.withLock { $0.append((Date(), s)) }
            }
        }
        var start: [Date] = []
        let ids = (0..<3).map { SourceID(rawValue: "s\($0)") }
        for k in 0..<3 {
            let source = try FileSource(url: Fixtures.conversationWav, id: ids[k], tag: "c\(k)", clock: ContinuousClock())
            if k > 0 { try await Task.sleep(for: .seconds(1)) }
            start.append(Date())
            await engine.attach(source)
        }
        let ends = await awaitEnds(engine, 3)
        watcher.cancel()
        XCTAssertTrue(ends.allSatisfy { $0.error == nil })
        try requireIdleMachine()
        let lines = await store.snapshot().lines
        let records = recorded.withLock { $0 }, seen = seenLock.withLock { $0 }

        func inflight(_ r: Decode) -> Double {
            records.first { $0.started < r.submitted && r.submitted < $0.finished && $0.started != r.started }.map(ran) ?? 0
        }
        func ahead(_ r: Decode) -> [Decode] { records.filter { r.submitted <= $0.started && $0.started < r.started } }

        var table = "| source | turn | first text s | bound | commit s | bound |\n|---|---|---|---|---|---|\n"
        for k in 0..<3 {
            let own = lines.filter { $0.src == ids[k] }
            for (j, turn) in turns.enumerated() {
                let w = try Fixtures.oracleWords(j)
                let onset = start[k].addingTimeInterval(turn.start + w.first!.start)
                let lastWord = start[k].addingTimeInterval(turn.start + w.last!.end)
                let mine = own.filter { turnOf($0, turns) == j }
                let t = try XCTUnwrap(mine.map(\.t).max(), "source \(k) turn \(j) has no line")
                let c = try XCTUnwrap(records.filter { $0.priority == .commit && $0.finished <= t }.max { $0.finished < $1.finished })
                XCTAssertTrue(ahead(c).allSatisfy { $0.priority == .commit }, "only commits are served ahead of a commit")
                // DECISIONS: 1.28 s + its decode + embeds + one in-flight decode + commits queued ahead. Queue wait is never added.
                let commitBound = 1.28 + ran(c) + 3 * embedMax + inflight(c) + ahead(c).map(ran).reduce(0, +)
                let commitLatency = t.timeIntervalSince(lastWord)
                XCTAssertLessThanOrEqual(commitLatency, commitBound, "source \(k) turn \(j) commit")

                // A snapshot counts for this turn only once it holds the earlier turns' lines, whose commits cleared their tails.
                let earlier = own.filter { turnOf($0, turns) < j }.count
                let first = try XCTUnwrap(seen.first { o in
                    o.1.lines.filter { $0.src == ids[k] }.count >= earlier && o.1.tails.contains { $0.src == ids[k] }
                }?.0, "source \(k) turn \(j) showed no text")
                let p = try XCTUnwrap(records.filter { $0.priority == .provisional && $0.finished <= first }.max { $0.finished < $1.finished })
                XCTAssertLessThanOrEqual(ahead(p).filter { $0.priority == .provisional }.count, 2, "round-robin")
                // DECISIONS: 0.866 s + that decode + what it waited behind, counted from the queue.
                let firstBound = 0.866 + ran(p) + inflight(p) + ahead(p).map(ran).reduce(0, +)
                let firstLatency = first.timeIntervalSince(onset)
                XCTAssertLessThanOrEqual(firstLatency, firstBound, "source \(k) turn \(j) first text")
                table += String(format: "| %d | %d | %.3f | %.3f | %.3f | %.3f |\n", k, j, firstLatency, firstBound, commitLatency, commitBound)
            }
        }
        try table.write(to: resultsDir().appending(path: "latency.md"), atomically: true, encoding: .utf8)
    }

    func testSoak() async throws {
        executionTimeAllowance = 3600
        let tr = try await Models.transcriber.value
        let embedder = try await Models.embedder.value
        let vad = try await Models.vad.value
        let audio: [Float] = try await collect(FileSource(url: Fixtures.dir.appending(path: "ami.wav"), id: convID, tag: "t")).flatMap { $0.samples }
        var state = VadStreamState.initial()
        var offset = 0, grow = 1, embeds = 0, vadAt = 0
        var times: [Double] = [], fastest: [Double] = [], footprints: [Double] = []
        for n in 1...14_000 {  // one hour of speech at one decode per 256 ms chunk
            let len = grow * 4096
            if offset + len > audio.count { offset = 0 }
            let t0 = Date()
            _ = try await tr.transcribe(Array(audio[offset..<offset + len]), priority: .provisional)
            times.append(Date().timeIntervalSince(t0))
            grow += 1
            if grow > 46 {  // 46 chunks = 11.8 s, just under the 12 s cut
                grow = 1
                offset += 46 * 4096
            }
            while Double(embeds) < Double(n) * 7200 / 14000 {
                let e = max(32000, min(offset + 32000, audio.count))
                _ = try await embedder.embed(Array(audio[(e - 32000)..<e]))
                embeds += 1
            }
            let lo = (vadAt % (audio.count / 4096)) * 4096
            state = try await vad.processStreamingChunk(Array(audio[lo..<lo + 4096]), state: state, config: VadSegmentationConfig(minSilenceDuration: 0.5)).state
            vadAt += 1
            if n % 1000 == 0 {
                fastest.append(times.min()!)  // other load on the machine barely moves the minimum; a real slowdown does
                footprints.append(footprintMB())
                times = []
            }
        }
        var report = "| decodes | fastest ms | footprint MB |\n|---|---|---|\n"
        for i in fastest.indices { report += String(format: "| %d | %.1f | %.0f |\n", (i + 1) * 1000, fastest[i] * 1000, footprints[i]) }
        try report.write(to: resultsDir().appending(path: "soak.md"), atomically: true, encoding: .utf8)
        XCTAssertLessThanOrEqual(footprints[13] - footprints[3], 20)  // measured 4 MB
        XCTAssertLessThanOrEqual(fastest.last!, 1.2 * fastest.first!)  // slower is the defect
        XCTAssertEqual(embeds, 7200)
    }
}

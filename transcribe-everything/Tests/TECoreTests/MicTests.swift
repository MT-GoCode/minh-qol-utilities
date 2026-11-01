import AVFoundation
import CoreAudio
import Foundation
import TECore
import XCTest
import os

private enum FakeError: Error { case boom }
private struct TimedOut: Error { let what: String }

private final class FakeMic: @unchecked Sendable {
    private struct S { var starts = 0, stops = 0; var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? }
    private let s = OSAllocatedUnfairLock(initialState: S())
    private let failOn: Int?
    private let restartDelay: Double
    init(failOn: Int? = nil, restartDelay: Double = 0) {
        self.failOn = failOn
        self.restartDelay = restartDelay
    }
    var starts: Int { s.withLock { $0.starts } }
    var stops: Int { s.withLock { $0.stops } }
    var start: MicSource.Start {
        { [self] on in
            let n = s.withLock { $0.starts += 1; $0.onBuffer = on; return $0.starts }
            if n == failOn { throw FakeError.boom }
            if n > 1 { Thread.sleep(forTimeInterval: restartDelay) }
            return MicSource.Capture(device: BoundDevice(id: 7, name: "fake"), stop: { [self] in s.withLock { $0.stops += 1 } })
        }
    }
    func deviceChanged() { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil) }
    func emit(rate: Double, count: Int) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let on = s.withLock { $0.onBuffer }!
        for b in 0..<count {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            buf.frameLength = 4096
            for i in 0..<4096 { buf.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 1000 * Double(b * 4096 + i) / rate).float }
            on(buf)
        }
    }
}
private extension Double { var float: Float { Float(self) } }

/// Returns at the deadline even if `body` never ends, so a defect that hangs goes red. A task group would wait for `body`. 5 s is over four times the longest legitimate wait here.
private func within<T: Sendable>(_ what: String, seconds: Double = 5, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        let once = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: c)
        let finish: @Sendable (Result<T, Error>) -> Void = { r in
            once.withLock { pending -> CheckedContinuation<T, Error>? in
                defer { pending = nil }
                return pending
            }?.resume(with: r)
        }
        Task {
            do { finish(.success(try await body())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            finish(.failure(TimedOut(what: what)))
        }
    }
}

private func gather(_ source: MicSource) async throws -> [Chunk] {
    var out: [Chunk] = []
    for try await c in source.chunks() { out.append(c) }
    return out
}

private func zeroCrossings(_ x: [Float]) -> Int { zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count }
private func rms(_ x: [Float]) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
private func assertContiguous(_ chunks: [Chunk], file: StaticString = #filePath, line: UInt = #line) {
    var next = 0
    for c in chunks {
        XCTAssertEqual(c.index, next, file: file, line: line)
        next += c.samples.count
    }
}
private func until(_ what: String, _ cond: @escaping @Sendable () -> Bool) async throws {
    _ = try await within(what) { while !cond() { try await Task.sleep(for: .milliseconds(5)) } }
}

final class MicTests: XCTestCase {
    private func make(_ fake: FakeMic, grace: Duration = .zero) -> MicSource { MicSource(id: SourceID(rawValue: "mic"), grace: grace, start: fake.start) }

    func testBuffersBecome16kMonoOnTheSampleClock() async throws {
        for (rate, expected) in [(48000.0, 68266.7), (44100.0, 74303.9)] {
            let fake = FakeMic(), source = make(fake)
            let got = Task { try await gather(source) }
            try await until("started") { fake.starts == 1 }
            fake.emit(rate: rate, count: 50)
            source.stop()
            let chunks = try await within("collect") { try await got.value }
            let x = chunks.flatMap(\.samples)
            assertContiguous(chunks)
            XCTAssertEqual(Double(x.count), expected, accuracy: 16)  // measured filter priming: at most 11.5 samples
            XCTAssertEqual(rms(x), 0.5 / 2.0.squareRoot().float, accuracy: 0.5 / 2.0.squareRoot().float * 0.02)
            XCTAssertEqual(Double(zeroCrossings(x)), 2 * Double(x.count) * 1000 / 16000, accuracy: 2 * Double(x.count) * 1000 / 16000 * 0.02)
            XCTAssertEqual(source.tag, "Mic")
        }
    }

    func testStreamFailsWhenBuffersStopForOverOneSecond() async throws {
        try waitForIdleMachine()
        let fake = FakeMic(), source = make(fake)
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        var last = Date()
        for _ in 0..<3 {
            try await sleepSeconds(0.1)
            last = Date()  // before the emit that beats the guard, so a stall is at least the limit after it
            fake.emit(rate: 48000, count: 1)
        }
        do {
            _ = try await within("stall") { try await got.value }
            XCTFail("no stall")
        } catch is StallGuard.Stalled {
            let elapsed = Date().timeIntervalSince(last)
            XCTAssertGreaterThanOrEqual(elapsed, 1.0)
            XCTAssertLessThanOrEqual(elapsed, 2.0)
        }

        let f2 = FakeMic(), s2 = make(f2)
        let g2 = Task { try await gather(s2) }
        try await until("started") { f2.starts == 1 }
        for _ in 0..<6 {
            f2.emit(rate: 48000, count: 1)
            try await sleepSeconds(0.5)
        }
        s2.stop()
        _ = try await within("control ends cleanly") { try await g2.value }
    }

    func testConfigurationChangeRestartsOnceAndChunksResumeContiguously() async throws {
        let fake = FakeMic(), source = make(fake)
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        fake.emit(rate: 48000, count: 5)
        fake.deviceChanged()
        try await until("restarted") { fake.starts == 2 }
        try await until("counted") { source.restarts == 1 }
        fake.emit(rate: 44100, count: 5)
        source.stop()
        let chunks = try await within("collect") { try await got.value }
        assertContiguous(chunks)
        XCTAssertEqual(source.restarts, 1)
        try await until("both stopped") { fake.stops == 2 }
        let first = 5 * 4096 * 16000 / 48000
        XCTAssertEqual(Double(chunks.map(\.samples.count).reduce(0, +) - first), 7430.4, accuracy: 32)  // two priming deficits, one per converter
    }

    func testANotificationBeforeTheFirstBufferDoesNotRestart() async throws {
        let fake = FakeMic(), source = make(fake)
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        for _ in 0..<3 { fake.deviceChanged() }
        try await sleepSeconds(0.3)
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(source.restarts, 0)
        fake.emit(rate: 48000, count: 1)
        fake.deviceChanged()
        try await until("a change after audio restarts") { fake.starts == 2 }
        fake.deviceChanged()  // the restarted capture has delivered nothing yet
        try await sleepSeconds(0.3)
        XCTAssertEqual(fake.starts, 2)
        source.stop()
        _ = try await within("collect") { try await got.value }
    }

    func testStallGuardIsRearmedByARestart() async throws {
        try waitForIdleMachine()
        let fake = FakeMic(), source = make(fake)
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        fake.emit(rate: 48000, count: 1)
        try await sleepSeconds(0.6)
        fake.deviceChanged()
        try await until("restarted") { fake.starts == 2 }
        let t = Date()
        do {
            _ = try await within("stall") { try await got.value }
            XCTFail("no stall")
        } catch is StallGuard.Stalled {
            let elapsed = Date().timeIntervalSince(t)
            XCTAssertGreaterThanOrEqual(elapsed, 0.9)
            XCTAssertLessThanOrEqual(elapsed, 2.0)
        }
    }

    func testARestartSlowerThanTheStallLimitIsNotAStall() async throws {
        let fake = FakeMic(restartDelay: 1.5), source = make(fake)
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        fake.emit(rate: 48000, count: 1)
        fake.deviceChanged()
        try await until("restarted") { source.restarts == 1 }
        fake.emit(rate: 48000, count: 1)
        source.stop()
        _ = try await within("no stall") { try await got.value }
    }

    func testAFirstBufferSlowerThanTheStallLimitIsNotAStall() async throws {
        let fake = FakeMic(), source = make(fake, grace: .seconds(3))
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        try await sleepSeconds(1.5)
        fake.emit(rate: 48000, count: 1)
        source.stop()
        _ = try await within("no stall") { try await got.value }
    }

    func testACaptureThatNeverDeliversStillFailsAfterTheGrace() async throws {
        let fake = FakeMic(), source = make(fake, grace: .seconds(1))
        let got = Task { try await gather(source) }
        do {
            _ = try await within("stall") { try await got.value }
            XCTFail("no stall")
        } catch is StallGuard.Stalled {}
    }

    func testARestartThatFailsFailsTheStream() async throws {
        let fake = FakeMic(failOn: 2), source = make(fake)
        let got = Task { try await gather(source) }
        try await until("started") { fake.starts == 1 }
        fake.emit(rate: 48000, count: 1)
        fake.deviceChanged()
        do {
            _ = try await within("failure") { try await got.value }
            XCTFail("no failure")
        } catch FakeError.boom {}
    }

    /// A locked session gives the mic exact zeros (DECISIONS), so these two need Minh's unlocked screen.
    private func requireUnlockedOrSkip() throws {
        try XCTSkipIf(AppHarness.screenLocked, "screen locked: unlock the Mac and rerun ./test.sh Mic")
    }

    func testRealMicTenSecondsAdvancesWithWallClockAndIsNotSilent() async throws {
        try requireUnlockedOrSkip()
        executionTimeAllowance = 180
        let cap = try await runCapture(self, [micSource]) { try await sleepSeconds(10) }
        try cap.requireNoFailure()
        let s = cap.samples["mic"]!, a = cap.report.sources["mic"]!.arrivals, mic = try XCTUnwrap(cap.report.mic)
        XCTAssertEqual(cap.report.ended.count, 0)
        XCTAssertEqual(mic.restarts, 0)
        XCTAssertEqual(s.count, a.last!.end)
        XCTAssertLessThanOrEqual(maxClockDrift(a), 4096.0 / 16000)
        XCTAssertGreaterThanOrEqual(a.last!.wall.timeIntervalSince(a[0].wall), 9)
        XCTAssertTrue(s.contains { $0 != 0 }, "a locked or denied mic gives exact zeros")
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0, n = UInt32(MemoryLayout<UInt32>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(try XCTUnwrap(mic.device).id, &address, 0, nil, &n, &transport), noErr)
        XCTAssertEqual(transport, kAudioDeviceTransportTypeBuiltIn)
        XCTAssertTrue(cap.report.lines.allSatisfy { $0.tag == "Mic" })
        let gap = zip(a, a.dropFirst()).map { $1.wall.timeIntervalSince($0.wall) }.max()!
        let nonzero = Double(s.filter { $0 != 0 }.count) / Double(s.count)
        try "device \(mic.device!.name), default input \(mic.defaultInput ?? "none"), \(a.count) arrivals, largest gap \(gap) s, peak \(s.map(abs).max()!), rms \(rms(s)), nonzero \(nonzero)\n".write(to: resultsDir().appending(path: "mic.md"), atomically: true, encoding: .utf8)
    }

    func testRealConfigurationChangeRestartsOnceAndAudioResumes() async throws {
        try requireUnlockedOrSkip()
        executionTimeAllowance = 180
        let cap = try await runCapture(self, [micSource], extra: ["reconfigureAt": [4.0]]) { try await sleepSeconds(10) }
        try cap.requireNoFailure()
        let s = cap.samples["mic"]!, a = cap.report.sources["mic"]!.arrivals
        XCTAssertEqual(cap.report.ended.count, 0)
        XCTAssertEqual(cap.report.mic?.restarts, 1)
        XCTAssertEqual(s.count, a.last!.end)
        XCTAssertGreaterThanOrEqual(a.filter { $0.wall > a[0].wall.addingTimeInterval(4.5) }.count, 20)  // about 60 expected; a third tolerates a slow restart, not none
        XCTAssertTrue(s.contains { $0 != 0 })
    }

    /// Needs no unlocked screen: ducking of other apps does not depend on what the mic hears.
    func testQuickTimeRmsIsUnchangedByTheMicAndTagsStayApart() async throws {
        executionTimeAllowance = 240
        try await AppHarness.muted {
            let clip = Fixtures.turnWav(3)
            func run(_ sources: (Int) -> [[String: Any]]) async throws -> Captured {
                let pid = try await QuickTime.open(clip, self)
                let cap = try await runCapture(self, sources(pid)) {
                    try QuickTime.play()
                    try await sleepSeconds(11.9 + captureTail)
                }
                try await QuickTime.quit()
                try cap.requireNoFailure()
                return cap
            }
            let b1 = try await run { [appSource("qt", "QuickTime", $0)] }
            let b2 = try await run { [appSource("qt", "QuickTime", $0)] }
            let m = try await run { [appSource("qt", "QuickTime", $0), micSource] }
            func r(_ c: Captured) -> Float { speechRMS(c.samples["qt"]!) }
            let bound: Float = 0.03  // identical runs measured up to 1.14% apart; voice processing measured 54%
            XCTAssertLessThanOrEqual(abs(r(b1) - r(b2)) / r(b1), bound, "the measurement itself is unstable")
            XCTAssertLessThanOrEqual(abs(r(m) - r(b1)) / r(b1), bound, "the mic changed QuickTime's level")
            let qt = m.report.lines.filter { $0.src.rawValue == "qt" }
            XCTAssertFalse(qt.isEmpty)
            XCTAssertTrue(qt.allSatisfy { $0.tag == "QuickTime" })
            XCTAssertTrue(m.report.lines.filter { $0.src.rawValue == "mic" }.allSatisfy { $0.tag == "Mic" })
        }
    }
}

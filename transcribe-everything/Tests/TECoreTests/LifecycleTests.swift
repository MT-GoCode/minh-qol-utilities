import AppKit
import Foundation
import TECore
import TEUI
import XCTest

@MainActor final class LifecycleTests: XCTestCase {
    private let a = Target.app(bundleId: "test.a", tag: "Alpha"), b = Target.app(bundleId: "test.b", tag: "Beta")

    override func setUp() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        executionTimeAllowance = 90
    }
    private func rig(have: Set<Permission> = Set(Permission.allCases), grants: Set<Permission> = [], gate: Gate? = nil, loadFailures: Int = 0) -> Rig {
        let r = Rig(self, have: have, grants: grants, gate: gate, loadFailures: loadFailures)
        addTeardownBlock {
            await gate?.release()  // stop waits for the load; a failed test may have left the gate shut
            await r.session.stop()
        }
        return r
    }
    private func isRunning(_ r: Rig) -> Bool { r.session.state == .running }
    private func isStopped(_ r: Rig) -> Bool { r.session.state == .stopped }
    private func isStarting(_ r: Rig) -> Bool { r.session.state == .starting }

    func testLaunchGoesYellowThenGreenAndTheIconFollowsAndDoubleStartIsANoOp() async throws {
        let r = rig()
        r.session.start()
        try await eventually("running") { isRunning(r) }
        XCTAssertEqual(r.history, ["starting/yellow", "running/green"])
        XCTAssertEqual(r.status, "Running")
        XCTAssertEqual(r.files().count, 1)
        XCTAssertEqual(r.permissions.requested, [])
        r.click("Start transcription")
        try await sleepSeconds(0.2)
        XCTAssertEqual(r.c.loads, 1)
        XCTAssertEqual(r.files().count, 1)
        XCTAssertEqual(r.history, ["starting/yellow", "running/green"])
        r.click("Stop transcription")
        try await eventually("stopped") { isStopped(r) }
        XCTAssertEqual(r.dot, "grey")
        XCTAssertEqual(r.status, "Stopped")
    }

    func testOnlyMissingPermissionsAreRequestedAndAnyMissingKeepsTheEngineOff() async throws {
        let expected = "Missing permission: Screen Recording. Grant it in System Settings, then relaunch."
        let r = rig(have: [.microphone])
        r.session.start()
        try await eventually("failed") { r.session.state == .failed(expected) }
        XCTAssertEqual(r.permissions.requested, [.screenRecording])
        XCTAssertEqual(r.status, expected)
        XCTAssertEqual(r.dot, "grey")
        XCTAssertEqual(r.files(), [])
        XCTAssertEqual(r.c.loads, 0)
        r.click("Start transcription")
        try await eventually("requested again") { r.permissions.requested == [.screenRecording, .screenRecording] }
        try await eventually("failed again") { r.session.state == .failed(expected) }

        let grants = rig(have: [], grants: [.microphone])
        grants.session.start()
        try await eventually("failed") { grants.session.state == .failed(expected) }
        XCTAssertEqual(grants.permissions.requested, [.microphone, .screenRecording])

        let none = rig(have: [])
        none.session.start()
        try await eventually("failed") { none.session.state == .failed("Missing permission: Microphone, Screen Recording. Grant it in System Settings, then relaunch.") }
    }

    func testAttachWhileStoppedOrStartingIsRecordedAndAppliedOnceWhenRunning() async throws {
        let r1 = rig()
        await r1.session.toggle(a)
        XCTAssertEqual(r1.session.attached, [a])
        XCTAssertNil(r1.c.made[a.id])
        r1.session.start()
        try await eventually("tail") { await r1.tail(a.id) }
        XCTAssertEqual(r1.c.made[a.id], 1)

        let g2 = Gate(), r2 = rig(gate: g2)
        await r2.session.toggle(a)
        r2.session.start()
        try await eventually("starting") { isStarting(r2) }
        await r2.session.toggle(b)
        XCTAssertEqual(r2.session.attached, [a, b])
        XCTAssertTrue(r2.c.made.isEmpty)
        await r2.session.toggle(b)
        XCTAssertEqual(r2.session.attached, [a])
        await r2.session.toggle(b)
        await g2.release()
        try await eventually("both tails") {
            let first = await r2.tail(a.id), second = await r2.tail(b.id)
            return first && second
        }
        XCTAssertEqual(r2.c.made[a.id], 1)
        XCTAssertEqual(r2.c.made[b.id], 1)

        let g3 = Gate(), r3 = rig(gate: g3)
        r3.session.start()
        try await eventually("starting") { isStarting(r3) }
        await r3.session.toggle(b)
        await r3.session.toggle(b)
        await g3.release()
        try await eventually("running") { isRunning(r3) }
        XCTAssertTrue(r3.session.attached.isEmpty)
        XCTAssertNil(r3.c.made[b.id])
        let tail = await r3.tail(b.id)
        XCTAssertFalse(tail)
    }

    func testStopKeepsCheckmarksAndStartRestoresThemWithAFreshLookupAndANewFile() async throws {
        let r = rig()
        await r.session.toggle(a)
        r.session.start()
        try await eventually("tail") { await r.tail(a.id) }
        let file = try XCTUnwrap(r.session.core?.store.file)
        r.click("Stop transcription")
        try await eventually("stopped") { isStopped(r) }
        XCTAssertNil(r.session.core)
        XCTAssertEqual(r.session.attached, [a])
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).isEmpty, "the open segment committed")
        r.click("Start transcription")
        try await eventually("tail") { await r.tail(a.id) }
        XCTAssertEqual(r.c.made[a.id], 2)
        XCTAssertEqual(r.files().count, 2)
    }

    func testRestoringAnAppThatIsGoneUnchecksItWithTheReason() async throws {
        let r = rig()
        await r.session.toggle(a)
        await r.session.toggle(b)
        r.session.start()
        try await eventually("both tails") {
            let first = await r.tail(a.id), second = await r.tail(b.id)
            return first && second
        }
        r.click("Stop transcription")
        try await eventually("stopped") { isStopped(r) }
        r.c.gone = [b.id]
        r.click("Start transcription")
        try await eventually("tail") { await r.tail(a.id) }
        XCTAssertEqual(r.session.attached, [a])
        XCTAssertEqual(r.session.failures[b.id], "Beta: not running")
        XCTAssertNil(r.session.failures[a.id])
    }

    func testStopOrQuitDuringStartingWinsWhenTheLoadFinishes() async throws {
        for action in ["Stop transcription", "Quit"] {
            let g = Gate(), r = rig(gate: g)
            r.session.start()
            try await eventually("starting") { isStarting(r) }
            r.click(action)
            if action == "Quit" {
                try await sleepSeconds(0.3)
                XCTAssertFalse(r.c.terminated, "quit waits for the load")
            }
            await g.release()
            try await eventually("stopped") { isStopped(r) }
            if action == "Quit" { try await eventually("terminated") { r.c.terminated } }
            XCTAssertEqual(r.history, ["starting/yellow", "stopped/grey"])
            XCTAssertNil(r.session.core)
            XCTAssertEqual(r.files(), [])
            XCTAssertEqual(r.c.loads, 1)
        }
    }

    func testAThrowingLoaderFailsWithTheReasonAndStartRetries() async throws {
        let r = rig(loadFailures: 1)
        r.session.start()
        try await eventually("failed") { r.session.state == .failed("model download failed") }
        XCTAssertEqual(r.status, "model download failed")
        XCTAssertEqual(r.dot, "grey")
        XCTAssertEqual(r.files(), [])
        XCTAssertEqual(r.c.loads, 1)
        r.click("Start transcription")
        try await eventually("running") { isRunning(r) }
        XCTAssertEqual(r.c.loads, 2)
    }

    func testQuitCommitsTheOpenSegmentThenTerminates() async throws {
        let r = rig()
        await r.session.toggle(a)
        r.session.start()
        try await eventually("tail") { await r.tail(a.id) }
        let store = try XCTUnwrap(r.session.core?.store)
        let before = await store.snapshot().lines.count
        r.click("Quit")
        try await eventually("terminated") { r.c.terminated }
        let after = await store.snapshot()
        XCTAssertTrue(after.tails.isEmpty)
        XCTAssertGreaterThan(after.lines.count, before)
        XCTAssertEqual(try String(contentsOf: store.file, encoding: .utf8).split(separator: "\n").count, after.lines.count)
    }

    func testASourceThatEndsUnchecksAndCanBeAttachedAgain() async throws {
        let r = rig()
        r.c.provide[a.id] = try FileSource(url: Fixtures.turnWav(0), id: a.id, tag: "Alpha")
        r.session.start()
        try await eventually("running") { isRunning(r) }
        await r.session.toggle(a)
        try await eventually("unchecked") { r.session.attached.isEmpty }
        XCTAssertTrue(r.session.failures.isEmpty)
        let store = try XCTUnwrap(r.session.core?.store)
        let first = await store.snapshot()
        XCTAssertFalse(first.lines.isEmpty)
        XCTAssertTrue(first.lines.allSatisfy { $0.tag == "Alpha" })
        XCTAssertTrue(first.tails.isEmpty)
        r.c.provide[a.id] = try FileSource(url: Fixtures.turnWav(1), id: a.id, tag: "Alpha")
        await r.session.toggle(a)
        try await eventually("second run ended") {
            let grew = await store.snapshot().lines.count > first.lines.count
            return r.session.attached.isEmpty && grew
        }
    }

    func testAFailingSourceUnchecksWithItsReasonAndCommitsItsOpenSegment() async throws {
        let r = rig()
        r.c.provide[a.id] = FailingSource(base: try FileSource(url: Fixtures.conversationWav, id: a.id, tag: "Alpha", clock: ContinuousClock()), failAt: 49_152)  // 3.07 s: turn 0 spans 0 to 3.03 s, so a segment is open
        r.session.start()
        try await eventually("running") { isRunning(r) }
        await r.session.toggle(a)
        try await eventually("unchecked") { r.session.attached.isEmpty }
        XCTAssertEqual(r.session.failures[a.id], "Alpha: boom")
        let snapshot = await r.session.core!.store.snapshot()
        XCTAssertTrue(snapshot.tails.isEmpty)
        XCTAssertGreaterThan(snapshot.lines.count, 0)
        await r.session.toggle(a)
        XCTAssertNil(r.session.failures[a.id])
    }
}

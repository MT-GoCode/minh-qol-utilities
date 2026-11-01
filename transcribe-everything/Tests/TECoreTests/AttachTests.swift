import AppKit
import Foundation
import TECore
import TEUI
import XCTest

private func limitFileSize(to bytes: Int) -> rlimit {
    signal(SIGXFSZ, SIG_IGN)
    var old = rlimit()
    getrlimit(RLIMIT_FSIZE, &old)
    var new = old
    new.rlim_cur = rlim_t(bytes)
    setrlimit(RLIMIT_FSIZE, &new)
    return old
}
private func restoreFileSize(_ old: rlimit) {
    var o = old
    setrlimit(RLIMIT_FSIZE, &o)
}
/// An `async` test is itself a main-actor job and cannot run other main-actor jobs inside a nested spin, so test 4 is synchronous.
private func spin(_ mode: RunLoop.Mode, seconds: Double, until: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if until() { return true }
        RunLoop.current.run(mode: mode, before: Date().addingTimeInterval(0.05))
    }
    return until()
}

/// TextEdit under test control. Refuses to start if one is running: the test quits it, and it may be Minh's.
private enum TextEdit {
    static func open(_ file: URL, _ test: XCTestCase) throws {
        let running = try AppHarness.sh("/usr/bin/pgrep", ["-x", "TextEdit"]).out
        guard running.isEmpty else { throw CaptureError.tool("TextEdit is already running") }
        test.addTeardownBlock { _ = try? AppHarness.sh("/usr/bin/osascript", ["-e", "tell application \"TextEdit\" to quit saving no"]) }
        try AppHarness.sh("/usr/bin/open", ["-g", "-a", "TextEdit", file.path])
    }
    static func closeAll() throws { try AppHarness.sh("/usr/bin/osascript", ["-e", "tell application \"TextEdit\" to close every document saving no"]) }
}

@MainActor final class AttachTests: XCTestCase {
    private let notes1 = WindowCatalog.Window(bundleId: "com.apple.Notes", app: "Notes", title: "Meeting")
    private let notes2 = WindowCatalog.Window(bundleId: "com.apple.Notes", app: "Notes", title: "Todo")
    private let safari = WindowCatalog.Window(bundleId: "com.apple.Safari", app: "Safari", title: "News")
    private let notesTarget = Target.app(bundleId: "com.apple.Notes", tag: "Meeti")

    override func setUp() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        executionTimeAllowance = 90
    }
    private func rig(every: TimeInterval = 3600, settings: [NSMenuItem] = []) -> Rig {
        let r = Rig(self, every: every, settings: settings)
        addTeardownBlock { await r.session.stop() }
        return r
    }
    private func running(_ r: Rig, windows: [WindowCatalog.Window]) async throws {
        r.windows.list = windows
        await r.catalog.refresh()
        r.session.start()
        try await eventually("running") { r.session.state == .running }
    }
    private func clickApp(_ r: Rig, _ title: String) {
        let m = r.submenu(), i = m.indexOfItem(withTitle: title)
        XCTAssertNotEqual(i, -1, title)
        m.performActionForItem(at: i)
    }

    func testGroupsDedupAndOrderByAppThenBundleThenTitle() {
        func w(_ b: String, _ a: String, _ t: String) -> WindowCatalog.Window { .init(bundleId: b, app: a, title: t) }
        let got = WindowCatalog.groups([
            w("com.apple.Safari", "Safari", "News"), w("com.apple.Safari", "Safari", "News"), w("com.apple.Safari", "Safari", "Apple"),
            w("com.apple.TextEdit", "TextEdit", "B.txt"), w("com.apple.TextEdit", "TextEdit", "A.txt"), w("org.x.Safari2", "Safari", "Zed"),
        ])
        XCTAssertEqual(got, [
            [w("com.apple.Safari", "Safari", "Apple"), w("com.apple.Safari", "Safari", "News")],
            [w("org.x.Safari2", "Safari", "Zed")],
            [w("com.apple.TextEdit", "TextEdit", "A.txt"), w("com.apple.TextEdit", "TextEdit", "B.txt")],
        ])
    }

    func testClickingARowChecksAllOfThatAppsRowsAndASecondClickDetaches() async throws {
        let r = rig()
        try await running(r, windows: [notes1, notes2, safari])
        XCTAssertEqual(r.submenu().items.map { $0.isSeparatorItem ? "-" : $0.title }, ["Meeting", "Todo", "-", "News"])
        clickApp(r, "Meeting")
        try await eventually("attached") { r.session.attached == [self.notesTarget] }
        XCTAssertEqual(r.submenu().item(withTitle: "Meeting")?.state, .on)
        XCTAssertEqual(r.submenu().item(withTitle: "Todo")?.state, .on)
        XCTAssertEqual(r.submenu().item(withTitle: "News")?.state, .off)
        try await eventually("tail") { await r.tail(self.notesTarget.id) }
        let tail = await r.session.core!.store.snapshot().tails.first { $0.src == self.notesTarget.id }
        XCTAssertEqual(tail?.tag, "Meeti")
        clickApp(r, "Todo")
        try await eventually("detached") { r.session.attached.isEmpty }
        for title in ["Meeting", "Todo", "News"] { XCTAssertEqual(r.submenu().item(withTitle: title)?.state, .off, title) }
    }

    func testAnAttachedAppWithNoWindowsKeepsARowToDetach() async throws {
        let r = rig()
        try await running(r, windows: [notes1, safari])
        clickApp(r, "Meeting")
        try await eventually("attached") { r.session.attached == [self.notesTarget] }
        r.windows.list = [safari]
        await r.catalog.refresh()
        XCTAssertEqual(r.submenu().item(withTitle: "Meeti")?.state, .on)
        clickApp(r, "Meeti")
        try await eventually("detached") { r.session.attached.isEmpty }
        XCTAssertNil(r.submenu().item(withTitle: "Meeti"))
    }

    func testCatalogUpdatesWhileTheMenuIsOpenOnlyOnChangeAndOnlyWhileScreenRecordingIsGranted() {
        let r = Rig(self, every: 0.1)
        func has(_ title: String) -> Bool { r.submenu().item(withTitle: title) != nil }
        r.windows.list = [notes1]
        XCTAssertTrue(spin(.default, seconds: 3) { has("Meeting") })
        r.windows.list = [notes1, safari]
        XCTAssertTrue(spin(.eventTracking, seconds: 3) { has("News") }, "a timer that misses .eventTracking stalls while the menu is open")
        let m = r.submenu()
        _ = spin(.default, seconds: 0.5) { false }
        XCTAssertTrue(m === r.submenu(), "an unchanged list must not rebuild the menu")
        r.permissions.have.remove(.screenRecording)
        XCTAssertTrue(spin(.default, seconds: 1) { r.submenu().item(withTitle: "Screen Recording not granted")?.action == nil && has("Screen Recording not granted") })
        let n = r.windows.fetches
        _ = spin(.default, seconds: 0.5) { false }
        XCTAssertEqual(r.windows.fetches, n)
        r.permissions.have.insert(.screenRecording)
        XCTAssertTrue(spin(.default, seconds: 3) { r.windows.fetches > n })
    }

    func testAFailedSourcesReasonIsADisabledMenuRowUntilItIsAttachedAgain() async throws {
        let r = rig()
        r.c.provide[notesTarget.id] = FailingSource(base: try FileSource(url: Fixtures.conversationWav, id: notesTarget.id, tag: "Meeti", clock: ContinuousClock()), failAt: 49_152)
        try await running(r, windows: [notes1])
        clickApp(r, "Meeting")
        try await eventually("failed") { r.session.failures[self.notesTarget.id] != nil }
        let menu = r.bar.item.menu!
        XCTAssertNil(try XCTUnwrap(menu.item(withTitle: "Meeti: boom")).action)
        r.c.provide[notesTarget.id] = try FileSource(url: Fixtures.conversationWav, id: notesTarget.id, tag: "Meeti", clock: ContinuousClock())
        clickApp(r, "Meeting")
        try await eventually("reason gone") { r.bar.item.menu!.item(withTitle: "Meeti: boom") == nil }
    }

    func testAFailingFinalFlushStillClearsTheTailAndReportsTheFailure() async throws {
        let root = temporaryRoot(self)
        let wav = try truncated(Fixtures.conversationWav, frames: 48_000, in: root.appending(path: "clip"))
        let (engine, store) = try await makeEngine(root)
        let id = SourceID(rawValue: "a")
        await engine.attach(try FileSource(url: wav, id: id, tag: "A", clock: ContinuousClock()))
        try await eventually("tail") { await store.snapshot().tails.contains { $0.src == id } }
        let old = limitFileSize(to: 0)  // the file is empty, so the final commit's write fails
        defer { restoreFileSize(old) }
        let ends = await awaitEnds(engine, 1)
        restoreFileSize(old)
        XCTAssertNotNil(ends[0].error)
        let s = await store.snapshot()
        XCTAssertTrue(s.tails.isEmpty)
        XCTAssertTrue(s.lines.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.file).count, 0)
    }

    func testDeleteOldTranscriptionsKeepsOnlyTheCurrentFileAndShowsAFailure() async throws {
        let r = rig()
        let paths = Paths(root: r.root)
        _ = try TranscriptStore(paths: paths, start: Date(timeIntervalSince1970: 1))
        _ = try TranscriptStore(paths: paths, start: Date(timeIntervalSince1970: 2))
        let notes = paths.transcripts.appending(path: "notes.txt")
        try "keep".write(to: notes, atomically: true, encoding: .utf8)
        r.session.start()
        try await eventually("running") { r.session.state == .running }
        let current = try XCTUnwrap(r.session.core).store.file.lastPathComponent
        r.click("Delete old transcriptions")
        XCTAssertEqual(r.files(), [current])
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
        r.click("Stop transcription")
        try await eventually("stopped") { r.session.state == .stopped }
        r.click("Delete old transcriptions")
        XCTAssertEqual(r.files(), [])
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.transcripts.path)
        addTeardownBlock { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.transcripts.path) }
        r.click("Delete old transcriptions")
        func failure() -> NSMenuItem? { r.bar.item.menu!.items.first { $0.title.hasPrefix("Delete old transcriptions:") } }
        XCTAssertNil(try XCTUnwrap(failure()).action)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.transcripts.path)
        r.click("Delete old transcriptions")
        XCTAssertNil(failure())
    }

    func testSettingsItemsSitRightAfterTheAttachRowAndSurviveRebuilds() async throws {
        let r = rig(settings: [NSMenuItem(title: "Probe item", action: nil, keyEquivalent: "")])
        func afterAttach() -> String {
            let m = r.bar.item.menu!
            return m.item(at: m.indexOfItem(withTitle: "Attach to Apps") + 1)!.title
        }
        XCTAssertEqual(afterAttach(), "Probe item")
        r.session.start()
        try await eventually("running") { r.session.state == .running }
        XCTAssertEqual(afterAttach(), "Probe item")
    }

    func testTextEditWindowAppearsAndLeavesInTheRealWindowList() async throws {
        executionTimeAllowance = 180
        let uuid = UUID().uuidString, dir = temporaryRoot(self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "te-s10-\(uuid).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try AppHarness.displayAwake.get()
        try TextEdit.open(file, self)
        func listed() async throws -> Bool {
            let root = temporaryRoot(self)
            let report = try await Task.detached { try AppHarness.run(root: root, steps: [["op": "windows"]]) }.value
            let first = (report["results"] as! [[String: Any]])[0]
            let windows = first["windows"] as! [[String: Any]]
            return windows.contains { $0["bundleId"] as? String == "com.apple.TextEdit" && ($0["title"] as? String ?? "").contains(uuid) }
        }
        var seen = false
        for _ in 0..<10 where !seen {
            seen = try await listed()
            if !seen { try await sleepSeconds(1) }
        }
        XCTAssertTrue(seen, "window listed")
        try TextEdit.closeAll()
        var gone = false
        for _ in 0..<10 where !gone {
            gone = try await !listed()
            if !gone { try await sleepSeconds(1) }
        }
        XCTAssertTrue(gone, "window gone")
    }
}

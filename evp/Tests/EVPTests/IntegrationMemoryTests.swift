import EVPCore
import XCTest

/// Per-file memory against real media and a real state file: what is left is what comes back.
final class IntegrationMemoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("evp-memory-\(UUID().uuidString)")
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    private func store() throws -> StateStore {
        try StateStore(directory: directory, flushInterval: 60, onFlushError: { XCTFail("flush failed: \($0)") })
    }

    /// A headless player for `name` wired to a fresh memory over the shared state directory, like a window would be.
    private func open(_ name: String, store: StateStore, start: Double? = nil) throws -> (Session, FileMemory) {
        let file = try Fixtures.url(name)
        let session = try Session()
        let memory = FileMemory(store: store, file: file)
        let record = session.player.onEvent
        session.player.onEvent = { event in
            record?(event)
            do { try memory.handle(event, player: session.player) } catch { XCTFail("\(error)") }
        }
        try memory.open(file, in: session.player, start: start)
        try session.waitFor(.fileLoaded)
        return (session, memory)
    }

    func testAFileComesBackWhereItWasLeft() throws {
        let first = try store()
        let (s1, _) = try open("t.mp4", store: first)
        try s1.player.setSpeed(1.5)
        try s1.player.setVolume(60)
        try s1.player.seek(to: 12)
        try s1.waitForPosition(near: 12, within: 0.3)
        try s1.waitFor(.speed(1.5))
        try s1.waitFor(.volume(60))
        try s1.until("the position is remembered") { abs(first.state.fileState(forKey: StateStore.fileKey(for: (try? Fixtures.url("t.mp4"))!)).position - 12) < 0.5 }
        try first.flushNow()

        let (s2, _) = try open("t.mp4", store: try store())
        try s2.waitForPosition(near: 12, within: 1)
        XCTAssertEqual(try s2.player.speed(), 1.5)
        XCTAssertEqual(try s2.player.volume(), 60)
    }

    func testAFinishedVideoStartsOver() throws {
        let first = try store()
        let (s1, _) = try open("t.mp4", store: first)
        try s1.player.seek(to: 18)
        try s1.waitForPosition(near: 18, within: 0.3)
        try s1.until("the position is remembered") { first.state.files.values.first.map { $0.position > 17 } ?? false }
        try first.flushNow()

        let (s2, _) = try open("t.mp4", store: try store())
        try s2.waitForPosition(near: 0, within: 1.5)
    }

    func testAnExplicitStartBeatsTheMemory() throws {
        let first = try store()
        let (s1, _) = try open("t.mp4", store: first)
        try s1.player.seek(to: 12)
        try s1.until("the position is remembered") { first.state.files.values.first.map { $0.position > 11 } ?? false }
        try first.flushNow()

        let (s2, _) = try open("t.mp4", store: try store(), start: 3)
        try s2.waitForPosition(near: 3, within: 1)
    }

    func testEachFileKeepsItsOwnStateAndANewFileGetsTheDefaults() throws {
        let first = try store()
        let (s1, _) = try open("t.mp4", store: first)
        try s1.player.setVolume(40)
        try s1.waitFor(.volume(40))
        try first.flushNow()

        let (s2, memory) = try open("tv.mp4", store: try store())
        XCTAssertEqual(memory.saved.speed, 1)
        XCTAssertEqual(memory.saved.volume, 100, "tv.mp4 must not inherit t.mp4's volume")
        XCTAssertEqual(try s2.player.volume(), 100)
        XCTAssertEqual(try s2.player.speed(), 1)
    }

    func testRecentsListTheMostRecentFirstWithoutRepeats() throws {
        let first = try store()
        _ = try open("t.mp4", store: first)
        _ = try open("tv.mp4", store: first)
        _ = try open("t.mp4", store: first)
        let names = first.state.recents.map { URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertEqual(names, ["t.mp4", "tv.mp4"])
    }

    func testNothingIsRecordedBeforeTheFileIsOpened() throws {
        let first = try store()
        let file = try Fixtures.url("t.mp4")
        let memory = FileMemory(store: first, file: file)
        let player = try MpvPlayer()
        try memory.handle(.volume(100), player: player)
        try memory.handle(.time(5), player: player)
        XCTAssertTrue(first.state.files.isEmpty)
    }
}

import EVPCore
import XCTest

final class UnitSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("evp-session-\(UUID().uuidString)")
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    private func store() throws -> StateStore {
        try StateStore(directory: directory, flushInterval: 60, onFlushError: { XCTFail("flush failed: \($0)") })
    }

    private func window(_ path: String, x: Double = 0) -> WindowState {
        WindowState(path: path, frame: Frame(x: x, y: 0, width: 800, height: 450), barHidden: false)
    }

    func testWindowsOpenedMovedAndToggledSurviveARelaunch() throws {
        let first = try store()
        let registry = SessionRegistry(store: first)
        let (a, b) = (window("/media/a.mkv"), window("/media/b.mp4"))
        registry.opened(a)
        registry.opened(b)
        registry.moved(a.id, to: Frame(x: 100, y: 50, width: 640, height: 360))
        registry.barToggled(b.id, hidden: true)
        try first.flushNow()

        let restored = SessionRegistry(store: try store()).windows
        XCTAssertEqual(restored.map(\.path), ["/media/a.mkv", "/media/b.mp4"])
        XCTAssertEqual(restored[0].frame, Frame(x: 100, y: 50, width: 640, height: 360))
        XCTAssertEqual(restored[1].barHidden, true)
        XCTAssertEqual(restored.map(\.id), [a.id, b.id])
    }

    func testClosingAWindowForgetsItButQuittingKeepsEverything() throws {
        let first = try store()
        let registry = SessionRegistry(store: first)
        let (a, b, c) = (window("/media/a.mkv"), window("/media/b.mp4"), window("/media/c.mov"))
        [a, b, c].forEach(registry.opened)
        registry.closed(b.id)  // the user closed this one
        XCTAssertEqual(registry.windows.map(\.path), ["/media/a.mkv", "/media/c.mov"])

        registry.beginTermination()  // quitting: the windows now close one by one
        registry.closed(a.id)
        registry.closed(c.id)
        XCTAssertEqual(registry.windows.map(\.path), ["/media/a.mkv", "/media/c.mov"], "quitting must not forget the windows")
    }

    func testTwoWindowsOfOneFileAreDistinct() throws {
        let registry = SessionRegistry(store: try store())
        let (first, second) = (window("/media/a.mkv", x: 0), window("/media/a.mkv", x: 500))
        registry.opened(first)
        registry.opened(second)
        registry.closed(first.id)
        XCTAssertEqual(registry.windows.map(\.id), [second.id])
        registry.opened(second)  // opening the same window again replaces it, never duplicates
        XCTAssertEqual(registry.windows.count, 1)
    }

    func testWindowsOfDeletedFilesAreDroppedAndReported() throws {
        let first = try store()
        let registry = SessionRegistry(store: first)
        [window("/media/here.mkv"), window("/media/gone.mp4"), window("/media/also-here.mov")].forEach(registry.opened)
        let (restore, missing) = registry.windowsToRestore(fileExists: { $0 != "/media/gone.mp4" })
        XCTAssertEqual(restore.map(\.path), ["/media/here.mkv", "/media/also-here.mov"])
        XCTAssertEqual(missing.map(\.path), ["/media/gone.mp4"])
        XCTAssertEqual(registry.windows.map(\.path), ["/media/here.mkv", "/media/also-here.mov"], "the dead entry is gone from the state")
    }

    func testOpenRecentListsFileNamesWithWhereTheyWereLeft() throws {
        var state = State()
        state.recents = ["/media/lecture 3.mkv", "/media/trailer.mp4", "/media/never-played.mov"]
        state.files["/media/lecture 3.mkv"] = FileState(position: 292, speed: 1, volume: 100)
        state.files["/media/trailer.mp4"] = FileState(position: 3892, speed: 1, volume: 100)
        let entries = RecentEntry.entries(from: state)
        XCTAssertEqual(entries.map(\.title), ["lecture 3.mkv", "trailer.mp4", "never-played.mov"])
        XCTAssertEqual(entries.map(\.position), ["4:52", "1:04:52", "0:00"])
        XCTAssertEqual(entries.map(\.path), state.recents)
    }

    func testOpenRecentShowsAtMostTen() {
        var state = State()
        state.recents = (0..<25).map { "/media/file\($0).mkv" }
        let entries = RecentEntry.entries(from: state)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.title, "file0.mkv")
        XCTAssertEqual(RecentEntry.entries(from: state, limit: 3).count, 3)
    }
}

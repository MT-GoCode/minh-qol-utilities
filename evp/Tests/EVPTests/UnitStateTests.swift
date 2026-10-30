import EVPCore
import XCTest

final class UnitStateTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("evp-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func store(_ directory: URL, flushInterval: TimeInterval = 1) throws -> StateStore {
        try StateStore(directory: directory, flushInterval: flushInterval, onFlushError: { XCTFail("flush failed: \($0)") })
    }

    private func sample() -> State {
        var state = State()
        state.files["/media/a.mkv"] = FileState(position: 292.5, speed: 1.3, volume: 60)
        state.windows = [WindowState(path: "/media/a.mkv", frame: Frame(x: 10, y: 20, width: 800, height: 450), barHidden: true)]
        state.recents = ["/media/a.mkv", "/media/b.mp4"]
        state.settings.seekShortSeconds = 7
        state.settings.decoupleMediaKeys = true
        return state
    }

    func testFlushedStateSurvivesAReload() throws {
        let directory = try temporaryDirectory()
        let writer = try store(directory)
        let expected = sample()
        writer.update { $0 = expected }
        try writer.flushNow()
        XCTAssertEqual(try store(directory).state, expected)
    }

    func testChangesReachDiskWithinTheFlushIntervalButNotBefore() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("state.json")
        let writer = try store(directory, flushInterval: 0.2)
        writer.update { $0.recents = ["/media/a.mkv"] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "written before the interval elapsed")
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try store(directory).state.recents, ["/media/a.mkv"])
    }

    func testFlushNowWritesImmediately() throws {
        let directory = try temporaryDirectory()
        let writer = try store(directory, flushInterval: 60)
        writer.update { $0.recents = ["/media/a.mkv"] }
        try writer.flushNow()
        XCTAssertEqual(try store(directory).state.recents, ["/media/a.mkv"])
    }

    func testCorruptStateFileThrowsAndIsNotReplaced() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("state.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: file)
        XCTAssertThrowsError(try store(directory))
        XCTAssertEqual(try Data(contentsOf: file), garbage)
    }

    func testNeverOpenedFileUsesSettingsDefaults() {
        var state = State()
        state.settings.defaultSpeed = 1.5
        state.settings.defaultVolume = 40
        XCTAssertEqual(state.fileState(forKey: "/media/new.mkv"), FileState(position: 0, speed: 1.5, volume: 40))
        state.files["/media/new.mkv"] = FileState(position: 9, speed: 1, volume: 100)
        XCTAssertEqual(state.fileState(forKey: "/media/new.mkv").position, 9)
    }

    func testFileKeyResolvesSymlinks() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("real.mkv")
        try Data().write(to: target)
        let link = directory.appendingPathComponent("link.mkv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(StateStore.fileKey(for: link), StateStore.fileKey(for: target))
    }
}

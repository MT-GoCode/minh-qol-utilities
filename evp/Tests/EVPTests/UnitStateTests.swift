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
        state.windows = [WindowState(id: UUID(), path: "/media/a.mkv", frame: Frame(x: 10, y: 20, width: 800, height: 450), barHidden: true)]
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

    private func secondsUntilFileExists(_ file: URL, timeout: TimeInterval) -> TimeInterval? {
        let start = Date()
        while !FileManager.default.fileExists(atPath: file.path) {
            guard Date().timeIntervalSince(start) < timeout else { return nil }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return Date().timeIntervalSince(start)
    }

    func testAChangeReachesDiskAfterTheIntervalAndNotMuchLater() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("state.json")
        let interval = 0.3
        let writer = try store(directory, flushInterval: interval)
        writer.update { $0.recents = ["/media/a.mkv"] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "written before the interval elapsed")
        let elapsed = try XCTUnwrap(secondsUntilFileExists(file, timeout: 3), "never written")
        XCTAssertGreaterThanOrEqual(elapsed, interval * 0.8)
        XCTAssertLessThan(elapsed, interval * 3, "flush lagged far behind the interval")
        XCTAssertEqual(try store(directory).state.recents, ["/media/a.mkv"])
    }

    func testASteadyStreamOfChangesStillFlushesEveryInterval() throws {
        // Playback updates the position every frame: a debounce that waits for quiet would never save it.
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("state.json")
        let writer = try store(directory, flushInterval: 0.3)
        let start = Date()
        var existedMidStream = false
        while Date().timeIntervalSince(start) < 1.5 {
            writer.update { $0.recents = ["\(Date().timeIntervalSince(start))"] }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if Date().timeIntervalSince(start) > 0.9 { existedMidStream = existedMidStream || FileManager.default.fileExists(atPath: file.path) }
        }
        XCTAssertTrue(existedMidStream, "no flush while changes kept arriving")
        let onDisk = try XCTUnwrap(Double(try XCTUnwrap(try store(directory).state.recents.first)))
        XCTAssertGreaterThan(onDisk, 0.9, "the file holds a late value, so it was rewritten every interval and not once")
    }

    func testOlderStateFilesKeepTheirDataAndGainDefaults() throws {
        let old = Data(#"{"files":{"/media/a.mkv":{"position":5,"speed":1,"volume":50}},"settings":{"seekShortSeconds":7}}"#.utf8)
        let state = try JSONDecoder().decode(State.self, from: old)
        XCTAssertEqual(state.files["/media/a.mkv"]?.position, 5)
        XCTAssertEqual(state.settings.seekShortSeconds, 7)
        XCTAssertEqual(state.settings.seekLongSeconds, 10, "a setting missing from the file takes its default")
        XCTAssertEqual(state.recents, [])
        XCTAssertEqual(state.version, State.currentVersion)
    }

    func testAWindowWithoutIdOrBarFlagGainsDefaults() throws {
        let old = Data(#"{"windows":[{"path":"/media/a.mkv","frame":{"x":1,"y":2,"width":3,"height":4}}]}"#.utf8)
        let windows = try JSONDecoder().decode(State.self, from: old).windows
        XCTAssertEqual(windows.map(\.path), ["/media/a.mkv"])
        XCTAssertEqual(windows.map(\.barHidden), [false])
        XCTAssertEqual(Set(windows.map(\.id)).count, 1)
    }

    func testAFileFromANewerVersionIsRefusedNotTruncated() {
        let newer = Data(#"{"version":\#(State.currentVersion + 1),"files":{}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(State.self, from: newer))
    }

    func testAStoreFlushesWhatIsPendingWhenItIsReleased() throws {
        let directory = try temporaryDirectory()
        var writer: StateStore? = try store(directory, flushInterval: 60)
        writer?.update { $0.recents = ["/media/a.mkv"] }
        writer = nil
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

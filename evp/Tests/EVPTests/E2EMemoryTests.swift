import EVPCore
import XCTest

/// What the real app remembers between runs: per-file position, speed and volume, and the open windows. Each test
/// starts the app with its own state folder, so the saved state of whoever uses this Mac is never read or written.
final class E2EMemoryTests: E2ETestCase {
    private func seconds(_ time: String) -> Double? {
        if case .absolute(let value)? = TimeFormat.parse(time) { return value }
        return nil
    }

    private func stateFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evp-home-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Waits until the app has `count` player windows and returns them, in a stable order.
    private func windows(_ count: Int) throws -> [WindowInfo] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let found = try? app!.playerWindows(), found.count == count { return found.sorted { ($0.x, $0.y) < ($1.x, $1.y) } }
            usleep(200_000)
        }
        throw Failure(description: "never saw \(count) player windows")
    }

    func testAKilledAppResumesAtTheSamePositionSpeedAndVolume() throws {
        let home = try stateFolder()
        let video = try Fixtures.url("tv.mp4").path
        app = try RunningApp.launch([video], home: home)
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }
        for _ in 0..<3 { try app!.key("d") }
        for _ in 0..<2 { try app!.key("down") }
        try app!.key("5")  // 50% of the 20 s video
        try app!.press("play-pause")
        _ = try app!.wait(for: "play-pause") { $0 == "▶" }
        let left = try XCTUnwrap(self.seconds(try app!.wait(for: "time") { abs((self.seconds($0) ?? 0) - 10) <= 1.5 }))
        _ = try app!.wait(for: "speed") { $0 == "1.3x" }
        _ = try app!.wait(for: "volume") { Double($0) == 90 }
        usleep(2_000_000)  // longer than the 1 s flush interval, so the last change has reached the disk

        try app!.crash()

        app = try RunningApp.launch([video], home: home)
        XCTAssertEqual(try app!.wait(for: "speed") { $0 == "1.3x" }, "1.3x")
        XCTAssertEqual(Double(try app!.wait(for: "volume") { Double($0) == 90 }), 90)
        _ = try app!.wait(for: "time") { abs((self.seconds($0) ?? 0) - left) <= 2 }
    }

    func testEveryWindowComesBackAtItsFramePausedAtItsPosition() throws {
        let home = try stateFolder()
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path, try Fixtures.url("t.mp4").path], home: home)
        let before = try windows(2)
        sleep(3)  // both videos play, so both leave a position past 0:01
        try app!.terminate()

        app = try RunningApp.launch([], home: home)
        let after = try windows(2)
        for (was, now) in zip(before, after) {
            for (name, a, b) in [("x", now.x, was.x), ("y", now.y, was.y), ("width", now.width, was.width), ("height", now.height, was.height)] {
                XCTAssertEqual(a, b, accuracy: 2, "a restored window's \(name) differs")
            }
        }
        XCTAssertEqual(try app!.read("play-pause"), "▶", "a restored window waits paused, so reopening is silent")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }
    }

    func testOpeningASavedFileAtLaunchGivesOneWindowNotTwo() throws {
        let home = try stateFolder()
        let (first, second) = (try Fixtures.url("tv.mp4").path, try Fixtures.url("t.mp4").path)
        app = try RunningApp.launch([first, second], home: home)
        _ = try windows(2)
        try app!.terminate()

        app = try RunningApp.launch([first], home: home)
        _ = try windows(2)
        sleep(2)  // a duplicate would open after the restore loop
        XCTAssertEqual(try app!.playerWindows().count, 2, "the file opened at launch was restored a second time")
    }
}

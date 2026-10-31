import EVPCore
import XCTest

/// Minh's keys, typed into the real app with real key events posted to its process.
final class E2EKeysTests: E2ETestCase {
    private func seconds(_ timeLabel: String) -> Double? {
        guard let shown = timeLabel.split(separator: "/").first, case .absolute(let value)? = TimeFormat.parse(String(shown)) else { return nil }
        return value
    }

    private func key(_ chord: String, expectFeedback feedback: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        try app!.key(chord)
        guard let feedback else { return }
        XCTAssertEqual(try app!.wait(for: "feedback") { $0 == feedback }, feedback, file: file, line: line)
    }

    func testMinhsKeysDriveThePlayer() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }

        try key("space", expectFeedback: "Paused")
        XCTAssertEqual(try app!.wait(for: "play-pause") { $0 == "▶" }, "▶")
        let start = try XCTUnwrap(seconds(try app!.read("time")))

        try key("right", expectFeedback: "+5s")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= start + 4 }
        try key("l", expectFeedback: "+10s")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= start + 14 }
        try key("left", expectFeedback: "-5s")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 99) <= start + 10 }
        try key("j", expectFeedback: "-10s")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 99) <= start + 1 }
        try key("5", expectFeedback: "50%")
        _ = try app!.wait(for: "time") { abs((self.seconds($0) ?? 0) - 10) <= 1 }

        for _ in 0..<3 { try key("d") }
        XCTAssertEqual(try app!.wait(for: "speed") { $0 == "1.3x" }, "1.3x")
        try key("s", expectFeedback: "Speed 1.2x")
        XCTAssertEqual(try app!.wait(for: "speed") { $0 == "1.2x" }, "1.2x")

        try key("m", expectFeedback: "Muted")
        try key(".", expectFeedback: "+1 frame")
        try key(",", expectFeedback: "-1 frame")
        try key("up", expectFeedback: "Volume 100%")
        try key("down", expectFeedback: "Volume 95%")
        XCTAssertEqual(Double(try app!.wait(for: "volume") { Double($0) == 95 }), 95)

        // ctrl+space is the global pause-all hotkey, not the window's: the window must leave it alone and stay up.
        try app!.key("ctrl+space")
        XCTAssertEqual(try app!.read("feedback"), "Volume 95%")
        XCTAssertEqual(try app!.read("play-pause"), "▶")
    }

    /// A button with focus would activate on the space bar by itself; the keymap must take the key first so space
    /// toggles exactly once.
    func testSpaceTogglesOnceEvenWhenAButtonHasFocus() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }
        try app!.focus("play-pause")
        try app!.key("space")
        XCTAssertEqual(try app!.wait(for: "play-pause") { $0 == "▶" }, "▶")
        usleep(700_000)
        XCTAssertEqual(try app!.read("play-pause"), "▶", "space toggled twice: once by the keymap, once by the focused button")
        XCTAssertEqual(try app!.read("feedback"), "Paused")
    }

    /// A held key reaches the app as a stream of key-downs; macOS drops synthetic ones flagged as repeats, so this sends
    /// 20 plain presses, and the rule that toggles ignore repeats is covered by `UnitKeyChordTests`.
    func testTwentyPressesInARowAllApply() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }
        // Volume down by 5 twenty times reaches exactly zero only if every press was applied.
        try app!.key("down", count: 20)
        XCTAssertEqual(Double(try app!.wait(for: "volume") { Double($0) == 0 }), 0)
        try app!.key("up", count: 4)
        XCTAssertEqual(Double(try app!.wait(for: "volume") { Double($0) == 20 }), 20)
    }
}

import EVPCore
import XCTest

/// The time field and the progress strip of the real app. macOS does not deliver synthetic mouse events to an app
/// from outside, so the double-click and the drag are exercised through their accessibility equivalents (focusing the
/// time field, a settable slider); the arithmetic behind the mouse handlers is unit-tested (`UnitScrubTests`).
final class E2ETimeTests: E2ETestCase {
    private func seconds(_ time: String) -> Double? {
        if case .absolute(let value)? = TimeFormat.parse(time) { return value }
        return nil
    }

    /// Starts the fixture (20 s) and pauses it so positions stand still while the test acts.
    private func startPaused() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }
        try app!.press("play-pause")
        _ = try app!.wait(for: "play-pause") { $0 == "▶" }
        usleep(400_000)
    }

    /// Gives the time field focus (the keyboard and accessibility way in) and waits until it is ready for typing.
    private func startEditing() throws {
        try app!.focus("time")
        _ = try app!.wait(for: "time", attribute: "AXHelp") { $0 == "editing" }
    }

    private func editTime(typing text: String, then finish: String = "return") throws {
        try startEditing()
        try app!.type(text)
        try app!.key(finish)
    }

    func testDoubleClickSelectsTheTimeAndATypedTimeSeeks() throws {
        try startPaused()
        try editTime(typing: "0:07")
        XCTAssertEqual(try app!.wait(for: "time") { $0 == "0:07" }, "0:07")
        XCTAssertEqual(try app!.read("play-pause"), "▶", "seeking from the field must leave the video paused")
        XCTAssertEqual(try app!.read("feedback"), "Go to 0:07")
    }

    func testARelativeTimeMovesFromWhereItIs() throws {
        try startPaused()
        try editTime(typing: "0:08")
        _ = try app!.wait(for: "time") { $0 == "0:08" }
        try editTime(typing: "+5")
        XCTAssertEqual(try app!.wait(for: "time") { $0 == "0:13" }, "0:13")
        try editTime(typing: "-3")
        XCTAssertEqual(try app!.wait(for: "time") { $0 == "0:10" }, "0:10")
    }

    func testABadTimeIsDroppedAndTheKeysWorkAgain() throws {
        try startPaused()
        try editTime(typing: "0:05")
        _ = try app!.wait(for: "time") { $0 == "0:05" }
        try editTime(typing: "zzz")
        XCTAssertEqual(try app!.read("time"), "0:05", "a bad time must not move the video or stay in the field")
        // Editing is over: the keymap has the keys back, so the right arrow seeks instead of moving a text cursor.
        try app!.key("right")
        XCTAssertEqual(try app!.wait(for: "time") { $0 == "0:10" }, "0:10")
    }

    func testEscapeCancelsAndMovingFocusAwayCancels() throws {
        try startPaused()
        let before = try app!.read("time")
        let moved = TimeFormat.format(try XCTUnwrap(seconds(before)) + 5)
        try editTime(typing: "0:15", then: "escape")
        XCTAssertEqual(try app!.read("time"), before, "escape must not seek")
        try app!.key("right")
        XCTAssertEqual(try app!.wait(for: "time") { $0 == moved }, moved, "keys must go to the keymap after escape")

        try startEditing()
        try app!.type("0:15")
        try app!.focus("play-pause")  // focus moving elsewhere ends the edit without seeking
        usleep(500_000)
        XCTAssertEqual(try app!.read("time"), moved, "moving focus away must not seek")
        try app!.key("left")
        XCTAssertEqual(try app!.wait(for: "time") { $0 == before }, before, "keys must go to the keymap after the edit ended")
    }

    func testSettingTheStripSeeksWithoutChangingPlayState() throws {
        try startPaused()
        try app!.setValue("scrub", to: 0.5)
        _ = try app!.wait(for: "time") { abs((self.seconds($0) ?? 0) - 10) <= 1 }
        try app!.setValue("scrub", to: 0.9)
        _ = try app!.wait(for: "time") { abs((self.seconds($0) ?? 0) - 18) <= 1 }
        XCTAssertEqual(try app!.read("play-pause"), "▶", "scrubbing must leave the video paused")
        // The strip reports how far the video has played.
        XCTAssertEqual(Double(try app!.read("scrub")) ?? 0, 0.9, accuracy: 0.06)
    }
}

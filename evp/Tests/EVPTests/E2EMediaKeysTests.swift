import XCTest

/// F8 and F9 through the system, coupled and decoupled. Opt-in (`EVP_E2E_MEDIA=1`): the keys go to the whole system,
/// so with a music app playing they would reach it.
final class E2EMediaKeysTests: E2ETestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EVP_E2E_MEDIA"] == "1", "set EVP_E2E_MEDIA=1 with no music app open")
        try super.setUpWithError()
    }

    func testCoupledKeysDriveThePlayingWindowAndDecoupledKeysLeaveItAlone() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { !$0.isEmpty }
        _ = try app!.wait(for: "play-pause") { $0 == "⏸" }
        try app!.media(17)
        XCTAssertEqual(try app!.wait(for: "feedback") { $0 == "+10s" }, "+10s", "F9 seeks forward by the long step")
        try app!.media(16)
        XCTAssertEqual(try app!.wait(for: "play-pause") { $0 == "▶" }, "▶", "F8 pauses")

        try app!.key("cmd+,")
        try app!.press("setting-decouple")
        try app!.key("cmd+w")
        try app!.press("play-pause")
        _ = try app!.wait(for: "play-pause") { $0 == "⏸" }
        try app!.key("m")
        _ = try app!.wait(for: "feedback") { $0 == "Muted" }
        try app!.media(17, 16)
        XCTAssertEqual(try app!.read("feedback"), "Muted", "decoupled: F9 did nothing")
        XCTAssertEqual(try app!.read("play-pause"), "⏸", "decoupled: F8 did nothing")
    }
}

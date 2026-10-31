import XCTest

/// The Audio and Subtitles menus of the real app, driven through the menu bar's accessibility tree.
final class E2ETracksTests: E2ETestCase {
    func testChoosingAnAudioTrackMovesTheCheckMark() throws {
        app = try RunningApp.launch([try Fixtures.url("t2.mkv").path])
        _ = try app!.wait(for: "time") { !$0.isEmpty }
        XCTAssertEqual(try app!.wait(for: "menu-audio-1", attribute: "AXMenuItemMarkChar") { $0 == "✓" }, "✓")
        try app!.press("menu-audio-2")
        XCTAssertEqual(try app!.wait(for: "menu-audio-2", attribute: "AXMenuItemMarkChar") { $0 == "✓" }, "✓")
    }

    func testTheSubtitleSidecarIsListedAndCanBeTurnedOff() throws {
        app = try RunningApp.launch([try Fixtures.url("sub.mkv").path])
        _ = try app!.wait(for: "time") { !$0.isEmpty }
        let line = try app!.wait(for: "menu-sub-1") { !$0.isEmpty }
        XCTAssertEqual(line, "English")
        try app!.press("menu-sub-1")
        XCTAssertEqual(try app!.wait(for: "menu-sub-1", attribute: "AXMenuItemMarkChar") { $0 == "✓" }, "✓")
        try app!.press("menu-sub-off")
        XCTAssertEqual(try app!.wait(for: "menu-sub-off", attribute: "AXMenuItemMarkChar") { $0 == "✓" }, "✓")
    }
}

import EVPCore
import XCTest

/// The Settings window of the real app: a key rebound there works at once, a conflict is refused, a new seek step is
/// used by the next key press, and the changes survive a relaunch.
final class E2ESettingsTests: E2ETestCase {
    private func key(_ chord: String, expectFeedback feedback: String) throws {
        try app!.key(chord)
        XCTAssertEqual(try app!.wait(for: "feedback") { $0 == feedback }, feedback, "after \(chord)")
    }

    /// The on-screen width of an element, from its accessibility size (`{value = w:80.000000 h:24.000000 ...}`).
    private func width(of id: String) throws -> Double {
        let size = try app!.read(id, attribute: "AXSize")
        guard let range = size.range(of: #"w:[0-9.]+"#, options: .regularExpression), let width = Double(size[range].dropFirst(2)) else {
            throw Failure(description: "no width in \(size)")
        }
        return width
    }

    func testRebindingSeekStepsAndPersistence() throws {
        let home = stateFolder()
        let video = try Fixtures.url("tv.mp4").path
        app = try RunningApp.launch([video], home: home)
        _ = try app!.wait(for: "time") { !$0.isEmpty }

        try app!.key("cmd+,")
        try app!.press("title:Keybinds")
        XCTAssertGreaterThan(try width(of: "bind-speedUp"), 20, "the Keybinds list is laid out, not collapsed to nothing")
        XCTAssertGreaterThan(try width(of: "bind-frameForward"), 20, "rows far down the list are laid out too")
        try app!.press("bind-speedUp")
        try app!.key("e")
        XCTAssertEqual(try app!.wait(for: "bind-speedUp") { $0 == "e" }, "e")
        try app!.press("bind-speedDown")
        try app!.key("e")
        _ = try app!.wait(for: "settings-message") { $0.contains("Speed up") }
        XCTAssertEqual(try app!.read("bind-speedDown"), "s", "a refused chord leaves the old one")

        try app!.press("title:General")
        try app!.focus("setting-seekShort")
        try app!.key("cmd+a")
        try app!.type("7")
        try app!.key("return")
        XCTAssertEqual(try app!.wait(for: "setting-seekShort") { $0 == "7" }, "7")
        try app!.press("close:Settings")  // and the keyboard goes back to the video

        try key("e", expectFeedback: "Speed 1.1x")
        try app!.key("d")
        try key("m", expectFeedback: "Muted")  // keys arrive in order, so d has been handled by now
        XCTAssertEqual(try app!.read("speed"), "1.1x", "d no longer speeds up")
        try key("right", expectFeedback: "+7s")

        try app!.terminate()
        app = try RunningApp.launch([video], home: home)
        _ = try app!.wait(for: "time") { !$0.isEmpty }
        try key("right", expectFeedback: "+7s")
        try key("e", expectFeedback: "Speed 1.2x")  // per-file speed came back as 1.1x, and e still speeds up
    }
}

import XCTest

/// The real EVP.app, started by the real `evp` command and observed from outside through screenshots.
final class E2ELaunchTests: E2ETestCase {
    /// A new window is 960x540 of content (PlayerWindowController); the frame adds the title bar.
    private let defaultContent = (width: 960.0, height: 540.0)

    func testEvpOpensAWindowThatPlaysTheVideo() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        let (window, pixels) = try app!.waitForSnapshot("colourful video in the window") { window, pixels in
            let titleBar = Int((window.height - defaultContent.height) * Double(pixels.width) / window.width)
            return pixels.colourfulShare(belowRow: titleBar) > 0.5
        }
        XCTAssertEqual(window.width, defaultContent.width)
        XCTAssertEqual(try app!.windowCount() > 0, true)
    }

    /// Closing a window that is not a video (Settings here, the Open panel in use) must not quit an app with no video.
    func testClosingAWindowThatIsNotAVideoKeepsTheAppRunning() throws {
        app = try RunningApp.launch([])
        sleep(1)
        try app!.key("cmd+,")
        try app!.press("close:Settings")
        sleep(2)  // a quit follows a window's close at once
        XCTAssertFalse(app!.application.isTerminated, "the app quit when Settings closed")
    }

    func testClosingTheLastVideoQuitsTheApp() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { !$0.isEmpty }
        // The press can report an error: its window is gone by the time the action returns. The quit below is the check.
        try? app!.press("close:tv.mp4")
        let deadline = Date().addingTimeInterval(5)
        while !app!.application.isTerminated, Date() < deadline { RunningApp.spin() }
        XCTAssertTrue(app!.application.isTerminated, "the app kept running with no video")
    }
}

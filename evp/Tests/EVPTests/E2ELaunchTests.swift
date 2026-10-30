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
}

import XCTest

/// The real EVP.app, started by the real `evp` command and observed from outside through screenshots.
final class E2ELaunchTests: XCTestCase {
    /// A new window is 960x540 of content (PlayerWindowController); the frame adds the title bar.
    private let defaultContent = (width: 960.0, height: 540.0)
    private var app: RunningApp?

    override func setUpWithError() throws {
        // A leftover instance from an aborted run would answer for the new launch.
        try RunningApp.stopLeftovers(of: Paths.app)
    }

    override func tearDownWithError() throws { try app?.terminate() }

    func testEvpOpensAWindowThatPlaysTheVideo() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        let (window, pixels) = try app!.waitForSnapshot("colourful video in the window") { window, pixels in
            let titleBar = Int((window.height - defaultContent.height) * Double(pixels.width) / window.width)
            return pixels.colourfulShare(belowRow: titleBar) > 0.5
        }
        XCTAssertEqual(window.width, defaultContent.width)
        XCTAssertEqual(try app!.windowCount() > 0, true)
    }

    func testVideoFitsAnyWindowSizeWithBlackBars() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        let initial = try app!.waitForSnapshot("first frame") { _, pixels in pixels.colourfulShare(belowRow: 0) > 0.2 }.0
        let titleBar = initial.height - defaultContent.height
        // Content sizes: a letterboxed small window, a very wide one, a tall narrow one (16:9 video throughout).
        for content in [(400.0, 300.0), (1600.0, 400.0), (300.0, 900.0)] {
            try app!.resize(width: Int(content.0), height: Int(content.1 + titleBar))
            let fit = min(content.0 / 16, content.1 / 9)
            let expected = (width: 16 * fit, height: 9 * fit)
            let (window, pixels) = try app!.waitForSnapshot("video fitted into \(content)") { window, pixels in
                let scale = Double(pixels.width) / window.width
                guard window.width == content.0, let bounds = pixels.nonBlackBounds(belowRow: Int(titleBar * scale)) else { return false }
                return abs(Double(bounds.width) / scale - expected.width) <= expected.width * 0.01
                    && abs(Double(bounds.height) / scale - expected.height) <= expected.height * 0.01
            }
            XCTAssertEqual(window.height, content.1 + titleBar, "window \(content)")
            _ = pixels
        }
    }
}

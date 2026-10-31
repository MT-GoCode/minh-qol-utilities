import AppKit
import EVPCore
import XCTest

/// The control bar of the real app: where it sits, what its buttons do, full screen.
final class E2EBarTests: E2ETestCase {
    /// Content size of a new window; the frame adds the title bar.
    private let defaultContent = (width: 960.0, height: 540.0)
    private let barHeight = Double(PlayerLayout.barHeight)

    private func seconds(_ timeLabel: String) -> Double? {
        guard let shown = timeLabel.split(separator: "/").first, case .absolute(let value)? = TimeFormat.parse(String(shown)) else { return nil }
        return value
    }

    func testTheBarSitsBelowTheVideoAtEverySize() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        let titleBar = try app!.waitForSnapshot("first frame") { _, pixels in pixels.colourfulShare(belowRow: 0) > 0.2 }.0.height - defaultContent.height
        for content in [(960.0, 540.0), (400.0, 300.0), (1600.0, 400.0), (300.0, 900.0), (640.0, 140.0)] {
            try app!.resize(width: Int(content.0), height: Int(content.1 + titleBar))
            // The picture fits the area above the bar.
            let area = (width: content.0, height: content.1 - barHeight)
            let fit = min(area.width / 16, area.height / 9)
            let (window, pixels) = try app!.waitForSnapshot("video fitted above the bar at \(content)") { window, pixels in
                let scale = Double(pixels.width) / window.width
                let videoRows = Int(titleBar * scale)..<(pixels.height - Int(barHeight * scale))
                guard window.width == content.0, let bounds = pixels.nonBlackBounds(rows: videoRows) else { return false }
                return abs(Double(bounds.width) / scale - 16 * fit) <= 16 * fit * 0.015 + 1
                    && abs(Double(bounds.height) / scale - 9 * fit) <= 9 * fit * 0.015 + 1
            }
            // None of the picture is in the bar's rows.
            let scale = Double(pixels.width) / window.width
            let barRows = (pixels.height - Int(barHeight * scale))..<pixels.height
            XCTAssertLessThan(pixels.colourfulShare(rows: barRows), 0.1, "video colours inside the bar at \(content)")
            try saveToResults("bar-\(Int(content.0))x\(Int(content.1)).png", pixels)
        }
    }

    func testButtonsDriveThePlayerAndTheBarShowsTheResult() throws {
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 1 }  // playing
        try app!.press("play-pause")
        XCTAssertEqual(try app!.wait(for: "play-pause") { $0 == "▶" }, "▶", "the button now offers play")
        let paused = try app!.read("time")
        usleep(1_200_000)
        XCTAssertEqual(try app!.read("time"), paused, "paused video kept moving")

        try app!.press("forward-long")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 0) >= 10 }
        XCTAssertEqual(try app!.read("feedback"), "+10s")
        try app!.press("back-short")
        _ = try app!.wait(for: "time") { (self.seconds($0) ?? 99) < 8 }
        XCTAssertEqual(try app!.read("feedback"), "-5s")
        try app!.press("speed")
        XCTAssertEqual(try app!.read("feedback"), "Speed 1x")
        XCTAssertEqual(try app!.read("speed"), "1.0x")
    }

    /// Full screen takes over the whole display for several seconds, so it runs only when asked: EVP_E2E_FULLSCREEN=1 ./test.
    func testFullScreenKeepsTheBarBelowTheVideo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EVP_E2E_FULLSCREEN"] == "1", "full screen takes over the display: set EVP_E2E_FULLSCREEN=1")
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.waitForSnapshot("first frame") { _, pixels in pixels.colourfulShare(belowRow: 0) > 0.2 }
        let screenWidth = Double(NSScreen.main!.frame.width)
        try app!.press("fullscreen")
        let (window, pixels) = try app!.waitForSnapshot(timeout: 15, "full screen with the bar below the video") { window, pixels in
            guard window.width == screenWidth else { return false }
            let scale = Double(pixels.width) / window.width
            return pixels.colourfulShare(rows: 0..<(pixels.height - Int(barHeight * scale))) > 0.2
        }
        let scale = Double(pixels.width) / window.width
        XCTAssertLessThan(pixels.colourfulShare(rows: (pixels.height - Int(barHeight * scale))..<pixels.height), 0.1)
        try saveToResults("bar-fullscreen.png", pixels)
        try app!.press("fullscreen")
        _ = try app!.waitForSnapshot(timeout: 15, "back to a window") { window, _ in window.width < screenWidth }
    }
}

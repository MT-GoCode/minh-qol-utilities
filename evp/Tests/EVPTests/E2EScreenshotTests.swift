import AppKit
import XCTest

/// The screenshot button of the real app. It writes to the clipboard of whoever uses this Mac, so the test puts the
/// clipboard back as it found it.
final class E2EScreenshotTests: E2ETestCase {
    func testTheScreenshotButtonPutsTheShownFrameOnTheClipboardAtFullSize() throws {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        addTeardownBlock {
            board.clearContents()
            board.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        }
        app = try RunningApp.launch([try Fixtures.url("tv.mp4").path])
        _ = try app!.wait(for: "time") { !$0.isEmpty }
        let before = board.changeCount
        try app!.press("screenshot")
        XCTAssertEqual(try app!.wait(for: "feedback") { $0.hasPrefix("Screenshot") || $0.hasPrefix("Error") }, "Screenshot copied")
        XCTAssertGreaterThan(board.changeCount, before)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(board.data(forType: .png))))
        XCTAssertEqual([image.pixelsWide, image.pixelsHigh], [1280, 720], "the frame at the video's own size")
    }
}

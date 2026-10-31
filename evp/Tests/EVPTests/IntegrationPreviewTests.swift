import AppKit
import EVPCore
import XCTest

/// Strip thumbnails from a second player of the same real file.
final class IntegrationPreviewTests: XCTestCase {
    private func frames(of name: String, asking times: [Double], count: Int) throws -> [(Double, Data)] {
        let preview = try FramePreview(file: try Fixtures.url(name))
        var got: [(Double, Data)] = []
        preview.onFrame = { got.append(($0, $1)) }
        preview.onError = { XCTFail("preview failed: \($0)") }
        times.forEach(preview.show)  // all before the file has loaded: only the last one may be decoded
        let deadline = Date().addingTimeInterval(Session.timeout)
        while got.count < count, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))  // room for a frame that should not come
        return got
    }

    func testAThumbnailIsASmallJpegOfTheVideo() throws {
        let got = try frames(of: "t.mp4", asking: [10], count: 1)
        XCTAssertEqual(got.map(\.0), [10])
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(got.first?.1)))
        XCTAssertEqual([image.pixelsWide, image.pixelsHigh], [320, 180], "scaled from 1280x720")
        XCTAssertEqual(Array(got[0].1.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
    }

    func testOnlyTheLatestRequestIsDecoded() throws {
        let got = try frames(of: "t.mp4", asking: [2, 5, 15], count: 1)
        XCTAssertEqual(got.map(\.0), [15], "requests superseded before decoding are dropped")
    }

    func testDifferentTimesGiveDifferentPictures() throws {
        let preview = try FramePreview(file: try Fixtures.url("t.mp4"))
        var got: [Data] = []
        preview.onFrame = { got.append($1) }
        preview.show(1)
        var deadline = Date().addingTimeInterval(Session.timeout)
        while got.count < 1, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        preview.show(15)
        deadline = Date().addingTimeInterval(Session.timeout)
        while got.count < 2, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(got.count, 2)
        XCTAssertNotEqual(got.first, got.last, "a thumbnail of 0:01 and of 0:15 must differ")
    }
}

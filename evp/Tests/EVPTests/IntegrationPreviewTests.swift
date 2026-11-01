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
        times.forEach(preview.show)  // all before the first frame: only the last one may be decoded
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
        XCTAssertEqual(try frames(of: "t.mp4", asking: [2, 5, 15], count: 1).map(\.0), [15], "requests superseded before the file loads are dropped")
    }

    func testARequestDuringADecodeReplacesTheWaitingOne() throws {
        let preview = try FramePreview(file: try Fixtures.url("t.mp4"))
        var got: [Double] = []
        preview.onFrame = { seconds, _ in got.append(seconds) }
        preview.show(1)
        let loaded = Date().addingTimeInterval(Session.timeout)
        while got.isEmpty, Date() < loaded { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        got = []
        // Ready: 2 starts decoding at once, 5 waits and is replaced by 15 before 2 finishes.
        [2, 5, 15].forEach(preview.show)
        let deadline = Date().addingTimeInterval(Session.timeout)
        while got.count < 2, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))
        XCTAssertEqual(got, [2, 15])
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

    /// 20 s is the fixture's length. A seek that produced no answer would leave every later hover waiting for ever.
    func testTheVeryEndAndARepeatedTimeStillAnswer() throws {
        let preview = try FramePreview(file: try Fixtures.url("t.mp4"))
        var got: [(Double, Data)] = []
        preview.onFrame = { got.append(($0, $1)) }
        preview.onError = { XCTFail("preview failed: \($0)") }
        for (index, seconds) in [20.0, 20, 5, 5, 0].enumerated() {
            preview.show(seconds)
            let deadline = Date().addingTimeInterval(Session.timeout)
            while got.count <= index, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        XCTAssertEqual(got.map(\.0), [20, 20, 5, 5, 0])
        XCTAssertNotEqual(got[0].1, got[2].1, "the end and 0:05 must differ: the player still seeks after reaching the end")
    }

    func testAFileThatCannotLoadReportsAnError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("evp-not-a-video-\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let preview = try FramePreview(file: file)
        var errors: [Error] = []
        preview.onError = { errors.append($0) }
        preview.onFrame = { _, _ in XCTFail("a frame from a file that is not a video") }
        let deadline = Date().addingTimeInterval(Session.timeout)
        while errors.isEmpty, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(errors.count, 1)
    }
}

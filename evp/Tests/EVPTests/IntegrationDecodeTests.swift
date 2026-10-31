import EVPCore
import XCTest

/// Real libmpv, real media: every stream of every format must decode with the expected codec and advance.
final class IntegrationDecodeTests: XCTestCase {
    /// The fixtures are generated at exactly 20 s (Tools/make-fixtures).
    private let fixtureDuration = 20.0

    private struct Fixture {
        let name: String
        let videoFormat: String?
        let audioCodec: String
    }

    /// Plays headless until position passes 1 s.
    private func play(_ name: String) throws -> Session {
        let session = try Session(loading: name)
        try session.until("position past 1 s in \(name)") { ((try? session.position()) ?? 0) > 1 }
        return session
    }

    private func assertDecodes(_ fixture: Fixture) throws {
        let session = try play(fixture.name)
        let player = session.player
        XCTAssertEqual(try XCTUnwrap(Double(try player.property("duration") ?? "")), fixtureDuration, accuracy: 0.1, fixture.name)
        XCTAssertEqual(try player.property("video-format"), fixture.videoFormat, "\(fixture.name) video codec")
        XCTAssertEqual(try player.property("audio-codec-name"), fixture.audioCodec, "\(fixture.name) audio codec")
        if fixture.videoFormat != nil {
            let frames = Int(try player.property("estimated-frame-number") ?? "") ?? 0
            XCTAssertGreaterThan(frames, 0, "\(fixture.name) decoded no video frames")
        }
        XCTAssertFalse(session.events.contains { if case .loadFailed = $0 { return true } else { return false } }, "\(fixture.name) reported a load failure")
    }

    func testMp4() throws { try assertDecodes(Fixture(name: "t.mp4", videoFormat: "h264", audioCodec: "aac")) }
    func testMkv() throws { try assertDecodes(Fixture(name: "t.mkv", videoFormat: "h264", audioCodec: "aac")) }
    func testMov() throws { try assertDecodes(Fixture(name: "t.mov", videoFormat: "h264", audioCodec: "aac")) }
    func testWebm() throws { try assertDecodes(Fixture(name: "t.webm", videoFormat: "vp9", audioCodec: "opus")) }
    func testMp3() throws { try assertDecodes(Fixture(name: "t.mp3", videoFormat: nil, audioCodec: "mp3")) }

    /// Headless has no GPU surface to share, so mpv picks the copy-back VideoToolbox variant.
    func testH264UsesHardwareDecode() throws {
        XCTAssertEqual(try play("t.mp4").player.property("hwdec-current"), "videotoolbox-copy")
    }

    func testMisspelledPropertyThrows() throws {
        XCTAssertThrowsError(try MpvPlayer().property("no-such-property"))
    }

    func testUnrecognisedFileReportsLoadFailure() throws {
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).mp4")
        try Data(repeating: 0xA5, count: 1024).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let session = try Session()
        try session.player.load(corrupt)
        try session.waitFor(.loadFailed(.unknownFormat))
    }
}

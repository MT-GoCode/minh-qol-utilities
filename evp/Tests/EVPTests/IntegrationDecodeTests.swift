import EVPCore
import XCTest

/// Real libmpv, real media: every stream of every format must decode with the expected codec and advance.
final class IntegrationDecodeTests: XCTestCase {
    /// Measured: about 2 s from `loadfile` to 1 s of playback on this machine (see results/*/xunit.xml).
    private let startupTimeout = 5.0
    /// The fixtures are generated at exactly 20 s (Tools/make-fixtures).
    private let fixtureDuration = 20.0

    private struct Fixture {
        let name: String
        let videoFormat: String?
        let audioCodec: String
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private func fixtureURL(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".fixtures/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(description: "\(name) missing: run ./test, which generates fixtures") }
        return url
    }

    private func wait(for expectation: XCTestExpectation) throws {
        guard XCTWaiter().wait(for: [expectation], timeout: startupTimeout) == .completed else {
            throw Failure(description: "timed out after \(startupTimeout) s: \(expectation.expectationDescription)")
        }
    }

    /// Plays headless until position passes 1 s; returns the player, the reported duration and every event seen.
    private func playUntilAdvancing(_ name: String) throws -> (MpvPlayer, Double, [MpvPlayer.Event]) {
        let player = try MpvPlayer()
        let advanced = expectation(description: "position passed 1 s in \(name)")
        var duration = 0.0
        var events: [MpvPlayer.Event] = []
        var done = false
        player.onEvent = { event in
            events.append(event)
            switch event {
            case .duration(let d): duration = d
            case .time(let t) where t > 1 && !done: done = true; advanced.fulfill()
            default: break
            }
        }
        try player.load(try fixtureURL(name))
        try wait(for: advanced)
        return (player, duration, events)
    }

    private func assertDecodes(_ fixture: Fixture) throws {
        let (player, duration, events) = try playUntilAdvancing(fixture.name)
        XCTAssertEqual(duration, fixtureDuration, accuracy: 0.1, fixture.name)
        XCTAssertEqual(try player.property("video-format"), fixture.videoFormat, "\(fixture.name) video codec")
        XCTAssertEqual(try player.property("audio-codec-name"), fixture.audioCodec, "\(fixture.name) audio codec")
        if fixture.videoFormat != nil {
            let frames = Int(try player.property("estimated-frame-number") ?? "") ?? 0
            XCTAssertGreaterThan(frames, 0, "\(fixture.name) decoded no video frames")
        }
        XCTAssertTrue(events.contains(.fileLoaded), "\(fixture.name) never reported fileLoaded")
        XCTAssertTrue(events.contains(.paused(false)), "\(fixture.name) never reported its pause state")
        XCTAssertFalse(events.contains { if case .loadFailed = $0 { return true } else { return false } }, "\(fixture.name) reported a load failure")
    }

    func testMp4() throws { try assertDecodes(Fixture(name: "t.mp4", videoFormat: "h264", audioCodec: "aac")) }
    func testMkv() throws { try assertDecodes(Fixture(name: "t.mkv", videoFormat: "h264", audioCodec: "aac")) }
    func testMov() throws { try assertDecodes(Fixture(name: "t.mov", videoFormat: "h264", audioCodec: "aac")) }
    func testWebm() throws { try assertDecodes(Fixture(name: "t.webm", videoFormat: "vp9", audioCodec: "opus")) }
    func testMp3() throws { try assertDecodes(Fixture(name: "t.mp3", videoFormat: nil, audioCodec: "mp3")) }

    /// Headless has no GPU surface to share, so mpv picks the copy-back VideoToolbox variant.
    func testH264UsesHardwareDecode() throws {
        let (player, _, _) = try playUntilAdvancing("t.mp4")
        XCTAssertEqual(try player.property("hwdec-current"), "videotoolbox-copy")
    }

    func testMisspelledPropertyThrows() throws {
        let player = try MpvPlayer()
        XCTAssertThrowsError(try player.property("no-such-property"))
    }

    func testUnrecognisedFileReportsLoadFailure() throws {
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).mp4")
        try Data(repeating: 0xA5, count: 1024).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let player = try MpvPlayer()
        let failed = expectation(description: "load failure reported")
        var reason = ""
        player.onEvent = { event in
            if case .loadFailed(let error) = event { reason = error.description; failed.fulfill() }
        }
        try player.load(corrupt)
        try wait(for: failed)
        XCTAssertEqual(reason, "unrecognized file format")
    }
}

import EVPCore
import XCTest

/// Real libmpv, real media: each format must reach a decoded, advancing position.
final class IntegrationDecodeTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".fixtures/\(name)")
    }

    /// Plays `url` headless until position passes 1 s; returns the player and the duration it reported.
    private func playUntilAdvancing(_ url: URL) throws -> (MpvPlayer, Double) {
        let player = try MpvPlayer()
        let advanced = expectation(description: "position passed 1 s in \(url.lastPathComponent)")
        var duration = 0.0
        var done = false
        player.onEvent = { event in
            switch event {
            case .duration(let d): duration = d
            case .time(let t) where t > 1 && !done: done = true; advanced.fulfill()
            default: break
            }
        }
        try player.load(url)
        wait(for: [advanced], timeout: 5)
        return (player, duration)
    }

    private func assertDecodes(_ name: String) throws {
        let (_, duration) = try playUntilAdvancing(fixture(name))
        XCTAssertEqual(duration, 20, accuracy: 0.1, name)
    }

    func testMp4() throws { try assertDecodes("t.mp4") }
    func testMkv() throws { try assertDecodes("t.mkv") }
    func testMov() throws { try assertDecodes("t.mov") }
    func testWebm() throws { try assertDecodes("t.webm") }
    func testMp3() throws { try assertDecodes("t.mp3") }

    /// Headless has no GPU surface to share, so mpv picks the copy-back VideoToolbox variant.
    func testH264UsesHardwareDecode() throws {
        let (player, _) = try playUntilAdvancing(fixture("t.mp4"))
        XCTAssertEqual(player.property("hwdec-current"), "videotoolbox-copy")
    }

    func testCorruptFileReportsFailure() throws {
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).mp4")
        try Data((0..<1024).map { _ in UInt8.random(in: 0...255) }).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let player = try MpvPlayer()
        let ended = expectation(description: "load failure reported")
        player.onEvent = { if $0 == .ended(failed: true) { ended.fulfill() } }
        try player.load(corrupt)
        wait(for: [ended], timeout: 5)
    }
}

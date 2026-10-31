import EVPCore
import XCTest

/// The screenshot is the frame on screen, at the video's own size: checked against ffmpeg's own extraction of that frame.
final class IntegrationScreenshotTests: XCTestCase {
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        process.arguments = [tool] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }

    /// Peak signal-to-noise ratio of two images, from ffmpeg (higher is more alike).
    private func psnr(_ a: URL, _ b: URL) throws -> Double {
        let output = try run("ffmpeg", ["-i", a.path, "-i", b.path, "-lavfi", "psnr", "-f", "null", "-"])
        let average = try XCTUnwrap(output.components(separatedBy: "average:").last?.split(separator: " ").first.map(String.init), output)
        return average == "inf" ? .infinity : try XCTUnwrap(Double(average), output)
    }

    /// mpv and ffmpeg convert the video's colours to RGB slightly differently, so the pictures are not identical
    /// pixel for pixel; what must hold is that the screenshot is the frame at 5 s and not a neighbour.
    func testTheScreenshotIsTheFrameBeingShownAtFullSize() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        let mark = s.events.count
        try s.player.seek(to: 5)
        try s.waitFor(.playbackRestart, after: mark)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evp-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let shot = folder.appendingPathComponent("shot.png")
        try s.player.screenshot(to: shot)

        XCTAssertEqual(try run("ffprobe", ["-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", shot.path]).trimmingCharacters(in: .whitespacesAndNewlines), "1280,720")
        // References: ffmpeg's own pictures of the video a few frames before, at, and after 5 s, with the same colour matrix.
        var scores: [Double] = []
        for second in ["4.9", "5", "5.1"] {
            let reference = folder.appendingPathComponent("reference-\(second).png")
            _ = try run("ffmpeg", ["-v", "error", "-ss", second, "-i", try Fixtures.url("t.mp4").path, "-frames:v", "1",
                                    "-vf", "scale=in_color_matrix=bt709:in_range=tv:out_range=pc", reference.path])
            scores.append(try psnr(shot, reference))
        }
        XCTAssertEqual(scores.firstIndex(of: scores.max()!), 1, "the screenshot should match the frame at 5 s best: \(scores)")
        XCTAssertGreaterThan(scores[1] - max(scores[0], scores[2]), 8, "and by a wide margin over its neighbours: \(scores)")
    }

    func testDifferentMomentsGiveDifferentPictures() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evp-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var shots: [Data] = []
        for second in [3.0, 12.0] {
            let mark = s.events.count
            try s.player.seek(to: second)
            try s.waitFor(.playbackRestart, after: mark)
            let file = folder.appendingPathComponent("\(Int(second)).png")
            try s.player.screenshot(to: file)
            shots.append(try Data(contentsOf: file))
        }
        XCTAssertNotEqual(shots[0], shots[1])
    }
}

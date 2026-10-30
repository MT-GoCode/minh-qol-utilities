import EVPCore
import XCTest

final class UnitResumeTests: XCTestCase {
    func testResumeStartPosition() {
        let cases: [(saved: Double, duration: Double, expected: Double)] = [
            (292, 541, 292),   // mid-video resumes exactly
            (0, 541, 0),
            (535.9, 541, 535.9), // 5.1 s from the end still resumes
            (536, 541, 0),     // exactly 5 s from the end restarts
            (541, 541, 0),     // finished
            (600, 541, 0),     // beyond the end (stale file state)
            (-3, 541, 0),
            (3, 4, 0),         // a video shorter than the margin always restarts
        ]
        for c in cases { XCTAssertEqual(ResumePolicy.startPosition(saved: c.saved, duration: c.duration), c.expected, "\(c.saved) of \(c.duration)") }
    }
}

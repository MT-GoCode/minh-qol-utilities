import EVPCore
import XCTest

final class UnitScrubTests: XCTestCase {
    func testPointsOnTheStripMapToFractionsAndClamp() {
        XCTAssertEqual(ScrubMath.fraction(x: 0, width: 400), 0)
        XCTAssertEqual(ScrubMath.fraction(x: 200, width: 400), 0.5)
        XCTAssertEqual(ScrubMath.fraction(x: 400, width: 400), 1)
        XCTAssertEqual(ScrubMath.fraction(x: -30, width: 400), 0, "left of the strip")
        XCTAssertEqual(ScrubMath.fraction(x: 999, width: 400), 1, "right of the strip")
        XCTAssertEqual(ScrubMath.fraction(x: 10, width: 0), 0, "a collapsed strip")
    }

    func testTooltipShowsThePositionUnderThePointer() {
        XCTAssertEqual(ScrubMath.tooltip(fraction: 0.5, duration: 541), "4:30")
        XCTAssertEqual(ScrubMath.tooltip(fraction: 0, duration: 541), "0:00")
        XCTAssertEqual(ScrubMath.tooltip(fraction: 1, duration: 3892), "1:04:52")
        XCTAssertEqual(ScrubMath.tooltip(fraction: 0.5, duration: 0), "0:00", "before the duration is known")
    }

    func testTheSpeedLabelKeepsTheEnginesPrecision() {
        XCTAssertEqual([1, 1.3, 1.25, 0.05, 10.5, 100].map(PlaybackLimits.label(speed:)), ["1.0x", "1.3x", "1.25x", "0.05x", "10.5x", "100.0x"])
    }
}

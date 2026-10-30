import EVPCore
import XCTest

final class UnitLayoutTests: XCTestCase {
    func testVideoAndBarNeverOverlapAndFillTheWindow() {
        for width in stride(from: 1.0, through: 3000, by: 37) {
            for height in stride(from: 1.0, through: 1600, by: 29) {
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let (video, bar) = PlayerLayout.frames(in: bounds, barHidden: false)
                XCTAssertEqual(bar.width, width)
                XCTAssertEqual(video.width, width)
                XCTAssertEqual(bar.height, min(PlayerLayout.barHeight, height), "\(bounds)")
                XCTAssertEqual(bar.minY, 0)
                XCTAssertEqual(video.minY, bar.maxY, "the video starts where the bar ends: \(bounds)")
                XCTAssertEqual(video.maxY, height)
                XCTAssertEqual(video.height + bar.height, height)
                XCTAssertTrue(video.intersection(bar).height == 0, "overlap at \(bounds)")
            }
        }
    }

    func testHidingTheBarGivesTheVideoEverything() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 450)
        let (video, bar) = PlayerLayout.frames(in: bounds, barHidden: true)
        XCTAssertEqual(video, bounds)
        XCTAssertEqual(bar, .zero)
    }

    func testFoldingKeepsTheMostImportantItemsAndNeverOverflowsTheBar() {
        let widths: [CGFloat] = [40, 40, 40, 40, 52, 96, 32]
        let (essential, gap, overflow): (CGFloat, CGFloat, CGFloat) = (170, 6, 28)
        var previous = 0
        for available in stride(from: CGFloat(0), through: 700, by: 1) {
            let count = BarLayout.visibleCount(available: available, essentialWidth: essential, foldableWidths: widths, gap: gap, overflowWidth: overflow)
            XCTAssertGreaterThanOrEqual(count, previous, "a wider bar never shows fewer items (at \(available))")
            previous = count
            let used = essential + widths.prefix(count).reduce(0) { $0 + gap + $1 } + (count < widths.count ? gap + overflow : 0)
            if count > 0 || available >= essential { XCTAssertLessThanOrEqual(used, max(available, essential + gap + overflow), "overflow at \(available)") }
            if count < widths.count {
                let next = essential + widths.prefix(count + 1).reduce(0) { $0 + gap + $1 } + (count + 1 < widths.count ? gap + overflow : 0)
                XCTAssertGreaterThan(next, available, "item \(count + 1) would have fit at \(available)")
            }
        }
        XCTAssertEqual(previous, widths.count)
    }
}

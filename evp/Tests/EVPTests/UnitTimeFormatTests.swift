import EVPCore
import XCTest

final class UnitTimeFormatTests: XCTestCase {
    func testParsesTheNotationsOfTheTimeField() {
        let valid: [(String, TimeInput)] = [
            ("4:52", .absolute(292)), ("1:04:52", .absolute(3892)), ("292", .absolute(292)), ("0:07", .absolute(7)),
            ("90:00", .absolute(5400)), (" 4:52 ", .absolute(292)),
            ("+30", .relative(30)), ("-30", .relative(-30)), ("+1:30", .relative(90)), ("-1:00:00", .relative(-3600)),
        ]
        for (text, expected) in valid { XCTAssertEqual(TimeFormat.parse(text), expected, text) }
    }

    func testRejectsEverythingElse() {
        for text in ["4:75", "1:60:00", "1:04:75", "abc", "", " ", "4:", ":30", "1::30", "1:2:3:4", "4.5", "4:5x", "+", "-", "++5", "٣:٠٠", "99999999999999999999", "999999999999999999:05", "9223372036854775807:59:59"] {
            XCTAssertNil(TimeFormat.parse(text), text)
        }
    }

    func testFormatsLikeTheBar() {
        let cases: [(Double, String)] = [(0, "0:00"), (7, "0:07"), (292, "4:52"), (541.9, "9:01"), (3599, "59:59"), (3600, "1:00:00"), (3892, "1:04:52")]
        for (seconds, expected) in cases { XCTAssertEqual(TimeFormat.format(seconds), expected, "\(seconds)") }
        XCTAssertEqual(TimeFormat.format(-5), "0:00")
        XCTAssertEqual(TimeFormat.format(.nan), "0:00")
        XCTAssertEqual(TimeFormat.format(.infinity), "0:00")
    }

    func testFormatThenParseRoundTrips() {
        for seconds in [0.0, 59, 60, 292, 3599, 3600, 86399] {
            XCTAssertEqual(TimeFormat.parse(TimeFormat.format(seconds)), .absolute(seconds))
        }
    }
}

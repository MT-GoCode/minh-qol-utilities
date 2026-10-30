import EVPCore
import XCTest

final class UnitOpenRequestTests: XCTestCase {
    private func request(_ text: String) throws -> OpenRequest { try OpenRequest(url: XCTUnwrap(URL(string: text))) }

    func testFileURLsOpenWithoutAStartPosition() throws {
        let opened = try request("file:///Users/m/Movies/a%20b.mkv")
        XCTAssertEqual(opened.file.path, "/Users/m/Movies/a b.mkv")
        XCTAssertNil(opened.start)
    }

    func testEvpURLCarriesAnEncodedPathAndATime() throws {
        let opened = try request("evp://open?path=%2FUsers%2Fm%2FMovies%2Fa%20b%26c.mkv&time=4%3A52")
        XCTAssertEqual(opened.file.path, "/Users/m/Movies/a b&c.mkv")
        XCTAssertEqual(opened.start, 292)
        XCTAssertNil(try request("evp://open?path=%2Fa.mkv").start)
        XCTAssertEqual(try request("evp://open?path=%2Fa.mkv&time=1%3A04%3A52").start, 3892)
    }

    func testRejectsAnythingThatIsNotAWellFormedRequest() {
        let bad = [
            "https://open?path=%2Fa.mkv",       // wrong scheme
            "evp://close?path=%2Fa.mkv",        // wrong action
            "evp://open",                       // no path
            "evp://open?path=a.mkv",            // relative path
            "evp://open?path=%2Fa.mkv&time=abc",
            "evp://open?path=%2Fa.mkv&time=%2B30",  // an offset is not a position
            "evp://open?path=%2Fa.mkv&time=4%3A75",
        ]
        for text in bad { XCTAssertThrowsError(try request(text), text) }
    }
}

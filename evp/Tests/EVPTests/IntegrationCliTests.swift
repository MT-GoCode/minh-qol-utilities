import XCTest

/// The `evp` command's argument handling; opening windows is covered by the E2E tests.
final class IntegrationCliTests: XCTestCase {
    private func evp(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = Paths.cli
        process.arguments = arguments
        process.environment = ["EVP_APP": Paths.app.path, "PATH": "/usr/bin:/bin"]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testHelpSucceedsAndNoArgumentsIsAUsageError() throws {
        XCTAssertEqual(try evp(["--help"]).status, 0)
        let none = try evp([])
        XCTAssertEqual(none.status, 2)
        XCTAssertTrue(none.stderr.contains("usage: evp"))
    }

    func testRejectsMissingFilesUnknownOptionsAndTimeWithSeveralFiles() throws {
        let missing = try evp(["/no/such/file.mkv"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.stderr.contains("no such file"))
        XCTAssertEqual(try evp(["--bogus", "x"]).status, 2)
        let real = try Fixtures.url("tv.mp4").path
        let two = try evp(["--time", "0:05", real, real])
        XCTAssertEqual(two.status, 1)
        XCTAssertTrue(two.stderr.contains("--time needs exactly one file"))
    }

    func testMissingAppIsReportedNotIgnored() throws {
        let process = Process()
        process.executableURL = Paths.cli
        process.arguments = [try Fixtures.url("tv.mp4").path]
        process.environment = ["EVP_APP": "/no/such/EVP.app", "PATH": "/usr/bin:/bin"]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("not found"))
    }
}

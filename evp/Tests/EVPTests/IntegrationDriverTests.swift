import XCTest

/// The test driver is a tool the later strata depend on; `windows` is the part that runs without input injection.
final class IntegrationDriverTests: XCTestCase {
    func testWindowsOfMissingProcessFailsLoudly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let driver = Process()
        driver.executableURL = root.appendingPathComponent(".build/evpdrive")
        driver.arguments = ["windows", "999999"]
        let stderr = Pipe()
        driver.standardError = stderr
        try driver.run()
        driver.waitUntilExit()
        XCTAssertEqual(driver.terminationStatus, 2)
        XCTAssertEqual(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "no windows for pid 999999\n")
    }
}

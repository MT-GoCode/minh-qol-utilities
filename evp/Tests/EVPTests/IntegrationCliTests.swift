import EVPCore
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

    /// Runs `evp` with a stand-in `open` on the PATH that records its arguments, one per line.
    private func argumentsSentToOpen(_ arguments: [String]) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evp-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("arguments")
        let stub = folder.appendingPathComponent("open")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '\(record.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let process = Process()
        process.executableURL = Paths.cli
        process.arguments = arguments
        process.environment = ["EVP_APP": Paths.app.path, "PATH": "\(folder.path):/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testEvpHandsTheAppAnEncodedUrlThatDecodesBackToTheFileAndTime() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evp cli files \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("odd name & é #1.mkv")
        try Data().write(to: file)

        let plain = try argumentsSentToOpen([file.path])
        XCTAssertEqual(Array(plain.prefix(2)), ["-a", Paths.app.path], "no -g unless asked")
        let request = try OpenRequest(url: XCTUnwrap(URL(string: plain[2])))
        XCTAssertEqual(request.file.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        XCTAssertNil(request.start)

        let timed = try argumentsSentToOpen(["-g", "--time", "4:52", file.path])
        XCTAssertEqual(Array(timed.prefix(3)), ["-g", "-a", Paths.app.path])
        XCTAssertEqual(try OpenRequest(url: XCTUnwrap(URL(string: timed[3]))).start, 292)
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

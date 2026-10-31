import XCTest

/// install.sh and uninstall.sh into a scratch prefix, with `sudo` replaced by a stub that fails the run if called.
final class E2EInstallTests: XCTestCase {
    private func run(_ script: String, _ arguments: [String] = [], in prefix: URL, extraPath: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Paths.root.appendingPathComponent(script)
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "APP_DIR": prefix.appendingPathComponent("Applications").path,
            "BINDIR": prefix.appendingPathComponent("bin").path,
            "PATH": "\(extraPath.path):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    func testInstallWorksWithoutSudoThenTheEvpCommandPlaysAndUninstallRemovesIt() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("evp-install-\(UUID().uuidString)")
        let stubs = prefix.appendingPathComponent("stubs")
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        let sudoCalled = prefix.appendingPathComponent("sudo-called")
        let stub = stubs.appendingPathComponent("sudo")
        try "#!/bin/sh\ntouch '\(sudoCalled.path)'\nexit 99\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        // A failed assertion must not leave the scratch app registered for evp:// with LaunchServices.
        addTeardownBlock {
            _ = try? self.run("uninstall.sh", in: prefix, extraPath: stubs)
            try? FileManager.default.removeItem(at: prefix)
        }

        // --prebuilt: ./test has just built the app, and a second `swift build` inside `swift test` would wait on its lock forever.
        let installed = try run("install.sh", ["--prebuilt"], in: prefix, extraPath: stubs)
        XCTAssertEqual(installed.status, 0, installed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sudoCalled.path), "install.sh called sudo")
        let app = prefix.appendingPathComponent("Applications/EVP.app")
        let command = prefix.appendingPathComponent("bin/evp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/EVP").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command.path))

        let running = try RunningApp.launch([try Fixtures.url("tv.mp4").path], appURL: app, cli: command)
        defer { try? running.terminate() }
        _ = try running.waitForSnapshot("the installed copy to play") { window, pixels in pixels.colourfulShare(belowRow: Int(0.1 * Double(pixels.height))) > 0.5 }

        let again = try run("install.sh", ["--prebuilt"], in: prefix, extraPath: stubs)  // idempotent: a second run succeeds in place
        XCTAssertEqual(again.status, 0, again.output)
        try running.terminate()
        let removed = try run("uninstall.sh", in: prefix, extraPath: stubs)
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.path))
    }

    func testPreflightNamesEveryMissingRequirementAndInstallsNothing() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("evp-preflight-\(UUID().uuidString)")
        let emptyPath = prefix.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        // The only tools install.sh needs before its preflight; swift, python3, brew and pkg-config stay absent.
        for tool in ["id", "dirname"] {
            try FileManager.default.createSymbolicLink(at: emptyPath.appendingPathComponent(tool), withDestinationURL: URL(fileURLWithPath: "/usr/bin/\(tool)"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: prefix) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Paths.root.appendingPathComponent("install.sh").path]
        process.environment = ["HOME": NSHomeDirectory(), "APP_DIR": prefix.appendingPathComponent("Applications").path,
                               "BINDIR": prefix.appendingPathComponent("bin").path, "PATH": emptyPath.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1, text)
        for fix in ["xcode-select --install", "brew install pkgconf", "brew install mpv", "https://brew.sh"] {
            XCTAssertTrue(text.contains(fix), "missing fix line \(fix) in:\n\(text)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("Applications").path), "preflight installed something")
    }
}

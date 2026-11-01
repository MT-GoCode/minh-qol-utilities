import CryptoKit
import Foundation
import XCTest

enum HarnessError: Error { case buildFailed(Int32, log: String), stale(String), app(String), noReport }

enum AppHarness {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let app = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/TranscribeEverything.app")
    static let staged = repo.appending(path: ".build-app/TranscribeEverything.app")
    static func executable(_ bundle: URL) -> URL { bundle.appending(path: "Contents/MacOS/TranscribeEverything") }

    /// Once per test process: build, sign, install, and prove the installed binary is the one just built.
    static let ready = Result<Void, Error> {
        let log = resultsDir().appending(path: "build.log")
        let r = try sh("/bin/bash", [repo.appending(path: "build.sh").path], log: log)
        guard r.status == 0 else { throw HarnessError.buildFailed(r.status, log: log.path) }
        try assertSameBinary(executable(staged), executable(app))
    }

    static func assertSameBinary(_ fresh: URL, _ installed: URL) throws {
        if SHA256.hash(data: try Data(contentsOf: fresh)) != SHA256.hash(data: try Data(contentsOf: installed)) { throw HarnessError.stale(installed.path) }
    }

    /// Launches the installed app on a scenario through LaunchServices, which makes it the permission holder, and returns the report.
    static func run(root: URL, steps: [[String: Any]]) throws -> [String: Any] {
        try ready.get()
        let dir = FileManager.default.temporaryDirectory.appending(path: "te-verify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scenario = dir.appending(path: "scenario.json"), report = dir.appending(path: "scenario.report.json")
        try JSONSerialization.data(withJSONObject: ["root": root.path, "steps": steps]).write(to: scenario)
        let out = resultsDir()
        _ = try sh("/usr/bin/open", ["-W", "-n", "--stdout", out.appending(path: "app.stdout").path, "--stderr", out.appending(path: "app.stderr").path, app.path, "--args", "verify", scenario.path])
        guard let data = try? Data(contentsOf: report) else { throw HarnessError.noReport }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let e = json["error"] as? String { throw HarnessError.app(e) }
        return json
    }

    /// Runs a tool to completion. `log` receives stdout and stderr; otherwise they are returned in `out`.
    @discardableResult
    static func sh(_ exe: String, _ args: [String], env: [String: String] = [:], log: URL? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let h = try FileHandle(forWritingTo: log)
            p.standardOutput = h
            p.standardError = h
            try p.run()
            p.waitUntilExit()
            return (p.terminationStatus, "")
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // before waiting, or a full pipe hangs
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

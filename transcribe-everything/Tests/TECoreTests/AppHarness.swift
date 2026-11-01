import CoreGraphics
import CryptoKit
import Foundation
import XCTest
import os

enum HarnessError: Error { case buildFailed(Int32, log: String), stale(String), app(String), noReport, neverReady }

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

    static var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true }

    /// Once per test process: SCK lists no display while the display sleeps. The assertion ends with this process.
    static let displayAwake = Result<Void, Error> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-d", "-w", "\(getpid())"]
        try p.run()
        Thread.sleep(forTimeInterval: 2)  // the 2 s the probe waited after waking before SCK listed the display
    }

    /// Mutes system output for `body` and restores the previous mute state, not "unmuted".
    static func muted<T>(_ body: () async throws -> T) async throws -> T {
        FileHandle.standardError.write(Data("AppHarness: muting system output until this test ends; a call in progress goes silent\n".utf8))
        let before = try isMuted()
        try setMuted(true)
        defer { try? setMuted(before) }
        return try await body()
    }
    static func isMuted() throws -> Bool { try sh("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
    static func setMuted(_ m: Bool) throws { try sh("/usr/bin/osascript", ["-e", "set volume output muted \(m)"]) }

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

/// One running launch of the app.
final class Launch {
    let report: Task<[String: Any], Error>
    private let done: OSAllocatedUnfairLock<Bool>
    init(root: URL, steps: [[String: Any]]) {
        let done = OSAllocatedUnfairLock(initialState: false)
        self.done = done
        report = Task.detached {
            defer { done.withLock { $0 = true } }
            return try AppHarness.run(root: root, steps: steps)
        }
    }
    /// Returns when the app wrote `ready`; throws the app's own error if it exits first. A capture that never delivers throws at the deadline, 2 minutes being far above any model load seen, and the test's `stop` then ends the app.
    func ready(in root: URL) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: root.appending(path: "ready").path) {
            if done.withLock({ $0 }) {
                _ = try await report.value
                throw HarnessError.noReport
            }
            if Date() > deadline { throw HarnessError.neverReady }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

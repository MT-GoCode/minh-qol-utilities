import CoreGraphics
import Foundation
import TECore
import XCTest

private func domain() -> String { "gui/\(getuid())" }
private func launchctlLoaded(_ label: String) throws -> Bool { try AppHarness.sh("/bin/launchctl", ["print", "\(domain())/\(label)"]).status == 0 }
private func pid(_ label: String) throws -> Int? {
    let out = try AppHarness.sh("/bin/launchctl", ["print", "\(domain())/\(label)"]).out
    guard let m = try NSRegularExpression(pattern: "\n\tpid = (\\d+)\n").firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) else { return nil }
    return Int((out as NSString).substring(with: m.range(at: 1)))
}
private func parent(_ p: Int) throws -> String { try AppHarness.sh("/bin/ps", ["-o", "ppid=", "-p", "\(p)"]).out.trimmingCharacters(in: .whitespacesAndNewlines) }
private func listing(_ dir: URL) -> [String: Int] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return Dictionary(uniqueKeysWithValues: names.map { n in
        (n, ((try? FileManager.default.attributesOfItem(atPath: dir.appending(path: n).path))?[.size] as? Int) ?? 0)
    })
}
private func throwaway(_ test: XCTestCase) throws -> (label: String, plist: URL) {
    let label = "com.minh.transcribe-everything.test-" + UUID().uuidString.prefix(8).lowercased()
    let dir = temporaryRoot(test)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let plist = dir.appending(path: "\(label).plist")
    try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/bin/sleep", "1000"], "RunAtLoad": true] as [String: Any], format: .xml, options: 0).write(to: plist)
    test.addTeardownBlock { _ = try? AppHarness.sh("/bin/launchctl", ["bootout", "\(domain())/\(label)"]) }
    return (label, plist)
}

/// A temporary HOME, stub setup and build, and a recording launchctl first on PATH, because the launchd domain is global.
private struct Sandbox {
    let home: URL, repo: URL, shim: URL
    init(_ test: XCTestCase) throws {
        let root = temporaryRoot(test), fm = FileManager.default
        (home, repo, shim) = (root.appending(path: "home"), root.appending(path: "repo"), root.appending(path: "shim"))
        for d in [home, repo.appending(path: "app"), shim] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for f in ["install.sh", "uninstall.sh", "app/env.sh"] { try fm.copyItem(at: AppHarness.repo.appending(path: f), to: repo.appending(path: f)) }
        let stubs: [(URL, String)] = [
            (repo.appending(path: "setup.sh"), "#!/bin/bash\necho setup >> \"$HOME/calls\"\n"),
            (repo.appending(path: "build.sh"), "#!/bin/bash\necho build >> \"$HOME/calls\"\n. \"$(dirname \"$0\")/app/env.sh\"\nmkdir -p \"$APP/Contents/MacOS\"\necho bin > \"$APP/Contents/MacOS/TranscribeEverything\"\n"),
            (shim.appending(path: "launchctl"), "#!/bin/sh\necho \"launchctl $*\" >> \"$HOME/calls\"\n[ \"$1\" = bootout ] && exit 3\n[ \"$1\" = print ] && exit 113\nexit 0\n"),
        ]
        for (url, text) in stubs { try text.write(to: url, atomically: true, encoding: .utf8) }
        for url in stubs.map(\.0) + [repo.appending(path: "install.sh"), repo.appending(path: "uninstall.sh")] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
    func run(_ script: String, _ args: [String] = []) throws -> (status: Int32, out: String) {
        try AppHarness.sh("/bin/bash", [repo.appending(path: script).path] + args, env: ["HOME": home.path, "PATH": shim.path + ":" + ProcessInfo.processInfo.environment["PATH"]!])
    }
    var calls: [String] { ((try? String(contentsOf: home.appending(path: "calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var plist: URL { home.appending(path: "Library/LaunchAgents/com.minh.transcribe-everything.plist") }
    var app: URL { home.appending(path: "Applications/TranscribeEverything.app") }
    var data: URL { home.appending(path: ".transcribe-everything") }
}
private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

final class InstallTests: XCTestCase {
    func testInstallTwiceSucceedsEvenThoughBootoutFindsNothingLoaded() throws {
        let s = try Sandbox(self)
        XCTAssertEqual(try s.run("install.sh").status, 0)
        XCTAssertTrue(exists(s.data))
        XCTAssertEqual(try AppHarness.sh("/usr/bin/plutil", ["-lint", s.plist.path]).status, 0)
        let bytes = try Data(contentsOf: s.plist)
        XCTAssertEqual(try s.run("install.sh").status, 0)
        XCTAssertEqual(try Data(contentsOf: s.plist), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: s.home.appending(path: "Applications").path).count, 1)
    }

    func testUninstallKeepsDataAndPurgeRemovesOnlyTheDataRoot() throws {
        let s = try Sandbox(self), fm = FileManager.default
        XCTAssertEqual(try s.run("install.sh").status, 0)
        let kept = [s.data.appending(path: "config.json"), s.data.appending(path: "transcripts/a.jsonl")]
        let sentinels = [s.home.appending(path: ".transcribe-everything-notes/k"), s.home.appending(path: ".other/k"), s.home.appending(path: "Documents/k"), s.home.appending(path: "Applications/Other.app/Contents/k")]
        for f in kept + sentinels {
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: f)
        }
        XCTAssertEqual(try s.run("uninstall.sh").status, 0)
        XCTAssertFalse(exists(s.app))
        XCTAssertFalse(exists(s.plist))
        XCTAssertEqual(s.calls.last, "launchctl bootout gui/\(getuid())/com.minh.transcribe-everything")
        for f in kept + sentinels { XCTAssertTrue(exists(f), f.path) }
        XCTAssertEqual(try s.run("uninstall.sh").status, 0)
        XCTAssertEqual(try s.run("install.sh").status, 0)
        XCTAssertEqual(try s.run("uninstall.sh", ["--purge"]).status, 0)
        XCTAssertFalse(exists(s.data))
        for f in sentinels { XCTAssertTrue(exists(f), f.path) }
        XCTAssertFalse(exists(s.app))
        XCTAssertFalse(exists(s.plist))
    }

    func testUninstallRejectsAnUnknownArgumentAndChangesNothing() throws {
        let s = try Sandbox(self)
        XCTAssertEqual(try s.run("install.sh").status, 0)
        let before = s.calls
        let r = try s.run("uninstall.sh", ["--purg"])
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.out.contains("usage"))
        XCTAssertTrue(exists(s.app))
        XCTAssertTrue(exists(s.plist))
        XCTAssertEqual(s.calls, before)
    }

    func testHarnessStopsALoadedAgentForTheBodyAndStartsItAgain() throws {
        let a = try throwaway(self)
        XCTAssertEqual(try AppHarness.sh("/bin/launchctl", ["bootstrap", domain(), a.plist.path]).status, 0)
        XCTAssertNotNil(try pid(a.label))
        try AppHarness.withAgentStopped(label: a.label, plist: a.plist) { XCTAssertFalse(try launchctlLoaded(a.label)) }
        XCTAssertTrue(try launchctlLoaded(a.label))
        XCTAssertNotNil(try pid(a.label))
    }

    func testHarnessStartsTheAgentAgainWhenTheBodyThrows() throws {
        let a = try throwaway(self)
        XCTAssertEqual(try AppHarness.sh("/bin/launchctl", ["bootstrap", domain(), a.plist.path]).status, 0)
        XCTAssertThrowsError(try AppHarness.withAgentStopped(label: a.label, plist: a.plist) { throw Boom() }) { XCTAssertTrue($0 is Boom) }
        XCTAssertTrue(try launchctlLoaded(a.label))
    }

    /// The transcripts listing (name to byte size) from before the reinstall.
    private static let installed = Result<[String: Int], Error> {
        try AppHarness.ready.get()
        let before = listing(Paths().transcripts)
        for script in ["uninstall", "install"] {
            let log = resultsDir().appending(path: "\(script).log")
            let r = try AppHarness.sh("/bin/bash", [AppHarness.repo.appending(path: "\(script).sh").path], log: log)
            guard r.status == 0 else { throw HarnessError.buildFailed(r.status, log: log.path) }
        }
        return before
    }
    private func agentPid() async throws -> Int {
        var p: Int?
        try await eventually("agent running") {
            p = try pid(AppHarness.label)
            return p != nil
        }
        return p!
    }

    func testReinstallRunsTheAppDirectlyUnderTheAgentWithPermissionsAndTranscriptsKept() async throws {
        executionTimeAllowance = 1200
        let before = try Self.installed.get()
        let p = try await agentPid()
        XCTAssertEqual(try AppHarness.sh("/bin/ps", ["-o", "command=", "-p", "\(p)"]).out.trimmingCharacters(in: .whitespacesAndNewlines), AppHarness.executable(AppHarness.app).path)
        XCTAssertEqual(try parent(p), "1")
        try await eventually("the agent's engine started") { listing(Paths().transcripts).count > before.count }
        let now = listing(Paths().transcripts)
        for (name, size) in before { XCTAssertEqual(now[name], size, name) }
        let root = temporaryRoot(self)
        let report = try await Task.detached { try AppHarness.run(root: root, steps: [["op": "permissions"]]) }.value
        let granted = (report["results"] as! [[String: Any]])[0]["granted"] as! [String: Bool]
        for name in ["Microphone", "Screen Recording"] {
            XCTAssertEqual(granted[name], true, "grant \(name) in System Settings; a grant applies after relaunch")
        }
        _ = try await agentPid()
    }

    func testACrashedAppIsRestartedByTheAgent() async throws {
        executionTimeAllowance = 1200
        _ = try Self.installed.get()
        let p1 = try await agentPid()
        kill(pid_t(p1), SIGKILL)
        var p2: Int?
        try await eventually("restarted") {
            p2 = try pid(AppHarness.label)
            return p2 != nil && p2 != p1
        }
        XCTAssertEqual(try parent(p2!), "1")
    }

    func testTheInstalledAppBuiltItsOverlay() async throws {
        executionTimeAllowance = 1200
        try AppHarness.displayAwake.get()
        _ = try Self.installed.get()
        let p = try await agentPid()
        // The status item cannot be found this way: MenuBarAgent hosts it on this macOS (DECISIONS). The human gate sees the dot.
        var windows: [[String: Any]] = []
        try await eventually("overlay panel") {
            windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]).filter { $0[kCGWindowOwnerPID as String] as? Int == p }
            return windows.contains { $0[kCGWindowLayer as String] as? Int == 3 && ($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Int == 760 }
        }
        try "\(windows)\n".write(to: resultsDir().appending(path: "installed-windows.txt"), atomically: true, encoding: .utf8)
    }
}

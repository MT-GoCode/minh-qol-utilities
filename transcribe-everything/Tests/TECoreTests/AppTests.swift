import CryptoKit
import Foundation
import XCTest

final class AppTests: XCTestCase {
    private static let launch = Result<[String: Any], Error> {
        let turns = try Fixtures.turns().indices.map { ["op": "transcribe", "path": Fixtures.turnWav($0).path] }
        let clip = ["op": "transcribe", "path": Fixtures.turnWav(3).path]  // 11.9 s
        let root = FileManager.default.temporaryDirectory.appending(path: "te-app-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        return try AppHarness.run(root: root, steps: turns + [[String: Any]](repeating: clip, count: 9))
    }

    private func results() throws -> [[String: Any]] { try Self.launch.get()["results"] as! [[String: Any]] }

    func testEveryTurnUnderTheAppIdentityIsTextIdenticalToTheOracle() throws {
        XCTAssertEqual(try Self.launch.get()["bundleId"] as? String, "com.minh.transcribe-everything")
        let r = try results()
        XCTAssertEqual(r.count, 21)
        var table = "| turn | seconds | text |\n|---|---|---|\n"
        for i in 0..<12 {
            XCTAssertEqual(r[i]["text"] as? String, try Fixtures.oracleText(i))
            table += "| \(i) | \(r[i]["seconds"]!) | \(r[i]["text"]!) |\n"
        }
        try table.write(to: resultsDir().appending(path: "app.md"), atomically: true, encoding: .utf8)
    }

    func testTwelveSecondDecodeUnderTheAppIdentityStaysAtTheProbeLevel() throws {
        let clip = Array(try results()[12...])
        for c in clip { XCTAssertEqual(c["text"] as? String, try Fixtures.oracleText(3)) }
        // The fastest of the warm decodes: other load on the machine barely moves it, a slow build does. 2 x the 72 ms measured in the signed bundle.
        let fastest = clip.dropFirst().map { $0["seconds"] as! Double }.min()!
        try "12 s decode, fastest of 8: \(fastest) s\n".write(to: resultsDir().appending(path: "app-latency.md"), atomically: true, encoding: .utf8)
        XCTAssertLessThanOrEqual(fastest, 0.144)
    }

    func testInstalledAppIsDeveloperIDHardenedWithAudioEntitlementAndPlist() throws {
        try AppHarness.ready.get()
        let app = AppHarness.app.path
        let info = try AppHarness.sh("/usr/bin/codesign", ["-dvv", app]).out
        XCTAssertTrue(info.contains("Authority=Developer ID Application:"), info)
        XCTAssertTrue(info.contains("(runtime)"), info)
        XCTAssertTrue(info.contains("Identifier=com.minh.transcribe-everything"), info)
        XCTAssertEqual(try AppHarness.sh("/usr/bin/codesign", ["--verify", "--strict", app]).status, 0)
        XCTAssertTrue(try AppHarness.sh("/usr/bin/codesign", ["-d", "--entitlements", "-", app]).out.contains("com.apple.security.device.audio-input"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: AppHarness.app.appending(path: "Contents/Info.plist")), format: nil) as! [String: Any]
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertFalse((plist["NSMicrophoneUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertFalse((plist["NSAudioCaptureUsageDescription"] as? String ?? "").isEmpty)
    }

    func testBuildRefusesWithoutADeveloperIDIdentityAndLeavesTheInstalledAppAlone() throws {
        try AppHarness.ready.get()
        let shim = temporaryRoot(self)
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        let security = shim.appending(path: "security")
        try "#!/bin/sh\necho \"     0 valid identities found\"\n".write(to: security, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)
        let installed = AppHarness.executable(AppHarness.app)
        let before = SHA256.hash(data: try Data(contentsOf: installed))
        let r = try AppHarness.sh("/bin/bash", [AppHarness.repo.appending(path: "build.sh").path], env: ["PATH": shim.path + ":" + ProcessInfo.processInfo.environment["PATH"]!])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.out.contains("Developer ID Application"), r.out)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: installed)), before)
    }

    func testHarnessRefusesAStaleBinary() throws {
        let dir = temporaryRoot(self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appending(path: "a"), b = dir.appending(path: "b")
        try Data([1, 2, 3]).write(to: a)
        try Data([1, 2, 4]).write(to: b)  // same size, so a size check cannot pass
        XCTAssertThrowsError(try AppHarness.assertSameBinary(a, b))
        XCTAssertNoThrow(try AppHarness.assertSameBinary(a, a))
    }
}

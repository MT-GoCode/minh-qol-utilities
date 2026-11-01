import Foundation
import TECore
import XCTest

let captureTail = 5.0   // pacing: QuickTime start ≤ 2 s + commit bound 1.28 s + a decode; too short fails the WER check, never passes it
let frame = 320, speechThreshold: Float = 0.01   // fixtures.py:60

func eventually(_ what: String, _ body: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)  // chrome_capture.sh: 30 × 0.5 s
    while Date() < deadline {
        if try await body() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CaptureError.never(what)
}
enum CaptureError: Error { case never(String), tool(String) }

func floats(_ f32: URL) throws -> [Float] {
    let d = try Data(contentsOf: f32)
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func speechFrames(_ x: [Float]) -> [Bool] {
    stride(from: 0, to: x.count - frame + 1, by: frame).map { i in
        (x[i..<i + frame].reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot() >= speechThreshold
    }
}
func speechOnset(_ x: [Float]) -> Int { speechFrames(x).firstIndex(of: true)! * frame }
func speechRMS(_ x: [Float]) -> Float {
    var sum: Float = 0, n = 0
    for (k, s) in speechFrames(x).enumerated() where s {
        sum += x[k * frame..<(k + 1) * frame].reduce(0) { $0 + $1 * $1 }
        n += frame
    }
    return (sum / Float(n)).squareRoot()
}
func lastSpeechEnd(_ x: [Float]) -> Double { Double((speechFrames(x).lastIndex(of: true)! + 1) * frame) / 16000 }
func silentRuns(_ x: [Float]) -> [(start: Double, end: Double)] {
    let f = speechFrames(x), last = f.lastIndex(of: true)!
    var out: [(start: Double, end: Double)] = [], open: Int?
    for k in f.firstIndex(of: true)!...last {
        if !f[k], open == nil { open = k }
        if f[k], let o = open {
            out.append((Double(o * frame) / 16000, Double(k * frame) / 16000))
            open = nil
        }
    }
    return out
}
func maxClockDrift(_ a: [Arrival]) -> Double {
    a.map { abs($0.wall.timeIntervalSince(a[0].wall) - Double($0.end - a[0].end) / 16000) }.max()!
}
/// The wall time of the chunk that carried the sample, backed off by the samples after it, so delivery lag cancels.
func wallTime(of sample: Int, _ a: [Arrival]) -> Date {
    let c = a.first { $0.end > sample }!
    return c.wall.addingTimeInterval(-Double(c.end - sample) / 16000)
}

struct Arrival: Decodable { let end: Int; let wall: Date }
struct Report: Decodable {
    struct Ended: Decodable { let id: String; let error: String? }
    struct Src: Decodable { let file: String; let arrivals: [Arrival] }
    struct Shown: Decodable { let t: Date; let lines: [String: Int]; let tails: [String] }
    struct MicInfo: Decodable { let restarts: Int; let device: BoundDevice?; let defaultInput: String? }
    let ended: [Ended]; let sources: [String: Src]; let decodes: [Decode]; let shown: [Shown]; let lines: [Line]; let mic: MicInfo?
}
struct Captured {
    let report: Report, samples: [String: [Float]], transcript: URL
    /// A failed source delivered nothing to measure; say why instead of crashing on empty samples.
    func requireNoFailure() throws {
        let failed = report.ended.filter { $0.error != nil }
        if !failed.isEmpty { throw CaptureError.tool("\(failed)") }
    }
}

let micSource: [String: Any] = ["id": "mic", "kind": "mic"]
func appSource(_ id: String, _ tag: String, _ pid: Int) -> [String: Any] { ["id": id, "kind": "app", "tag": tag, "pid": pid] }

/// One launch of the app's `capture` op. `during` runs once every source delivers; `stop` is written when it returns.
func runCapture(_ test: XCTestCase, _ sources: [[String: Any]], extra: [String: Any] = [:], during: () async throws -> Void) async throws -> Captured {
    try AppHarness.displayAwake.get()
    let root = temporaryRoot(test)
    let stop = root.appending(path: "stop")
    test.addTeardownBlock { try? Data().write(to: stop) }  // an aborted test never leaves the app running
    let step: [String: Any] = (["op": "capture", "sources": sources] as [String: Any]).merging(extra) { $1 }
    let launch = Launch(root: root, steps: [step])
    try await launch.ready(in: root)
    try await during()
    try Data().write(to: stop)
    let r = try await launch.report.value
    let report = try JSONDecoder().decode(Report.self, from: JSONSerialization.data(withJSONObject: (r["results"] as! [[String: Any]])[0]))
    let samples = try report.sources.mapValues { try floats(root.appending(path: $0.file)) }
    let dir = Paths(root: root).transcripts
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    XCTAssertEqual(files.count, 1)
    return Captured(report: report, samples: samples, transcript: files[0])
}

/// QuickTime Player under test control. Refuses to start if one is running: the test quits it, and it may be Minh's.
enum QuickTime {
    private static func pids() throws -> [Int] {
        try AppHarness.sh("/usr/bin/pgrep", ["-x", "QuickTime Player"]).out.split(separator: "\n").compactMap { Int($0) }
    }
    private static func tell(_ body: String) throws -> String {
        let r = try AppHarness.sh("/usr/bin/osascript", ["-e", "with timeout of 10 seconds", "-e", "tell application \"QuickTime Player\" to \(body)", "-e", "end timeout"])
        if r.status != 0 { throw CaptureError.tool(r.out) }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func open(_ wav: URL, _ test: XCTestCase) async throws -> Int {
        guard try pids().isEmpty else { throw CaptureError.tool("QuickTime Player is already running") }
        test.addTeardownBlock { try? await quit() }
        try AppHarness.sh("/usr/bin/open", ["-g", "-a", "QuickTime Player", wav.path])
        try await eventually("QuickTime opened the file") { try !pids().isEmpty && tell("count documents") == "1" }
        return try pids()[0]
    }
    static func play() throws { _ = try tell("play document 1") }
    static func pause() throws { _ = try tell("pause document 1") }
    static func quit() async throws {
        guard try !pids().isEmpty else { return }
        _ = try tell("quit")
        try await eventually("QuickTime exited") { try pids().isEmpty }
    }
}

/// A throwaway Chrome (own profile) whose page plays `wav` once `go()` creates go.txt. Minh's Chrome is never touched.
/// Launched through LaunchServices: a child of this test would make the test, not Chrome, responsible for the audio helper.
struct Chrome {
    let pid: Int, dir: URL
    static func launch(_ test: XCTestCase, playing wav: URL) async throws -> Chrome {
        let dir = temporaryRoot(test)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appending(path: "page.html")
        try "<audio id=a src=\"\(wav.absoluteString)\"></audio><script>const t=setInterval(()=>fetch('go.txt').then(()=>{clearInterval(t);a.play()}).catch(()=>{}),100)</script>".write(to: page, atomically: true, encoding: .utf8)
        let profile = "user-data-dir=\(dir.path)/profile"  // no leading dashes: pgrep and pkill take it as a pattern
        test.addTeardownBlock { _ = try? AppHarness.sh("/usr/bin/pkill", ["-f", profile]) }  // runs before the directory removal: teardown is last-in first-out
        try AppHarness.sh("/usr/bin/open", ["-g", "-n", "-a", "Google Chrome", "--args", "--" + profile, "--no-first-run", "--no-default-browser-check", "--autoplay-policy=no-user-gesture-required", "--allow-file-access-from-files", "--new-window", page.absoluteString])
        var pid: Int?
        try await eventually("Chrome started") {
            // The main process is the one without a --type= argument.
            pid = try AppHarness.sh("/usr/bin/pgrep", ["-f", profile]).out.split(separator: "\n").compactMap { Int($0) }.first { p in
                ((try? AppHarness.sh("/bin/ps", ["-o", "args=", "-p", "\(p)"]).out) ?? "--type=").contains("--type=") == false
            }
            return pid != nil
        }
        return Chrome(pid: pid!, dir: dir)
    }
    func go() throws { try Data().write(to: dir.appending(path: "go.txt")) }
}

/// Words the captured path may lose beyond a decode of the file: captured audio passed through the mixer and is not sample-identical. Measured: at most 1 word per turn and 1 of 242 overall beyond oracle + cuts; these are twice and four times that.
let captureExcessPerTurn = 2, captureExcessTotal = 4

func sleepSeconds(_ s: Double) async throws { try await Task.sleep(for: .seconds(s)) }

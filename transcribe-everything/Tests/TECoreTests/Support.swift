import Foundation
import TECore
import XCTest

enum Fixtures {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/transcribe-everything/fixtures")
    struct Turn: Decodable {
        let speaker: String
        let start, end: Double
        let text: String
    }
    static func turns() throws -> [Turn] {
        let f = dir.appending(path: "conversation.json")
        guard FileManager.default.fileExists(atPath: f.path) else { fatalError("run ./test-setup.sh") }
        return try JSONDecoder().decode([Turn].self, from: Data(contentsOf: f))
    }
    static func turnWav(_ i: Int) -> URL { dir.appending(path: String(format: "turns/%02d.wav", i)) }
    static func oracleText(_ i: Int) throws -> String {
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: String(format: "oracle/%02d.json", i)))) as! [String: Any]
        return o["text"] as! String
    }
}

func normalize(_ s: String) -> [String] {
    String(s.lowercased().map { ("a"..."z").contains($0) || $0 == "'" ? $0 : " " }).split(separator: " ").map(String.init)
}

func wer(ref: String, hyp: String) -> (errors: Int, words: Int) {
    let r = normalize(ref), h = normalize(hyp)
    var d = Array(0...h.count)
    for i in r.indices {
        var prev = d[0]
        d[0] = i + 1
        for j in h.indices {
            (prev, d[j + 1]) = (d[j + 1], min(d[j + 1] + 1, d[j] + 1, prev + (r[i] == h[j] ? 0 : 1)))
        }
    }
    return (d[h.count], r.count)
}

func resultsDir() -> URL {
    guard let p = ProcessInfo.processInfo.environment["TE_RESULTS"] else { fatalError("run ./test.sh") }
    return URL(fileURLWithPath: p)
}

func collect(_ source: some TECore.AudioSource) async throws -> [Chunk] {
    var out: [Chunk] = []
    for try await c in source.chunks() { out.append(c) }
    return out
}

func temporaryRoot(_ test: XCTestCase) -> URL {
    let u = FileManager.default.temporaryDirectory.appending(path: "te-" + UUID().uuidString)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: u) }
    return u
}

struct Busy: Error {}

/// Decode time tripled at load 26 on 16 cores (DECISIONS): above the core count the latency bounds do not apply.
func machineIsBusy() -> Double? {
    var load = [0.0]
    getloadavg(&load, 1)
    return load[0] > Double(ProcessInfo.processInfo.activeProcessorCount) ? load[0] : nil
}

/// Before a timed test. Other work on this Mac comes and goes, so it waits up to 2 minutes, a few one-minute load decays, before refusing.
func waitForIdleMachine() throws {
    let deadline = Date().addingTimeInterval(120)
    while machineIsBusy() != nil, Date() < deadline { Thread.sleep(forTimeInterval: 5) }
    try requireIdleMachine()
}

/// After a timed test: a load that rose during the run voids its timings, so this one does not wait.
func requireIdleMachine() throws {
    if let load = machineIsBusy() {
        XCTFail("machine load \(load) exceeds \(ProcessInfo.processInfo.activeProcessorCount) cores: latency bounds do not apply")
        throw Busy()
    }
}

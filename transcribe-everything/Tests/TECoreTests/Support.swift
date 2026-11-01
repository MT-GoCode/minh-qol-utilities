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

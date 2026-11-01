import Foundation
import TECore
import XCTest

final class StoreTests: XCTestCase {
    private func line(_ text: String, start: Double = 0.5) -> Line {
        Line(t: Date(timeIntervalSince1970: 1_700_000_001.25), src: SourceID(rawValue: "mic"), tag: "Mic", spk: 1, text: text, start: start, end: start + 1.75)
    }

    func testAppendedLinesLandInTheFileInTheDocumentedShape() async throws {
        let root = temporaryRoot(self)
        let store = try TranscriptStore(paths: Paths(root: root), start: Date(timeIntervalSince1970: 1_700_000_000.5))
        let a = line("He said \"hi\"\nthen left, é")
        let b = Line(t: Date(timeIntervalSince1970: 1_700_000_002.5), src: SourceID(rawValue: "app"), tag: "Zoom", spk: 2, text: "two", start: 3.25, end: 4.5)
        let c = Line(t: Date(timeIntervalSince1970: 1_700_000_003.75), src: SourceID(rawValue: "x"), tag: "T", spk: 3, text: "three", start: 5.5, end: 6.25)
        for l in [a, b, c] { try await store.append(l) }

        XCTAssertEqual(store.file.lastPathComponent, "2023-11-14T22:13:20.500Z.jsonl")
        XCTAssertEqual(store.file.deletingLastPathComponent().lastPathComponent, "transcripts")
        let text = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        let rows = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 3)
        let first = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as! [String: Any]
        XCTAssertEqual(Set(first.keys), ["t", "src", "tag", "spk", "text", "start", "end"])
        XCTAssertEqual(first["t"] as? String, "2023-11-14T22:13:21.250Z")
        XCTAssertEqual(first["src"] as? String, "mic")
        XCTAssertEqual(first["tag"] as? String, "Mic")
        XCTAssertEqual(first["spk"] as? Int, 1)
        XCTAssertEqual(first["text"] as? String, "He said \"hi\"\nthen left, é")
        XCTAssertEqual(first["start"] as? Double, 0.5)
        XCTAssertEqual(first["end"] as? Double, 2.25)
        let last = try JSONSerialization.jsonObject(with: Data(rows[2].utf8)) as! [String: Any]
        XCTAssertEqual(last["t"] as? String, "2023-11-14T22:13:23.750Z")
        XCTAssertEqual(last["spk"] as? Int, 3)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, [a, b, c])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            try Date(try d.singleValueContainer().decode(String.self), strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        XCTAssertEqual(try rows.map { try decoder.decode(Line.self, from: Data($0.utf8)) }, [a, b, c])
        var noSpeaker = first
        noSpeaker["spk"] = nil
        XCTAssertThrowsError(try decoder.decode(Line.self, from: JSONSerialization.data(withJSONObject: noSpeaker)))
    }

    func testSecondInstanceMakesANewFileAndNeverReusesOne() async throws {
        let paths = Paths(root: temporaryRoot(self))
        let s = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try TranscriptStore(paths: paths, start: s)
        let b = try TranscriptStore(paths: paths, start: s + 1)
        XCTAssertNotEqual(a.file, b.file)
        try await a.append(line("a"))
        try await b.append(line("b"))
        XCTAssertTrue(try String(contentsOf: a.file, encoding: .utf8).contains("\"a\""))
        XCTAssertFalse(try String(contentsOf: a.file, encoding: .utf8).contains("\"b\""))
        XCTAssertThrowsError(try TranscriptStore(paths: paths, start: s))
    }

    func testEightConcurrentAppendersKeepEveryLineIntact() async throws {
        let store = try TranscriptStore(paths: Paths(root: temporaryRoot(self)))
        try await withThrowingTaskGroup(of: Void.self) { g in
            for k in 0..<8 {
                g.addTask {
                    for n in 0..<100 {
                        try await store.append(Line(t: Date(), src: SourceID(rawValue: "s\(k)"), tag: "t", spk: 1, text: "k\(k)-n\(n)", start: Double(k * 100 + n), end: 0))
                    }
                }
            }
            try await g.waitForAll()
        }
        let text = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.count, 800)
        let texts = try rows.map { (try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["text"] as! String }
        XCTAssertEqual(Set(texts), Set((0..<8).flatMap { k in (0..<100).map { "k\(k)-n\($0)" } }))
        let count = await store.snapshot().count
        XCTAssertEqual(count, 800)
    }
}

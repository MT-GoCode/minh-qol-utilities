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
        for l in [a, b, c] { try await store.commit([l], of: l.src) }

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
        let snapshot = await store.snapshot().lines
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

    func testDeleteOldKeepsExactlyTheCurrentFileAndForeignFiles() throws {
        let root = temporaryRoot(self), paths = Paths(root: root)
        _ = try TranscriptStore(paths: paths, start: Date(timeIntervalSince1970: 1))
        _ = try TranscriptStore(paths: paths, start: Date(timeIntervalSince1970: 2))
        let current = try TranscriptStore(paths: paths, start: Date(timeIntervalSince1970: 3))
        try "keep".write(to: paths.transcripts.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        func listing() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: paths.transcripts.path)) }
        try TranscriptStore.deleteOld(in: paths, except: current.file)
        XCTAssertEqual(try listing(), [current.file.lastPathComponent, "notes.txt"])
        try TranscriptStore.deleteOld(in: paths, except: nil)
        XCTAssertEqual(try listing(), ["notes.txt"])
        XCTAssertNoThrow(try TranscriptStore.deleteOld(in: Paths(root: temporaryRoot(self)), except: nil))
    }

    func testSecondInstanceMakesANewFileAndNeverReusesOne() async throws {
        let paths = Paths(root: temporaryRoot(self))
        let s = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try TranscriptStore(paths: paths, start: s)
        let b = try TranscriptStore(paths: paths, start: s + 1)
        XCTAssertNotEqual(a.file, b.file)
        try await a.commit([line("a")], of: SourceID(rawValue: "mic"))
        try await b.commit([line("b")], of: SourceID(rawValue: "mic"))
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
                        let src = SourceID(rawValue: "s\(k)")
                        try await store.commit([Line(t: Date(), src: src, tag: "t", spk: 1, text: "k\(k)-n\(n)", start: Double(k * 100 + n), end: 0)], of: src)
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
        let count = await store.snapshot().lines.count
        XCTAssertEqual(count, 800)
    }

    private let srcA = SourceID(rawValue: "A")
    private func tail(_ src: SourceID, _ text: String) -> Provisional { Provisional(src: src, tag: src.rawValue, spk: 1, text: text) }

    func testCommitEndsTheSegmentAtomicallyAndALateTailIsDropped() async throws {
        let store = try TranscriptStore(paths: Paths(root: temporaryRoot(self)))
        var l = line("done")
        l.src = srcA
        l.spk = 3
        var e = await store.epoch(of: srcA)
        XCTAssertEqual(e, 0)
        await store.setTail(tail(srcA, "hel"), epoch: 0)
        var s = await store.snapshot()
        XCTAssertEqual(s.tails, [tail(srcA, "hel")])
        e = try await store.commit([l], of: srcA)
        XCTAssertEqual(e, 1)
        s = await store.snapshot()
        XCTAssertEqual(s.lines, [l])
        XCTAssertEqual(s.tails, [])
        XCTAssertEqual(s.speakers, [srcA: [1, 3]])
        await store.setTail(tail(srcA, "late"), epoch: 0)
        s = await store.snapshot()
        XCTAssertEqual(s.tails, [])
        await store.setTail(Provisional(src: srcA, tag: "A", spk: 2, text: "new"), epoch: 1)
        s = await store.snapshot()
        XCTAssertEqual(s.tails.map(\.text), ["new"])
        XCTAssertEqual(s.speakers, [srcA: [1, 2, 3]])
        await store.setTail(tail(srcA, ""), epoch: 1)
        s = await store.snapshot()
        XCTAssertEqual(s.tails, [])
        e = try await store.commit([], of: srcA)
        XCTAssertEqual(e, 2)
        s = await store.snapshot()
        XCTAssertEqual(s.lines, [l])
    }

    func testNoReaderSeesALineTogetherWithItsOwnTail() async throws {
        let store = try TranscriptStore(paths: Paths(root: temporaryRoot(self)))
        let src = srcA, make = tail
        let base = line("x")
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask {
                for n in 0..<500 {
                    await store.setTail(make(src, "t\(n)"), epoch: n)
                    var l = base
                    l.text = "t\(n)"
                    try await store.commit([l], of: src)
                }
            }
            for _ in 0..<4 {
                g.addTask {
                    for _ in 0..<2000 {
                        let s = await store.snapshot()
                        let committed = Set(s.lines.map(\.text))
                        XCTAssertTrue(s.tails.allSatisfy { !committed.contains($0.text) })
                        await Task.yield()
                    }
                }
            }
            try await g.waitForAll()
        }
    }

    func testTailsAreInAttachOrderNotWriteOrder() async throws {
        let store = try TranscriptStore(paths: Paths(root: temporaryRoot(self)))
        let a = srcA, b = SourceID(rawValue: "B"), c = SourceID(rawValue: "C")
        for s in [b, a, c] { _ = await store.epoch(of: s) }
        for s in [a, c, b] { await store.setTail(tail(s, "x"), epoch: 0) }
        let order = await store.snapshot().tails.map(\.src)
        XCTAssertEqual(order, [b, a, c])
    }

    func testEveryWriteWakesTheReader() async throws {
        executionTimeAllowance = 60
        let store = try TranscriptStore(paths: Paths(root: temporaryRoot(self)))
        var it = store.changes.makeAsyncIterator()
        await store.setTail(tail(srcA, "x"), epoch: 0)
        var woke: Void? = await it.next()
        XCTAssertNotNil(woke)
        try await store.commit([], of: srcA)
        woke = await it.next()
        XCTAssertNotNil(woke)
    }
}

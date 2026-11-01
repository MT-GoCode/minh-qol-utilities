import Foundation
import TECore
import XCTest

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func L(_ src: String, _ text: String, ago: Double, spk: Int = 1, tag: String? = nil) -> Line {
    Line(t: now.addingTimeInterval(-ago), src: SourceID(rawValue: src), tag: tag ?? src, spk: spk, text: text, start: 0, end: 0)
}
private func T(_ src: String, _ text: String, spk: Int = 1) -> Provisional {
    Provisional(src: SourceID(rawValue: src), tag: src, spk: spk, text: text)
}
private func snapshot(_ lines: [Line], _ tails: [Provisional]) -> Snapshot {
    var speakers: [SourceID: Set<Int>] = [:]
    for l in lines { speakers[l.src, default: []].insert(l.spk) }
    for t in tails { speakers[t.src, default: []].insert(t.spk) }
    return Snapshot(lines: lines, tails: tails, speakers: speakers)
}
private func result(_ lines: [Line], tails: [Provisional] = [], attached: [String], expanded: Bool = false, at: Date = now, config: Config = Config()) -> Rendered {
    render(snapshot: snapshot(lines, tails), attached: Set(attached.map { SourceID(rawValue: $0) }), now: at, expanded: expanded, config: config)
}
private func texts(_ lines: [Line], tails: [Provisional] = [], attached: [String], expanded: Bool = false, at: Date = now, config: Config = Config()) -> [String] {
    result(lines, tails: tails, attached: attached, expanded: expanded, at: at, config: config).rows.map(\.text)
}

final class RenderTests: XCTestCase {
    func testTagAppearsWhenMoreThanOneSourceIsAttachedOrDisplayed() {
        XCTAssertEqual(texts([L("A", "Hello.", ago: 1)], attached: ["A"]), ["Hello."])
        XCTAssertEqual(texts([L("A", "Hello.", ago: 1)], attached: ["A", "B"]), ["[A] Hello."])
        XCTAssertEqual(texts([L("A", "Bye.", ago: 8), L("B", "Hi.", ago: 3)], attached: ["B"]), ["[A] Bye.", "[B] Hi."])
        XCTAssertEqual(texts([L("A", "Bye.", ago: 1)], attached: []), ["Bye."])
        XCTAssertEqual(texts([L("A", "Bye.", ago: 1)], tails: [T("B", "uh")], attached: ["A"]), ["[A] Bye.", "[B] uh"])
        let none = result([], attached: ["A", "B"])
        XCTAssertEqual(none.rows, [])
        XCTAssertNil(none.nextChange)
        XCTAssertEqual(texts([L("A", "x", ago: 1, tag: "Zoom Meeting")], attached: ["A", "B"]), ["[Zoom] x"])
        XCTAssertEqual(texts([L("A", "x", ago: 1, tag: "ab   cd")], attached: ["A", "B"]), ["[ab] x"])
    }

    func testSpeakerLabelOnlyForMultiSpeakerSourcesAndEarlierLinesRelabel() {
        let hi = L("A", "Hi.", ago: 10), yes = L("A", "Yes.", ago: 5, spk: 2), ok = L("B", "ok.", ago: 4)
        XCTAssertEqual(texts([hi, yes, ok], attached: ["A", "B"]), ["[A] [Speaker 1] Hi.", "[A] [Speaker 2] Yes.", "[B] ok."])
        XCTAssertEqual(texts([hi, ok], attached: ["A", "B"]), ["[A] Hi.", "[B] ok."])
        XCTAssertEqual(texts([L("A", "Old.", ago: 100, spk: 2), hi], attached: ["A"]), ["[Speaker 1] Hi."])
        XCTAssertEqual(texts([hi], tails: [T("A", "tail", spk: 2)], attached: ["A"]), ["[Speaker 1] Hi.", "[Speaker 2] tail"])
    }

    func testWindowEdges() {
        XCTAssertEqual(texts([L("A", "Out.", ago: 20.01), L("A", "In.", ago: 19.99)], attached: ["A"]), ["In."])
        XCTAssertEqual(texts([L("A", "Out.", ago: 60.01), L("A", "In.", ago: 59.99)], attached: ["A"], expanded: true), ["In."])
        XCTAssertEqual(texts([L("A", "Old.", ago: 59.99)], attached: ["A"]), [])
        var c = Config()
        c.windowSeconds = 5
        XCTAssertEqual(texts([L("A", "Out.", ago: 5.01), L("A", "In.", ago: 4.99)], attached: ["A"], config: c), ["In."])
    }

    func testSentenceExtension() {
        XCTAssertEqual(texts([L("A", "I think that", ago: 25), L("A", "this works.", ago: 15)], attached: ["A"]), ["I think that", "this works."])
        XCTAssertEqual(texts([L("A", "Done.", ago: 30), L("A", "I think that", ago: 25), L("A", "this works.", ago: 15)], attached: ["A"]), ["I think that", "this works."])
        for ended in ["Ok?", "Ok!", "Ok."] { XCTAssertEqual(texts([L("A", ended, ago: 30), L("A", "next", ago: 15)], attached: ["A"]), ["next"]) }
        XCTAssertEqual(texts([L("A", "Wait,", ago: 30), L("A", "next", ago: 15)], attached: ["A"]), ["Wait,", "next"])
        XCTAssertEqual(texts([L("A", "Wait", ago: 30), L("A", "next", ago: 15)], attached: ["A"]), ["Wait", "next"])
        XCTAssertEqual(texts([L("A", "x", ago: 70), L("A", "y", ago: 50), L("A", "z", ago: 15)], attached: ["A"]), ["y", "z"])
        XCTAssertEqual(texts([L("A", "p", ago: 59.99), L("A", "z", ago: 15)], attached: ["A"]), ["p", "z"])
        XCTAssertEqual(texts([L("A", "p", ago: 60.01), L("A", "z", ago: 15)], attached: ["A"]), ["z"])
        XCTAssertEqual(texts([L("A", "so", ago: 25), L("B", "Hello.", ago: 18), L("A", "yes.", ago: 15)], attached: ["A", "B"]), ["[A] so", "[B] Hello.", "[A] yes."])
        XCTAssertEqual(texts([L("A", "and", ago: 30)], attached: ["A"]), [])
    }

    func testOrderIsWallClockWithFractionsAndStableWithinACommit() {
        let lines = [L("A", "late.", ago: 3.25), L("B", "early.", ago: 3.75), L("A", "c1.", ago: 1), L("A", "c2.", ago: 1, spk: 2)]
        XCTAssertEqual(texts(lines, attached: ["A", "B"]), ["[B] early.", "[A] [Speaker 1] late.", "[A] [Speaker 1] c1.", "[A] [Speaker 2] c2."])
    }

    func testTailsComeLastAndAreProvisional() {
        let r = result([L("A", "Hi.", ago: 1)], tails: [T("B", "b-text"), T("A", "a-text")], attached: ["A", "B"])
        XCTAssertEqual(r.rows.map(\.text), ["[A] Hi.", "[B] b-text", "[A] a-text"])
        XCTAssertEqual(r.rows.map(\.provisional), [false, true, true])
    }

    func testNextChangeIsTheFirstTimeTheCaptionsChange() {
        let plain = [L("A", "b.", ago: 12), L("A", "a.", ago: 5)]
        XCTAssertEqual(result(plain, attached: ["A"]).nextChange, now.addingTimeInterval(8))
        XCTAssertEqual(texts(plain, attached: ["A"], at: now.addingTimeInterval(7.75)), ["b.", "a."])
        XCTAssertEqual(texts(plain, attached: ["A"], at: now.addingTimeInterval(8.25)), ["a."])
        XCTAssertEqual(result(plain, attached: ["A"], expanded: true).nextChange, now.addingTimeInterval(48))
        let extended = [L("A", "and", ago: 58), L("A", "go.", ago: 10)]
        XCTAssertEqual(result(extended, attached: ["A"]).nextChange, now.addingTimeInterval(2))
        XCTAssertEqual(texts(extended, attached: ["A"], at: now.addingTimeInterval(1.75)), ["and", "go."])
        XCTAssertEqual(texts(extended, attached: ["A"], at: now.addingTimeInterval(2.25)), ["go."])
        XCTAssertNil(result([], tails: [T("A", "x")], attached: ["A"]).nextChange)
    }

    func testCaptionsOfTheConversation() throws {
        let turns = try Fixtures.turns()
        let order = turns.reduce(into: [String]()) { if !$0.contains($1.speaker) { $0.append($1.speaker) } }
        let number = { (s: String) in order.firstIndex(of: s)! + 1 }
        let id = SourceID(rawValue: "conv")
        var lines: [Line] = []
        var captions = ""
        for (k, turn) in turns.enumerated() {
            let t = now.addingTimeInterval(turn.end)
            lines.append(Line(t: t, src: id, tag: "Conv", spk: number(turn.speaker), text: try Fixtures.oracleText(k), start: turn.start, end: turn.end))
            let rows = render(snapshot: snapshot(lines, []), attached: [id], now: t, expanded: false, config: Config()).rows.map(\.text)
            captions += "## after turn \(k)\n" + rows.joined(separator: "\n") + "\n\n"
            let multi = Set(turns[0...k].map(\.speaker)).count > 1
            for row in rows { XCTAssertFalse(row.hasPrefix("[Conv]")) }
            for j in 0...k {
                let text = try Fixtures.oracleText(j), gap = turn.end - turns[j].end
                let label = multi ? "[Speaker \(number(turns[j].speaker))] " : ""
                if gap <= 19.9 { XCTAssertTrue(rows.contains(label + text), "turn \(j) after \(k)") }
                if gap > 60 { XCTAssertFalse(rows.contains(label + text), "turn \(j) after \(k)") }
            }
        }
        try captions.write(to: resultsDir().appending(path: "captions.md"), atomically: true, encoding: .utf8)
    }
}

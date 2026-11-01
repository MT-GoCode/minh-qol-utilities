import AppKit
import Foundation
import TECore
import TEUI
import XCTest

private let base: [String: Any] = ["minSilence": 0.5, "maxSegment": 12.0, "speakerThreshold": 0.35, "speakerWindow": 2.0, "speakerHop": 0.5,
    "speakerConfirmWindows": 4, "windowSeconds": 20.0, "expandedSeconds": 60.0, "fontSize": 22, "fontSizeRange": [12, 48]]
private func json(_ edits: [String: Any] = [:]) -> Data {
    var d = base
    for (k, v) in edits { d[k] = v is NSNull ? nil : v }
    return try! JSONSerialization.data(withJSONObject: d)
}
private enum Style: CaseIterable { case inPlace, atomic, replace }
private func write(_ data: Data, _ file: URL, _ style: Style) throws {
    switch style {
    case .inPlace:
        let h = try FileHandle(forWritingTo: file)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: data)
        try h.close()
    case .atomic: try data.write(to: file, options: .atomic)
    case .replace:
        try FileManager.default.removeItem(at: file)
        try data.write(to: file)
    }
}
private func open(_ test: XCTestCase) async throws -> (ConfigStore, URL) {
    let file = Paths(root: temporaryRoot(test)).config
    return (try await ConfigStore.open(file: file), file)
}
private func fires(_ s: AsyncStream<Void>, within seconds: Double = 5) async -> Bool {
    await withTaskGroup(of: Bool.self) { g in
        g.addTask {
            var it = s.makeAsyncIterator()
            return await it.next() != nil
        }
        g.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let r = await g.next()!
        g.cancelAll()
        return r
    }
}
private func onDisk(_ file: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
private func views<T: NSView>(_ v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0) as [T] } }

final class ConfigTests: XCTestCase {
    private let minSilence025Segments = 16  // pinned by the first measured run; see DECISIONS

    func testFirstRunWritesTheDefaultsFileAndLoadsIt() async throws {
        let (store, file) = try await open(self)
        XCTAssertEqual(try onDisk(file) as NSDictionary, base as NSDictionary)
        let c = await store.current, error = await store.error
        XCTAssertEqual(c.fontSize, 22)
        XCTAssertEqual(c.minSilence, 0.5)
        XCTAssertEqual(c.fontSizeRange, 12...48)
        XCTAssertNil(error)
    }

    func testEditsAreSeenWhetherInPlaceAtomicOrReplaced() async throws {
        let (store, file) = try await open(self)
        for (style, n) in zip(Style.allCases, 30...) {
            try write(json(["fontSize": n, "minSilence": 0.25, "windowSeconds": 40.0]), file, style)
            try await eventually("\(style)") { await store.current.fontSize == n }
            let c = await store.current, error = await store.error
            XCTAssertEqual(c.minSilence, 0.25)
            XCTAssertEqual(c.windowSeconds, 40)
            XCTAssertNil(error)
        }
    }

    func testInvalidEditsKeepThePreviousValueAndShowTheReason() async throws {
        let (store, file) = try await open(self)
        try write(json(["fontSize": 30]), file, .atomic)
        try await eventually("30") { await store.current.fontSize == 30 }
        let before = await store.current
        let table: [(Data, String)] = [
            (Data("{".utf8), "not valid JSON"), (json(["fontSize": 99]), "fontSize"), (json(["fontSizeRange": [48, 12]]), "fontSizeRange"),
            (json(["minSilence": NSNull()]), "minSilence"), (json(["speakerHop": 0.0]), "speakerHop"),
            (json(["windowSeconds": 90.0]), "windowSeconds"), (json(["fontSize": "big"]), "fontSize"),
        ]
        for (data, expected) in table {
            try write(data, file, .atomic)
            try await eventually("error for \(expected)") { await store.error != nil }
            let error = await store.error, current = await store.current
            XCTAssertTrue(error?.contains(expected) ?? false, "\(String(describing: error))")
            XCTAssertEqual(current, before)
            try write(json(["fontSize": 30]), file, .atomic)
            try await eventually("recovered") { await store.error == nil }
        }
    }

    func testADeletedFileIsInvalidAndNotRecreated() async throws {
        let (store, file) = try await open(self)
        try write(json(["fontSize": 30]), file, .atomic)
        try await eventually("30") { await store.current.fontSize == 30 }
        try FileManager.default.removeItem(at: file)
        try await eventually("error") { await store.error != nil }
        let current = await store.current
        XCTAssertEqual(current.fontSize, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSetWritesTheFileAndRefusesOutOfRangeAndInvalidFiles() async throws {
        let (store, file) = try await open(self)
        var c = await store.current
        c.fontSize = 40
        try await store.set(c)
        XCTAssertEqual(try onDisk(file)["fontSize"] as? Int, 40)
        XCTAssertEqual(try onDisk(file)["minSilence"] as? Double, 0.5)
        let current = await store.current
        XCTAssertEqual(current.fontSize, 40)
        let bytes = try Data(contentsOf: file)
        c.fontSize = 50
        do {
            try await store.set(c)
            XCTFail("out of range")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try write(Data("{".utf8), file, .inPlace)
        try await eventually("invalid") { await store.error != nil }
        c.fontSize = 20
        do {
            try await store.set(c)
            XCTFail("invalid file")
        } catch { XCTAssertTrue("\(error)".contains("invalid"), "\(error)") }
        XCTAssertEqual(try Data(contentsOf: file), Data("{".utf8))
    }

    func testEachSubscriberGetsEveryChangeAndAnUnchangedSetPublishesNothing() async throws {
        let (store, _) = try await open(self)
        let a = await store.changes(), b = await store.changes()
        var c = await store.current
        c.fontSize = 33
        try await store.set(c)
        let fa = await fires(a), fb = await fires(b)
        XCTAssertTrue(fa)
        XCTAssertTrue(fb)
        try await store.set(c)
        let again = await fires(a, within: 0.5)
        XCTAssertFalse(again, "the watcher's own reload of the same file is also silent")
    }

    @MainActor func testFontSizeSliderSnapsToIntegersWritesTheFileAndFollowsEdits() async throws {
        _ = NSApplication.shared
        let (store, file) = try await open(self)
        let s = await FontSizeItem(config: store)
        let root = s.item.view!, slider = (views(root) as [NSSlider])[0], fields = views(root) as [NSTextField]
        let value = fields.first { $0.identifier?.rawValue == "fontSize.value" }!, error = fields.first { $0.identifier?.rawValue == "fontSize.error" }!
        func send(_ v: Double) {
            slider.doubleValue = v
            _ = slider.sendAction(slider.action, to: slider.target)
        }
        XCTAssertEqual(slider.minValue, 12)
        XCTAssertEqual(slider.maxValue, 48)
        XCTAssertEqual(value.stringValue, "22")
        XCTAssertTrue(error.isHidden)
        send(30.6)
        XCTAssertEqual(slider.doubleValue, 31)
        XCTAssertEqual(value.stringValue, "31")
        try await eventually("31 on disk") { try onDisk(file)["fontSize"] as? Int == 31 }
        for v in 20...25 { send(Double(v)) }
        try await eventually("25 on disk") { try onDisk(file)["fontSize"] as? Int == 25 }
        try await sleepSeconds(0.3)
        XCTAssertEqual(try onDisk(file)["fontSize"] as? Int, 25, "the last write lands last")
        try write(json(["fontSize": 18]), file, .inPlace)
        try await eventually("follows the file") { slider.doubleValue == 18 && value.stringValue == "18" }
        try write(json(["fontSize": 99]), file, .atomic)
        try await eventually("error shown") { !error.isHidden && error.stringValue.contains("fontSize") }
        XCTAssertEqual(slider.doubleValue, 18)
        let bytes = try Data(contentsOf: file)
        send(30)
        try await sleepSeconds(0.3)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(error.isHidden)
        try write(json(["fontSize": 18]), file, .atomic)
        try await eventually("error hidden") { error.isHidden }
    }

    @MainActor func testOverlayFontFollowsTheFile() async throws {
        let (store, file) = try await open(self)
        let rig = try OverlayRig(self, config: store), o = rig.overlay!
        rig.attached = [SourceID(rawValue: "A")]
        try await rig.say("A", "Hello there.")
        func size() -> CGFloat? {
            guard o.text.textStorage!.length > 0 else { return nil }
            return (o.text.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }
        try await eventually("22") { size() == 22 }
        try write(json(["fontSize": 31]), file, .atomic)
        try await eventually("31") { size() == 31 }
    }

    /// The source has started under the old value when the edit lands, and only then delivers audio, so only a read at each segment can see it.
    func testMinSilenceEditReachesARunningSource() async throws {
        executionTimeAllowance = 600
        let root = temporaryRoot(self), file = Paths(root: root).config
        let config = try await ConfigStore.open(file: file)
        let (engine, store) = try await makeEngine(root, config: config)
        let turns = try Fixtures.turns()
        func segments(_ id: SourceID) async -> (Int, Int) {
            _ = await awaitEnds(engine, 1)
            let lines = await store.snapshot().lines.filter { $0.src == id }
            return (lines.count - splits(lines) { turnOf($0, turns) }, lines.count)
        }
        let a = SourceID(rawValue: "a")
        await engine.attach(try FileSource(url: Fixtures.conversationWav, id: a, tag: "A"))
        let (segA, linesA) = await segments(a)
        XCTAssertEqual(segA, 14)
        let b = SourceID(rawValue: "b"), gate = Gate()
        await engine.attach(GatedSource(base: try FileSource(url: Fixtures.conversationWav, id: b, tag: "B"), gate: gate))
        try await sleepSeconds(0.3)  // the pipeline has read the config and waits for its first chunk
        try write(json(["minSilence": 0.25]), file, .atomic)
        try await eventually("edit") { await config.current.minSilence == 0.25 }
        await gate.release()
        let (segB, linesB) = await segments(b)
        try "minSilence 0.5: \(segA) segments, \(linesA) lines\nminSilence 0.25: \(segB) segments, \(linesB) lines\n".write(to: resultsDir().appending(path: "config.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(segB, minSilence025Segments)
        XCTAssertGreaterThan(segB, segA)
    }
}

/// Delivers nothing until the gate opens: a live source that has started but is still silent.
private struct GatedSource: TECore.AudioSource {
    let base: FileSource, gate: Gate
    var id: SourceID { base.id }
    var tag: String { base.tag }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                await gate.wait()
                do {
                    for try await chunk in base.chunks() { c.yield(chunk) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func stop() { base.stop() }
}

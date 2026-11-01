import Foundation

public struct Provisional: Equatable, Sendable {
    public var src: SourceID, tag: String, spk: Int, text: String
    public init(src: SourceID, tag: String, spk: Int, text: String) {
        self.src = src
        self.tag = tag
        self.spk = spk
        self.text = text
    }
}

public struct Snapshot: Equatable, Sendable {
    public var lines: [Line]
    public var tails: [Provisional]  // open segments with text, at most one per source, in attach order
    public var speakers: [SourceID: Set<Int>]  // every label of the engine start, including lines no longer displayed
    public init(lines: [Line], tails: [Provisional], speakers: [SourceID: Set<Int>]) {
        self.lines = lines
        self.tails = tails
        self.speakers = speakers
    }
}

/// One per engine start. Sole owner of displayed text.
public actor TranscriptStore {
    public nonisolated let file: URL
    /// Yields after every change. Coalesced: a reader redraws from `snapshot()`, so only "changed" matters.
    public nonisolated let changes: AsyncStream<Void>
    private let notify: AsyncStream<Void>.Continuation
    private let handle: FileHandle
    private var lines: [Line] = []
    private var speakers: [SourceID: Set<Int>] = [:]
    private var slots: [Slot] = []  // attach order
    private struct Slot {
        let src: SourceID
        var epoch = 0
        var tail: Provisional?
    }
    private static let isoMs = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(d.formatted(isoMs))
        }
        return e
    }()

    public init(paths: Paths, start: Date = Date()) throws {
        (changes, notify) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        try FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        file = paths.transcripts.appending(path: start.formatted(Self.isoMs) + ".jsonl")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileWriteFileExists) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
    }

    /// The segment id for tail writes. The first call per source fixes its place in `Snapshot.tails`.
    public func epoch(of src: SourceID) -> Int { slots[index(of: src)].epoch }

    /// Dropped when `epoch` is not the source's current one: that segment already committed.
    public func setTail(_ tail: Provisional, epoch: Int) {
        let i = index(of: tail.src)
        guard slots[i].epoch == epoch else { return }
        let new = tail.text.isEmpty ? nil : tail
        guard new != slots[i].tail else { return }  // a re-decode often returns the same text: no redraw
        slots[i].tail = new
        if let new { speakers[new.src, default: []].insert(new.spk) }
        notify.yield()
    }

    /// The only write of committed lines: appends them, clears the source's tail and ends its segment in one step.
    /// `new` may be empty, because a blank decode still ends the segment. Returns the next segment's epoch.
    @discardableResult
    public func commit(_ new: [Line], of src: SourceID) throws -> Int {
        defer { notify.yield() }
        let i = index(of: src)
        slots[i].tail = nil
        slots[i].epoch += 1
        for line in new {
            try handle.write(contentsOf: Self.encoder.encode(line) + [0x0A])
            lines.append(line)
            speakers[line.src, default: []].insert(line.spk)
        }
        return slots[i].epoch
    }

    public func snapshot() -> Snapshot { Snapshot(lines: lines, tails: slots.compactMap(\.tail), speakers: speakers) }

    private func index(of src: SourceID) -> Int {
        if let i = slots.firstIndex(where: { $0.src == src }) { return i }
        slots.append(Slot(src: src))
        return slots.count - 1
    }
}

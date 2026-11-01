import Foundation

public struct Rendered: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let text: String
        public let provisional: Bool
    }
    public let rows: [Row]  // oldest first: committed by t, then tails
    public let nextChange: Date?  // when the result next changes with no new data; never later than the first change
}

public func render(snapshot: Snapshot, attached: Set<SourceID>, now: Date, expanded: Bool, config: Config) -> Rendered {
    let window = expanded ? config.expandedSeconds : config.windowSeconds
    let inWindow = now.addingTimeInterval(-window), cap = now.addingTimeInterval(-config.expandedSeconds)

    // Nothing older than the cap can show, so cost stays flat over an all-day session.
    let first = snapshot.lines.lastIndex { $0.t < cap }.map { $0 + 1 } ?? 0
    // Per source: the first in-window line, extended back to the start of its sentence.
    var shown: [(i: Int, line: Line)] = []
    for group in Dictionary(grouping: Array(zip(first..., snapshot.lines[first...])), by: { $0.1.src }).values {
        guard var lo = group.firstIndex(where: { $0.1.t >= inWindow }) else { continue }
        while lo > 0, !endsSentence(group[lo - 1].1.text) { lo -= 1 }
        shown += group[lo...].map { (i: $0.0, line: $0.1) }
    }
    shown.sort { ($0.line.t, $0.i) < ($1.line.t, $1.i) }  // stable within a commit, whose lines share one t

    let tagged = attached.count > 1 || Set(shown.map(\.line.src) + snapshot.tails.map(\.src)).count > 1
    func row(_ src: SourceID, _ tag: String, _ spk: Int, _ text: String, provisional: Bool) -> Rendered.Row {
        var parts: [String] = []
        if tagged { parts.append("[\(tag.prefix(5).trimmingCharacters(in: .whitespaces))]") }
        if snapshot.speakers[src]!.count > 1 { parts.append("[Speaker \(spk)]") }
        return Rendered.Row(text: (parts + [text]).joined(separator: " "), provisional: provisional)
    }
    return Rendered(
        rows: shown.map { row($0.line.src, $0.line.tag, $0.line.spk, $0.line.text, provisional: false) }
            + snapshot.tails.map { row($0.src, $0.tag, $0.spk, $0.text, provisional: true) },
        nextChange: shown.map { $0.line.t.addingTimeInterval($0.line.t >= inWindow ? window : config.expandedSeconds) }.min())
}

private func endsSentence(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".?!".contains($0) } ?? false
}

# Stratum 5 Blueprint — Caption render rules (End of headless core Period)

# Uncertainties squashed

1. **No FluidAudio API is called.** `render` is pure Foundation over `Line`, `SourceID` (STRATUM-1-BLUEPRINT.md: `Line` fields `t: Date, src: SourceID, tag: String, spk: Int, text: String, start, end`; `SourceID` is `Hashable`, `RawRepresentable<String>`) and `Config` (`windowSeconds`, `expandedSeconds`, both `Double`). The test target already depends on `TECore`; the one test that reads fixtures reuses S1's `Fixtures` (`Support.swift`).
2. **OTHER.md has no S5 item.** Nothing to resolve there.
3. **`Snapshot` shape (S4 fills it).** S1's `TranscriptStore.snapshot()` returns `[Line]`. The shape `render` takes is `Snapshot { lines: [Line], tails: [Provisional] }` below. S4 owns the store's read side, so S4 declares both types in `TranscriptStore.swift` verbatim and changes `snapshot()` to return `Snapshot` (S1's `StoreTests` then read `.lines`). S5 declares nothing; it consumes them. `tails` order is the order `render` outputs tails in, so S4 supplies it in attach order (an array, never a dictionary's order). A source with no open segment has no entry.
4. **What the `Speaker N` rule counts.** "That source has > 1 speaker" = distinct `spk` over **all** of that source's committed lines in the snapshot (the engine start), plus its non-empty tail, not only the visible lines. Labels are per engine start (DECISIONS), so a source that had Speaker 2 a minute ago keeps labelling Speaker 1 now; and "earlier lines relabel" falls out because the decision is per source, not per line.
5. **Sentence extension, exact reading.** From a source's first in-window line, step back while the line before it does **not** end a sentence (`.`, `?`, `!` after trimming whitespace) and is not older than `expandedSeconds`. A source with no in-window line gets no extension. The open tail does not extend backwards: a force-cut segment is ≤ 12 s (`maxSegment`), so the commit before an open tail is at most about 12 s old and is in the window already; the only gap is a tail after a long silence, where a new utterance starts anyway.
6. **`nextChange` is the next expiry, and output only shrinks with time.** With no new data, a line cannot become visible later (extension anchors on in-window lines, which only expire; a later anchor extends back over a subset of what an earlier anchor did). So the first time the rendered text changes is the earliest expiry among displayed lines: `t + window` for in-window lines, `t + expandedSeconds` for extension-only lines. A time earlier than the true change would only cause one harmless re-render; the exactness test (test 7) pins both directions anyway. Tails have no expiry (S4 clears them).
7. **Window edge arithmetic.** In-window is `t >= now − window` (inclusive, STRATA S5). Tests use fractions that are exact in binary (`.25`, `.5`, whole seconds) at the line's `ago`, plus the 0.01 s margins STRATA names (20.01 / 19.99); at 0.01 the Double error (~1e-7 s at epoch 1.7e9) is far smaller than the margin.
8. **Tag text.** First 5 characters, then whitespace trimmed (DECISIONS: "first 5 chars of the window", STRATA S5: "first 5 chars, trimmed"). Applied in `render` only, the one place display rules live; idempotent if S10 already truncates.
9. **`attached` is the set of sources currently attached** (running). The caller (S9/S10 controller) owns it; render only reads `.count`.

# Blueprint

Files: `Sources/TECore/Render.swift`, `Tests/TECoreTests/RenderTests.swift`. Nothing else changes.

## The shape (declared by S4 in `TranscriptStore.swift`, quoted here as the contract)
```swift
public struct Provisional: Equatable, Sendable {
    public var src: SourceID, tag: String, spk: Int, text: String      // spk = the current label
    public init(src: SourceID, tag: String, spk: Int, text: String)
}
public struct Snapshot: Equatable, Sendable {
    public var lines: [Line]            // committed, in append order; per source, increasing t
    public var tails: [Provisional]     // open segments, one per source at most, in attach order
    public init(lines: [Line], tails: [Provisional])
}
```

## `Sources/TECore/Render.swift`
```swift
import Foundation

public struct Rendered: Equatable, Sendable {
    public struct Row: Equatable, Sendable { public let text: String; public let provisional: Bool }
    public let rows: [Row]             // oldest first; committed rows by t, then tails
    public let nextChange: Date?       // earliest expiry among displayed lines; nil if none
}

public func render(snapshot: Snapshot, attached: Set<SourceID>, now: Date, expanded: Bool, config: Config) -> Rendered {
    let window = expanded ? config.expandedSeconds : config.windowSeconds
    let inWindow = now.addingTimeInterval(-window), cap = now.addingTimeInterval(-config.expandedSeconds)

    // 1. Per source: first in-window line, extended back to the sentence start.
    var shown: [(i: Int, line: Line, fresh: Bool)] = []          // i = index in snapshot.lines
    for group in Dictionary(grouping: Array(snapshot.lines.enumerated()), by: { $0.element.src }).values {
        guard var lo = group.firstIndex(where: { $0.element.t >= inWindow }) else { continue }
        while lo > 0, !endsSentence(group[lo - 1].element.text), group[lo - 1].element.t >= cap { lo -= 1 }
        shown += group[lo...].map { ($0.offset, $0.element, $0.element.t >= inWindow) }
    }
    shown.sort { ($0.line.t, $0.i) < ($1.line.t, $1.i) }           // stable within a commit: equal t keeps append order

    // 2. Tags and speaker labels.
    let tails = snapshot.tails.filter { !$0.text.isEmpty }
    let tagged = attached.count > 1 || Set(shown.map(\.line.src) + tails.map(\.src)).count > 1
    let speakers = Dictionary(grouping: snapshot.lines.map { ($0.src, $0.spk) } + tails.map { ($0.src, $0.spk) }, by: \.0)
        .mapValues { Set($0.map(\.1)).count }
    func row(_ src: SourceID, _ tag: String, _ spk: Int, _ text: String, _ provisional: Bool) -> Rendered.Row {
        var parts: [String] = []
        if tagged { parts.append("[\(tag.prefix(5).trimmingCharacters(in: .whitespaces))]") }   // 5 = DECISIONS
        if speakers[src]! > 1 { parts.append("[Speaker \(spk)]") }
        return .init(text: (parts + [text]).joined(separator: " "), provisional: provisional)
    }
    return Rendered(
        rows: shown.map { row($0.line.src, $0.line.tag, $0.line.spk, $0.line.text, false) }
            + tails.map { row($0.src, $0.tag, $0.spk, $0.text, true) },
        nextChange: shown.map { $0.line.t.addingTimeInterval($0.fresh ? window : config.expandedSeconds) }.min())
}

private func endsSentence(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".?!".contains($0) } ?? false
}
```
Notes for the implementer: `speakers[src]!` cannot be nil (every shown line and tail source is in the snapshot's lines or tails). `render` reads no clock and no global; `now`, `expanded` and `config` arrive per call (ConfigStore's value is read by the caller).

## `Tests/TECoreTests/RenderTests.swift` (class `RenderTests`, category Render)
Helpers (test-local, expected values are literals, none computed by `render`):
```swift
let now = Date(timeIntervalSince1970: 1_700_000_000)
func L(_ src: String, _ text: String, ago: Double, spk: Int = 1, tag: String? = nil) -> Line   // t = now - ago; tag defaults to src; start=end=0
func T(_ src: String, _ text: String, spk: Int = 1) -> Provisional                              // tag = src
func texts(_ lines: [Line], tails: [Provisional] = [], attached: [String], expanded: Bool = false,
           at: Date = now, config: Config = Config()) -> [String]                              // render(...).rows.map(\.text)
```

1. `testTagAppearsWhenMoreThanOneSourceIsAttachedOrDisplayed` — table, each row `(attached, lines, tails) ⇒ expected texts`:
   - `{A}`, A "Hello." ⇒ `["Hello."]`
   - `{A,B}`, A "Hello." only (the two-attached-one-speaking row) ⇒ `["[A] Hello."]`
   - `{B}`, A "Bye." ago 8 and B "Hi." ago 3 (A just detached) ⇒ `["[A] Bye.", "[B] Hi."]`
   - `{}`, A "Bye." ⇒ `["Bye."]`
   - `{A}`, A "Bye." plus tail B "uh" ⇒ `["[A] Bye.", "[B] uh"]`
   - `{A,B}`, nothing ⇒ `[]` and `nextChange == nil`
   - `{A,B}`, tag `"Zoom Meeting"` ⇒ `[Zoom]`; tag `"ab   cd"` ⇒ `[ab]` (prefix 5 = `ab   `, trimmed)
   Mutants: drop the `attached.count > 1` term ⇒ row 2 red; use only displayed sources for the rule ⇒ row 2 red; use only `attached` ⇒ rows 3 and 5 red; no trim ⇒ last row red.
2. `testSpeakerLabelOnlyForMultiSpeakerSourcesAndEarlierLinesRelabel` — attached `{A,B}`: A "Hi." spk 1 ago 10, A "Yes." spk 2 ago 5, B "ok." spk 1 ago 4 ⇒ `["[A] [Speaker 1] Hi.", "[A] [Speaker 2] Yes.", "[B] ok."]`. Same snapshot without the spk 2 line ⇒ `["[A] Hi.", "[B] ok."]`. Source A with an old out-of-window spk 2 line (ago 100) and an in-window spk 1 line, attached `{A}` ⇒ `["[Speaker 1] Hi."]`. Source A with one spk 1 line and a tail with spk 2 ⇒ both rows carry labels. Mutant: count speakers over shown lines only ⇒ third case red; label by line instead of by source ⇒ first row red.
3. `testWindowEdges` — A attached; lines `"Out."` ago 20.01 and `"In."` ago 19.99 ⇒ `["In."]`. Expanded: ago 60.01 out and 59.99 in, and in non-expanded a line ago 59.99 is absent. `config.windowSeconds = 5` (render per call reads config): ago 4.99 in, 5.01 out. Mutant: `>` and `<` swapped, or `expandedSeconds` ignored ⇒ red.
4. `testSentenceExtension`, attached `{A}`, all in one source unless stated:
   - A "I think that" ago 25, A "this works." ago 15 ⇒ both rows. With a third earlier A "Done." ago 30 ⇒ "Done." absent.
   - Previous line ends `?` / `!` / `.` (ago 30) ⇒ only `["next"]`; ends `,` or no mark ⇒ `["Wait,", "next"]`, `["Wait", "next"]`.
   - No punctuation anywhere: A "x" ago 70, "y" ago 50, "z" ago 15 ⇒ `["y","z"]` (cap `expandedSeconds`). Previous line ago 59.99 shown, ago 60.01 not.
   - Per source: A "so" ago 25, B "Hello." ago 22, A "yes." ago 15, attached `{A,B}` ⇒ `["[A] so", "[B] Hello.", "[A] yes."]`.
   - A source with only an old unpunctuated line (ago 30 "and") ⇒ `[]`.
   Mutants: drop the extension ⇒ first, second and fourth bullets red; extend by displayed lines only ⇒ red; no cap ⇒ "x" appears, red; stop on `,` ⇒ `["Wait,","next"]` red.
5. `testOrderIsWallClockWithFractionsAndStableWithinACommit` — snapshot appended out of order: A "late." ago 3.25, B "early." ago 3.75, A "c1." ago 1 spk 1 and A "c2." ago 1 spk 2 (same t, appended in that order), attached `{A,B}` ⇒ `["[B] early.", "[A] late.", "[A] [Speaker 1] c1.", "[A] [Speaker 2] c2."]` (.75 before .25 of the next whole second proves fractions count). Mutant: sort by `t` truncated to seconds, or reverse the tie ⇒ red.
6. `testTailsComeLastAreProvisionalAndEmptyOnesVanish` — committed A "Hi." ago 1; tails `[T(B,"b-text"), T(A,"a-text"), T(C,"")]`, attached `{A,B,C}` ⇒ `["[A] Hi.", "[B] b-text", "[A] a-text"]` with `provisional == [false, true, true]` (tail order = array order; empty tail omitted and its source not counted for tags). Mutant: tails sorted among committed rows by anything ⇒ red.
7. `testNextChangeIsTheFirstTimeTheCaptionsChange` — exactness in both directions via re-render:
   - Case 1: A "b." ago 12, A "a." ago 5 ⇒ `nextChange == now+8`; `texts(at: now+7.75)` equals `texts(at: now)` (`["b.","a."]`); `texts(at: now+8.25) == ["a."]`. Expanded ⇒ `nextChange == now+48`.
   - Case 2 (extension-only line): A "and" ago 58, A "go." ago 10 ⇒ `nextChange == now+2` (`58+2 = 60`); at `now+1.75` rows unchanged (`["and","go."]`); at `now+2.25` ⇒ `["go."]`.
   - Case 3: only a tail ⇒ `nextChange == nil`.
   Mutants: `t + window` for every line ⇒ case 2 red; max instead of min ⇒ case 1 red.
8. `testCaptionsOfTheConversation` — the human-verifiable result. `Fixtures.turns()` gives 12 turns (`speaker`, `start`, `end`); lines are built from them: `t = base + turn.end` (`base = Date(timeIntervalSince1970: 1_700_000_000)`), `src` `"conv"`, `tag` `"Conv"`, `spk` = 1, 2, 3 by order of first appearance of `turn.speaker`, `text = Fixtures.oracleText(i)` (Ultra's own punctuated text). For each turn `k` in order, render `Snapshot(lines: first k+1 lines, tails: [])`, `attached {conv}`, `now = t_k`, collapsed. Append each rendered caption block to `resultsDir()/captions.md` (`## after turn k`, the rows one per line) and print the file at the end of the test. Assertions (derived from `turns()`, not from `render`): every row starts with `[Speaker n] ` where `n` is the truth speaker's number for the turn whose oracle text the row ends with; no row has a `[Conv]` tag (one source); the rows are a consecutive run of turns ending at turn `k`; every turn `j ≤ k` with `end_k − end_j ≤ 20` is present; no turn with `end_k − end_j > 60` is present. Mutant: shift tag rule to `attached.count >= 1` ⇒ red (tags appear).
9. **Mutation pass** (all listed above) by hand before commit: apply, `./test.sh Render`, red; `git checkout -- Sources/TECore/Render.swift`; green. The three STRATA mutants (drop the > 1-source rule, displayed-lines-only, drop the extension) are rows in tests 1 and 4.

## Attaining the result (in order)
1. `./test.sh Render` ⇒ all `RenderTests` green; prints `results: test-results/<timestamp>`.
2. `cat test-results/<timestamp>/captions.md` ⇒ the S3-shaped conversation as the overlay will show it: `[Speaker 1] …` lines, expiring as the turns advance, no tags.
3. `./test.sh` ⇒ the whole suite green (S1–S5): the headless core is complete.
4. **End of headless core Period**: a FRESH adversarial subagent reviews the **whole codebase** since S1 (not only `Render.swift`) with `~/minh-agent-doctrines/code-principles.md` and `strata-rules.md`; rounds until a round returns no HIGH or MEDIUM; then commit.

## Not in this stratum
Overlay drawing, the timer that fires at `nextChange`, provisional-tail production (S4), the `attached` set's owner (S9/S10), any config UI.

# Review corrections (apply at build; these override the tests above)
- Test 4: B "Hello." at ago 18, so it is in the window; order unchanged.
- Test 5: expected `["[B] early.", "[A] [Speaker 1] late.", "[A] [Speaker 1] c1.", "[A] [Speaker 2] c2."]`; A has two speakers, so every A row is labelled.
- Test 8: a `[Speaker n]` label is expected only once truth turns 0...k hold more than one distinct speaker; otherwise assert none. Use end diff <= 19.9 for "must be present".
- Compute freshness inside the `nextChange` closure instead of a tuple field. `nextChange` is never later than the first change; an extra re-render is harmless.
- S4 declares `Snapshot` and `Provisional`.

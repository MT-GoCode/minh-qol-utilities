import AppKit
import TECore

/// Wall clock and a sleep on it; the one injection point for time.
public struct OverlayTime: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Date) async throws -> Void
    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Date) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }
    public static let system = OverlayTime(now: { Date() }, sleep: { try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow))) })
}

public final class OverlayPanel: NSPanel { public override var canBecomeKey: Bool { true } }

/// Clicking the text takes the keyboard (copy needs it); bar controls do not (becomesKeyOnlyIfNeeded).
public final class CaptionText: NSTextView { public override var needsPanelToBecomeKey: Bool { true } }

@MainActor public final class Overlay: NSObject {
    static let width = 760.0  // the probed panel, confirmed by Minh's real mouse
    static let barHeight = 28.0  // the probe's 24 pt grip + 4
    static let maxHeightFraction = 0.4  // DECISIONS

    public let panel: OverlayPanel
    public let text: CaptionText
    public let scroll = NSScrollView()
    let bar = NSView()
    private let config: ConfigStore, attached: @MainActor () -> Set<SourceID>, time: OverlayTime
    private var store: TranscriptStore?, feed: Task<Void, Never>?, expiry: Task<Void, Error>?
    private var placed: CGFloat?, follows = true
    private var kicks: AsyncStream<Void>.Continuation!, waiters: [CheckedContinuation<Void, Never>] = []
    var expanded = false

    public init(config: ConfigStore, attached: @escaping @MainActor () -> Set<SourceID>, time: OverlayTime = .system) {
        self.config = config
        self.attached = attached
        self.time = time
        // Top at 45% of the visible height: leaves the 40% maximum growth room below it. A decision, not a measurement.
        let screen = NSScreen.screens[0].visibleFrame
        panel = OverlayPanel(contentRect: NSRect(x: screen.midX - Self.width / 2, y: screen.minY + screen.height * 0.45 - Self.barHeight, width: Self.width, height: Self.barHeight),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // a shadow would draw around the text on a clear window
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false  // an accessory app deactivates whenever a menu closes
        panel.becomesKeyOnlyIfNeeded = true
        text = CaptionText(usingTextLayoutManager: false)  // TextKit 1: place() reads usedRect
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: 1e7, height: 1e7)
        text.textContainer!.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.frame = NSRect(x: 0, y: 0, width: Self.width, height: 0)
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false  // the wheel still scrolls
        super.init()
        panel.contentView!.subviews = [bar, scroll]
        bar.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.barHeight)
        scroll.frame = .zero
        let (stream, kicks) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.kicks = kicks
        // One consumer: two concurrent draws could apply an older snapshot last.
        Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                let ws = waiters
                waiters = []
                await draw()
                ws.forEach { $0.resume() }
            }
        }
        Task { [weak self] in  // a changed config redraws, and ends any selection like any user change
            for await _ in await config.changes() {
                guard let self else { return }
                userChange()
            }
        }
        let poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in  // the probe's rate, confirmed by Minh's real mouse
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                if self.panel.isVisible { self.pollMouse(at: NSEvent.mouseLocation, pressed: NSEvent.pressedMouseButtons) }
            }
        }
        poll.tolerance = 1.0 / 240  // a quarter period: lets wakeups coalesce, keeps a flip within one display refresh
        panel.orderFrontRegardless()
    }

    /// One per engine start.
    public func bind(_ store: TranscriptStore) {
        feed?.cancel()
        self.store = store
        feed = Task { [kicks] in for await _ in store.changes { kicks!.yield() } }
        refresh()
    }

    /// Anything but the store: the attach set, failures, hide and expand. The task completes after a draw that started after this call.
    @discardableResult public func refresh() -> Task<Void, Never> {
        Task { await withCheckedContinuation { waiters.append($0); kicks.yield() } }
    }

    /// A change the user asked for ends any selection, then redraws.
    func userChange() {
        text.setSelectedRange(NSRange(location: 0, length: 0))
        refresh()
    }

    /// Click-through: only bar controls and the text itself take the mouse. Frozen while a button is down so a drag never flips it.
    public func pollMouse(at p: NSPoint, pressed: Int) {
        guard pressed == 0 else { return }
        let w = panel.convertPoint(fromScreen: p)
        panel.ignoresMouseEvents = !interactive.contains { $0.contains(w) }
    }
    /// Per line: the text view's own used rect always spans the full width, which would swallow clicks beside short lines.
    private var interactive: [NSRect] {
        var rects = bar.subviews.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }
        let lm = text.layoutManager!, clip = scroll.convert(scroll.bounds, to: nil)
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forBoundingRect: text.visibleRect, in: text.textContainer!)) { _, used, _, _, _ in
            rects.append(self.text.convert(used, to: nil).intersection(clip))
        }
        return rects
    }

    private func draw() async {
        guard let store else { return }
        let snapshot = await store.snapshot(), config = await config.current
        let r = render(snapshot: snapshot, attached: attached(), now: time.now(), expanded: expanded, config: config)
        if scroll.frame.height > 0 { follows = scroll.contentView.bounds.maxY >= text.frame.height - 1 }  // read before the text changes; 1 pt is layout rounding
        writeText(r, config)
        place()
        if follows { text.scroll(NSPoint(x: 0, y: max(0, text.frame.height - scroll.contentView.bounds.height))) }
        expiry?.cancel()
        expiry = r.nextChange.map { next in
            // render's edge is inclusive: waking exactly at `next` would redraw the same result in a hot loop.
            Task { [kicks, time] in
                try await time.sleep(Date(timeIntervalSinceReferenceDate: next.timeIntervalSinceReferenceDate.nextUp))
                kicks!.yield()
            }
        }
    }

    private func writeText(_ r: Rendered, _ config: Config) {
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        let s = NSAttributedString(string: r.rows.map(\.text).joined(separator: "\n"), attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: CGFloat(config.fontSize), weight: .semibold), .shadow: shadow])
        if !text.textStorage!.isEqual(to: s) { text.textStorage!.setAttributedString(s) }  // rewriting would collapse a selection
    }

    /// Top stays fixed; the panel grows downward.
    private func place() {
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager!.usedRect(for: text.textContainer!).height
        // An empty text view still lays out one line: no captions means no body.
        let body = text.textStorage!.length == 0 ? 0 : min(used, Self.maxHeightFraction * (panel.screen ?? NSScreen.screens[0]).visibleFrame.height)
        guard body != placed else { return }
        placed = body
        let f = panel.frame, h = Self.barHeight + body
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: Self.width, height: h), display: true)
        bar.frame = NSRect(x: 0, y: body, width: Self.width, height: Self.barHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: body)
    }
}

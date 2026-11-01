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
public final class CaptionText: NSTextView {
    public override var needsPanelToBecomeKey: Bool { true }
    var pressed = false  // true exactly while a mouse press is being tracked: NSTextView.mouseDown runs its tracking loop inside the call
    var onRelease: (() -> Void)?
    public override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }  // the first click selects; it does not just make the panel key
    public override func mouseDown(with e: NSEvent) {
        pressed = true
        super.mouseDown(with: e)
        pressed = false
        onRelease?()
    }
    public override func dragSelection(with e: NSEvent, offset: NSSize, slideBack: Bool) -> Bool { false }  // highlight and copy only
}

final class Grip: NSButton { override func mouseDown(with e: NSEvent) { window!.performDrag(with: e) } }

@MainActor public final class Overlay: NSObject {
    static let width = 760.0  // the probed panel, confirmed by Minh's real mouse
    static let barHeight = 28.0  // the probe's 24 pt grip + 4
    static let maxHeightFraction = 0.4  // DECISIONS
    static let noteX = 88.0  // after three controls at pitch 28 (the probe's 24 pt grip + 4) from x = 4

    public let panel: OverlayPanel
    public let text: CaptionText
    public let scroll = NSScrollView()
    let bar = NSView()
    private let config: ConfigStore, attached: @MainActor () -> Set<SourceID>, failures: @MainActor () -> [String], time: OverlayTime
    private let grip = Grip(title: "", target: nil, action: nil), expand = NSButton(title: "", target: nil, action: nil), eye = NSButton(title: "", target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    /// The one copy: the eye image, the menu title and the panel height derive from it.
    public private(set) var captionsHidden = false {
        didSet {
            eye.image = Self.eyeImage(hidden: captionsHidden)
            hideShowItem.title = captionsHidden ? "Show" : "Hide"
            userChange()
        }
    }
    public private(set) var hideShowItem = NSMenuItem(title: "Hide", action: #selector(toggleCaptions), keyEquivalent: "")
    private var store: TranscriptStore?, feed: Task<Void, Never>?, expiry: Task<Void, Error>?
    private var placed: CGFloat?, follows = true
    private var kicks: AsyncStream<Void>.Continuation!, waiters: [CheckedContinuation<Void, Never>] = []
    var expanded = false
    private var held = false  // a data-driven text write was skipped and is owed
    private var holding: Bool { text.pressed || text.selectedRange().length > 0 }  // a replacement would destroy the selection
    private func releaseIfHeld() { if held && !holding { refresh() } }

    public init(config: ConfigStore, attached: @escaping @MainActor () -> Set<SourceID>, failures: @escaping @MainActor () -> [String] = { [] },
                autosaveName: String = "TranscribeEverythingOverlay", time: OverlayTime = .system) {
        self.config = config
        self.attached = attached
        self.failures = failures
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
        hideShowItem.target = self
        func styled(_ s: String) -> NSAttributedString { Self.styled(s, size: 18) }  // the probe's grip font
        grip.attributedTitle = styled("\u{283F}")
        expand.attributedTitle = styled("\u{2303}")
        expand.target = self
        expand.action = #selector(toggleExpanded)
        eye.target = self
        eye.action = #selector(toggleCaptions)
        eye.imagePosition = .imageOnly
        eye.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        eye.contentTintColor = .white
        eye.image = Self.eyeImage(hidden: false)
        for (i, (control, id)) in [(grip as NSButton, "grip"), (expand, "expand"), (eye, "eye")].enumerated() {
            control.isBordered = false
            control.identifier = NSUserInterfaceItemIdentifier(id)
            control.frame = NSRect(x: 4 + 28 * Double(i), y: 2, width: 24, height: 24)
            bar.addSubview(control)
        }
        note.font = .systemFont(ofSize: 13, weight: .semibold)
        note.textColor = .white
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        note.identifier = NSUserInterfaceItemIdentifier("failure")
        bar.addSubview(note)
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
        text.onRelease = { [weak self] in self?.releaseIfHeld() }
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: text, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseIfHeld() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.text.setSelectedRange(NSRange(location: 0, length: 0)) }  // fires the observer above
        }
        // An accessory app needs no other main menu; this hidden one exists only so ⌘C resolves.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")  // target nil: first responder of the key window
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
        precondition(panel.setFrameAutosaveName(autosaveName))  // restores a saved frame, moved back onto a screen if it is off every screen
        panel.orderFrontRegardless()
    }

    private static func styled(_ s: String, size: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        return NSAttributedString(string: s, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: size, weight: .semibold), .shadow: shadow])
    }
    private static func eyeImage(hidden: Bool) -> NSImage { NSImage(systemSymbolName: hidden ? "eye.slash" : "eye", accessibilityDescription: nil)! }
    @objc public func toggleCaptions() { captionsHidden.toggle() }
    @objc private func toggleExpanded() {
        expanded.toggle()
        userChange()
    }
    private func setNote() {
        let s = failures().joined(separator: "  ")
        guard s != note.stringValue else { return }
        note.stringValue = s
        note.isHidden = s.isEmpty
        note.frame = NSRect(x: Self.noteX, y: 5, width: min(note.fittingSize.width, Self.width - Self.noteX), height: 18)
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
        setNote()  // a failure matters most while the captions are hidden
        guard let store, !captionsHidden else {
            expiry?.cancel()
            place()
            return
        }
        let snapshot = await store.snapshot(), config = await config.current
        let r = render(snapshot: snapshot, attached: attached(), now: time.now(), expanded: expanded, config: config)
        if scroll.frame.height > 0 { follows = scroll.contentView.bounds.maxY >= text.frame.height - 1 }  // read before the text changes; 1 pt is layout rounding
        if holding { held = true } else {
            held = false
            writeText(r, config)
        }
        place()
        if follows, !held { text.scroll(NSPoint(x: 0, y: max(0, text.frame.height - scroll.contentView.bounds.height))) }
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
        let s = Self.styled(r.rows.map(\.text).joined(separator: "\n"), size: CGFloat(config.fontSize))
        if !text.textStorage!.isEqual(to: s) { text.textStorage!.setAttributedString(s) }  // rewriting would collapse a selection
    }

    /// Top stays fixed; the panel grows downward.
    private func place() {
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager!.usedRect(for: text.textContainer!).height
        // An empty text view still lays out one line: no captions means no body. A zero body also empties the text's click rectangles.
        let body = captionsHidden || text.textStorage!.length == 0 ? 0 : min(used, Self.maxHeightFraction * (panel.screen ?? NSScreen.screens[0]).visibleFrame.height)
        guard body != placed else { return }
        placed = body
        let f = panel.frame, h = Self.barHeight + body
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: Self.width, height: h), display: true)
        bar.frame = NSRect(x: 0, y: body, width: Self.width, height: Self.barHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: body)
    }
}

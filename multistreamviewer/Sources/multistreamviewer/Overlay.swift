import AppKit
import SwiftUI

// Hold ⌘⌥ → a full-screen view of every desktop laid out spatially, each showing its
// windows. Release hides it (peek). It's a NAVIGATOR, not a space switch: nothing on the
// real screen moves — clicking a desktop just makes it current (and raises its window),
// clicking a window raises that window. The menu can also pin it open for mouse work.
@MainActor
final class Overlay: ObservableObject {
    static let shared = Overlay()

    @Published private(set) var groups: [GroupView] = []
    private var panel: NSPanel?
    private var pinned = false
    private var peek: DispatchWorkItem?

    var isOpen: Bool { panel != nil }

    /// ⌘⌥ held: show after a short quiet delay so ⌘⌥+key chords (⌘⌥I, ⌘⌥esc, …) don't
    /// flash it. Re-checks the modifiers are still down when the delay fires.
    func scheduleHeld() {
        guard !isOpen, peek == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.peek = nil
            guard CGEventSource.flagsState(.combinedSessionState)
                .isSuperset(of: [.maskCommand, .maskAlternate]) else { return }
            self?.present(pinned: false)
        }
        peek = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// ⌘⌥⇥ cursor: which desktop releasing ⌘⌥ will jump to. nil = plain peek.
    @Published private(set) var selected: UUID?

    /// ⌘⌥⇥ / ⌘⌥⇧⇥: open now (no peek delay) and move the cursor, starting from the current
    /// desktop, wrapping.
    func cycle(_ delta: Int) {
        peek?.cancel(); peek = nil
        if !isOpen { present(pinned: false) }
        let ids = groups.map(\.id)
        guard !ids.isEmpty else { return }
        let from = ids.firstIndex(of: selected ?? Engine.shared.currentID) ?? 0
        selected = ids[((from + delta) % ids.count + ids.count) % ids.count]
    }

    /// ⌘⌥ released (or broken): commit a ⌘⌥⇥ selection, otherwise end the peek.
    func released() {
        if let s = selected { jump(to: s) } else { dismissPeek() }
    }

    /// Any other key under ⌘⌥ is a chord (⌘⌥I, ⌘⌥esc, …): drop the selection, end the peek.
    func chord() {
        selected = nil
        dismissPeek()
    }

    /// Cancel a pending peek, hide a held (non-pinned) overlay. A rename or drag in progress
    /// keeps it up — letting go of the modifiers to type, or mid-drag, must not close the
    /// overlay out from under you; `settle()` honours the release once it ends.
    private func dismissPeek() {
        peek?.cancel(); peek = nil
        if isOpen, !pinned, renamingID == nil, drag == nil { hide() }
    }

    func toggle() {
        if isOpen { hide() } else { present(pinned: true) }
    }

    func hide() {
        peek?.cancel(); peek = nil
        panel?.orderOut(nil)
        panel = nil
        pinned = false
        renamingID = nil
        drag = nil
        selected = nil
        Captures.shared.stopIfIdle()
    }

    func refresh() {
        guard isOpen else { return }
        groups = Engine.shared.view()
    }

    // actions from the view
    @Published var renamingID: UUID?

    func jump(to id: UUID) { Engine.shared.jump(to: id); hide() }
    func focus(_ w: Win) { Engine.shared.focusWindow(w.id); hide() }
    func newGroup() { Engine.shared.newGroup(); refresh() }
    func closeWindow(_ w: Win) { Engine.shared.closeWindow(w.id) }
    func killApp(_ w: Win) { Engine.shared.killApp(w.id) }
    func seed(_ id: UUID) { Engine.shared.seed(id) }
    func deleteGroup(_ id: UUID) { Engine.shared.deleteGroup(id); refresh() }
    func beginRename(_ id: UUID) { renamingID = id }

    func endRename() {
        renamingID = nil
        settle()
    }

    // Drag-to-move is tracked here, in-panel, not via system drag-and-drop: an AppKit drag
    // session reads held ⌘⌥ as "make alias" and the drop is refused — and ⌘⌥ is exactly
    // what's held while the overlay is peeked.
    enum Dragged {
        case window(Win), desktop(GroupView)
        var label: String {
            switch self {
            case .window(let w): w.title.isEmpty ? w.app : w.title
            case .desktop(let g): g.name
            }
        }
    }
    nonisolated static let space = "overlay"           // coordinate space of drag points + card frames
    @Published private(set) var drag: (item: Dragged, at: CGPoint)?
    var cardFrames: [UUID: CGRect] = [:]
    var dropTarget: UUID? {
        drag.flatMap { d in cardFrames.first { $0.value.contains(d.at) }?.key }
    }

    func dragMoved(_ item: Dragged, to p: CGPoint) { drag = (item, p) }

    func dragEnded() {
        if let item = drag?.item, let target = dropTarget {
            switch item {
            case .window(let w): Engine.shared.retag(w.id, to: target)
            case .desktop(let g): Engine.shared.reorder(g.id, before: target)
            }
        }
        drag = nil
        settle()
    }

    /// A rename/drag outlived the ⌘⌥ release: close now unless the keys are back down or
    /// the panel was pinned open.
    private func settle() {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .isSuperset(of: [.maskCommand, .maskAlternate])
        if !pinned, !held { hide() } else { refresh() }
    }

    func liveRename(_ id: UUID, _ name: String) {
        Engine.shared.rename(id, to: name)
        refresh()
    }

    private func present(pinned: Bool) {
        self.pinned = pinned
        groups = Engine.shared.view()
        let p = panel ?? Self.makePanel()
        panel = p
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        p.setFrame(screen.frame, display: true)
        p.orderFrontRegardless()
        Captures.shared.start()
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: OverlayView().environmentObject(Overlay.shared))
        return p
    }
}

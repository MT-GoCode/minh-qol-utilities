import AppKit

// One CGEvent tap. Every gesture is harmless — none ever moves a window:
//   hold ⌘⌥       → overlay of all desktops in spaced views; release hides.
//   ⌘⌥ + ⇥/⇧⇥     → cycle a desktop cursor in that overlay; releasing ⌘⌥ jumps there.
//   ⌘⌥ + 1…9      → jump straight to desktop N (passed through if there is no desktop N).
//   ⌘⇥            → in-group switcher. Hold ⌘, ⇥/⇧⇥/arrows to pick, release ⌘ commits,
//                   esc cancels. (Replaces native ⌘⇥, scoped to the current group.)
//
// Discipline (MSV's root bug, avoided): the callback CLASSIFIES + CONSUMES only; every
// action dispatches out — never AX inside the tap. Dispatching ALL of them (modifier
// changes included) to the one main queue also keeps them in key order: a release can't
// overtake the ⇥ that preceded it. The switcher commits ONLY on the ⌘ key's own release
// (keycode 54/55 in flagsChanged); other cmd-less events mid-hold (e.g. Karabiner remaps)
// must not be read as a release. KeyUp debts are counters with a TTL so a lost keyUp can't
// poison later keystrokes.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var tap: CFMachPort?
    private var owedKeyUps: [Int64: (count: Int, at: Date)] = [:]
    private var lastCreateAttempt = Date.distantPast
    private var disabledStrikes = 0
    private var cycling = false     // a ⌘⌥⇥ was seen this hold — its overlay may still be queued

    /// tap exists AND passed its last health check — so the menu ⚠ shows for a
    /// created-then-dead tap (Accessibility revoked, port death), not just a never-created one.
    var alive: Bool { tap != nil && disabledStrikes == 0 }

    /// The 1s watchdog: create a missing tap, detect and recreate a dead one. Two consecutive
    /// disabled observations before recreating — right after tapDisabledByTimeout there's a
    /// window where the in-callback re-enable hasn't run yet; one sample there would tear down
    /// a tap about to self-heal. Create attempts (and their failure logs) throttle to 1/5s.
    func ensureAlive() {
        guard let tap else { throttledStart(); return }
        let valid = CFMachPortIsValid(tap)
        let enabled = valid && CGEvent.tapIsEnabled(tap: tap)
        if valid && enabled { disabledStrikes = 0; return }
        disabledStrikes += 1
        guard !valid || disabledStrikes >= 2 else { return }
        NSLog("multistreamviewer: event tap dead (valid=%d enabled=%d) — recreating",
              valid ? 1 : 0, enabled ? 1 : 0)
        CFMachPortInvalidate(tap)
        self.tap = nil
        disabledStrikes = 0
        if !Switcher.shared.isOpen { Switcher.karabinerVar(0) }   // never leave the gate stuck
        throttledStart()
    }

    private func throttledStart() {
        guard Date().timeIntervalSince(lastCreateAttempt) >= 5 else { return }
        lastCreateAttempt = Date()
        start()
    }

    /// Idempotent: safe to retry after the user grants Accessibility (tap creation fails
    /// silently without it, and there's no notification when it's granted).
    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Hotkeys.callback(type: type, event: event) },
            userInfo: nil)
        guard let tap else {
            NSLog("multistreamviewer: event tap failed — grant Accessibility and relaunch")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Auto-repeats get no keyUp of their own, so they owe nothing.
    private func consume(_ e: CGEvent) {
        guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        owedKeyUps[code] = ((owedKeyUps[code]?.count ?? 0) + 1, Date())
    }

    private func settleKeyUp(_ code: Int64) -> Bool {
        guard var debt = owedKeyUps[code] else { return false }
        if Date().timeIntervalSince(debt.at) > 2 { owedKeyUps.removeValue(forKey: code); return false }
        debt.count -= 1
        if debt.count <= 0 { owedKeyUps.removeValue(forKey: code) } else { owedKeyUps[code] = debt }
        return true
    }

    private nonisolated static func callback(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated { Hotkeys.shared.handle(type: type, event: event) }
    }

    private func pass(_ e: CGEvent) -> Unmanaged<CGEvent> { Unmanaged.passUnretained(e) }

    /// ANSI keycodes of the top-row 1…9 (not sequential — the layout's history).
    private static let digitCodes: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass(event)
        }
        let s = Switcher.shared
        let f = event.flags
        let cmd = f.contains(.maskCommand)
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        let opt = f.contains(.maskAlternate)
        let ctrl = f.contains(.maskControl)
        let shift = f.contains(.maskShift)

        if type == .flagsChanged {
            if !(cmd && opt) { cycling = false }
            DispatchQueue.main.async {
                if s.isOpen, !cmd, code == 54 || code == 55 { s.commit() }   // ⌘ released → commit
                // hold ⌘⌥ (nothing else) → overlay of all desktops; release/break → hide (or
                // commit a ⌘⌥⇥ selection). ⇧ is allowed once it's up: it's ⌘⌥⇧⇥'s reverse.
                let o = Overlay.shared
                if cmd, opt, !ctrl, !shift || o.isOpen, !s.isOpen {
                    o.scheduleHeld()
                } else {
                    o.released()
                }
            }
            return pass(event)
        }
        if type == .keyUp {
            return settleKeyUp(code) ? nil : pass(event)
        }
        guard type == .keyDown else { return pass(event) }

        // ⌘⌥ layer: desktop cursor and direct jumps; any other key is a chord (⌘⌥I, ⌘⌥esc, …).
        if cmd, opt, !s.isOpen {
            if !ctrl, code == 48 {                // tab
                consume(event)
                cycling = true
                DispatchQueue.main.async { Overlay.shared.cycle(shift ? -1 : 1) }
                return nil
            }
            let groups = Engine.shared.groups
            if !ctrl, !shift, let n = Self.digitCodes[code], groups.indices.contains(n - 1) {
                let first = event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                consume(event)
                let id = groups[n - 1].id
                if first { DispatchQueue.main.async { Overlay.shared.jump(to: id) } }
                return nil
            }
            DispatchQueue.main.async { Overlay.shared.chord() }
            // esc as the overview's cancel is swallowed: passed through, ⌘⌥⎋ opens Force Quit.
            if code == 53, cycling || Overlay.shared.isOpen { consume(event); return nil }
        }

        // ⌘ layer: the switcher.
        if cmd, !opt, !ctrl {
            if code == 48 {                       // tab
                consume(event)
                DispatchQueue.main.async {
                    s.isOpen ? s.step(shift ? -1 : 1) : s.open()
                }
                return nil
            }
            if s.isOpen {
                switch code {
                case 123: consume(event); DispatchQueue.main.async { s.arrow(-1, 0) }; return nil
                case 124: consume(event); DispatchQueue.main.async { s.arrow(1, 0) }; return nil
                case 125: consume(event); DispatchQueue.main.async { s.arrow(0, 1) }; return nil
                case 126: consume(event); DispatchQueue.main.async { s.arrow(0, -1) }; return nil
                case 53: consume(event); DispatchQueue.main.async { s.cancel() }; return nil  // esc
                default: break
                }
            }
        }
        // esc cancels regardless of modifiers, so a dropped ⌘ can't trap the HUD.
        if s.isOpen, code == 53 {
            consume(event)
            DispatchQueue.main.async { s.cancel() }
            return nil
        }
        return pass(event)
    }
}

import AppKit
import Foundation
import TECore
import TEUI
import XCTest
import os

final class FakeTime: @unchecked Sendable {
    private struct S { var current: Date; var deadlines: [Date] = []; var waiters: [(Date, CheckedContinuation<Void, Error>)] = [] }
    let base: Date
    private let s: OSAllocatedUnfairLock<S>
    init(base: Date) {
        self.base = base
        s = OSAllocatedUnfairLock(initialState: S(current: base))
    }
    var current: Date { s.withLock { $0.current } }
    var deadlines: [Date] { s.withLock { $0.deadlines } }
    var time: OverlayTime { OverlayTime(now: { self.current }, sleep: { try await self.sleep(until: $0) }) }
    func sleep(until d: Date) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let ready = s.withLock { state -> Bool in
                state.deadlines.append(d)
                if d <= state.current { return true }
                state.waiters.append((d, c))
                return false
            }
            if ready { c.resume() }
        }
    }
    func advance(by seconds: Double) {
        let due = s.withLock { state -> [CheckedContinuation<Void, Error>] in
            state.current += seconds
            let now = state.current
            let due = state.waiters.filter { $0.0 <= now }.map(\.1)
            state.waiters.removeAll { $0.0 <= now }
            return due
        }
        due.forEach { $0.resume() }
    }
}

@MainActor final class OverlayRig {
    let time = FakeTime(base: Date(timeIntervalSince1970: 1_800_000_000))  // 2027-01-15 08:00:00Z
    let config: ConfigStore, store: TranscriptStore
    var attached: Set<SourceID> = [], failures: [String] = []
    let autosaveName = UUID().uuidString
    private(set) var overlay: Overlay!
    init(_ test: XCTestCase, config: ConfigStore = ConfigStore()) throws {
        _ = NSApplication.shared
        self.config = config
        store = try TranscriptStore(paths: Paths(root: temporaryRoot(test)), start: time.base)
        overlay = Overlay(config: config, attached: { [unowned self] in attached }, failures: { [unowned self] in failures }, autosaveName: autosaveName, time: time.time)
        overlay.bind(store)
        let panel = overlay.panel
        let key = "NSWindow Frame \(autosaveName)"
        test.addTeardownBlock { @MainActor in
            panel.close()
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    func say(_ src: String, _ text: String, tag: String = "Zoom", spk: Int = 1) async throws {
        let id = SourceID(rawValue: src)
        try await store.commit([Line(t: time.current, src: id, tag: tag, spk: spk, text: text, start: 0, end: 0)], of: id)
    }
}

func find<T: NSView>(_ id: String, in v: NSView) -> T {
    func walk(_ v: NSView) -> T? {
        if v.identifier?.rawValue == id, let t = v as? T { return t }
        for s in v.subviews { if let t = walk(s) { return t } }
        return nil
    }
    return walk(v)!
}

private func mouse(_ type: NSEvent.EventType, _ panel: NSPanel, _ p: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
/// The mouse-up is queued first because a control's tracking loop blocks until it arrives.
@MainActor func click(_ panel: NSPanel, atWindowPoint p: NSPoint) {
    NSApp.postEvent(mouse(.leftMouseUp, panel, p), atStart: false)
    panel.sendEvent(mouse(.leftMouseDown, panel, p))
}

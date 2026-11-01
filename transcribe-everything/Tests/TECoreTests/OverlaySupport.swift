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
    var attached: Set<SourceID> = []
    private(set) var overlay: Overlay!
    init(_ test: XCTestCase, config: ConfigStore = ConfigStore()) throws {
        _ = NSApplication.shared
        self.config = config
        store = try TranscriptStore(paths: Paths(root: temporaryRoot(test)), start: time.base)
        overlay = Overlay(config: config, attached: { [unowned self] in attached }, time: time.time)
        overlay.bind(store)
        let panel = overlay.panel
        test.addTeardownBlock { @MainActor in panel.close() }
    }
    func say(_ src: String, _ text: String, tag: String = "Zoom", spk: Int = 1) async throws {
        let id = SourceID(rawValue: src)
        try await store.commit([Line(t: time.current, src: id, tag: tag, spk: spk, text: text, start: 0, end: 0)], of: id)
    }
}

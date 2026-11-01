import AppKit
import Foundation
import TECore
import TEUI
import XCTest

actor Gate {
    private var open = false, waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor final class FakePermissions: Permissions {
    var have: Set<Permission>
    let grantsOnRequest: Set<Permission>
    private(set) var requested: [Permission] = []
    init(have: Set<Permission>, grantsOnRequest: Set<Permission>) {
        self.have = have
        self.grantsOnRequest = grantsOnRequest
    }
    func granted(_ p: Permission) -> Bool { have.contains(p) }
    func request(_ p: Permission) async {
        requested.append(p)
        if grantsOnRequest.contains(p) { have.insert(p) }
    }
}

/// Shared by the rig's closures, which are built before the session exists.
@MainActor final class Counters {
    var loads = 0, loadFailures = 0, terminated = false
    var made: [SourceID: Int] = [:], gone: Set<SourceID> = [], provide: [SourceID: any TECore.AudioSource] = [:]
}

@MainActor final class FakeWindows {
    var list: [WindowCatalog.Window] = []
    var fetches = 0
}

/// Reads the drawn image, sharing nothing with `MenuBar`.
func dotColor(_ image: NSImage) -> String {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
    NSGraphicsContext.restoreGraphicsState()
    let c = rep.colorAt(x: 8, y: 8)!.usingColorSpace(.sRGB)!
    let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
    if r > 0.9, g > 0.7, g < 0.95, b < 0.2 { return "yellow" }
    if r < 0.4, g > 0.7, b > 0.2, b < 0.5 { return "green" }
    if abs(r - g) < 0.06, abs(g - b) < 0.06, g > 0.3, g < 0.7 { return "grey" }
    return "other(\(r),\(g),\(b))"
}

@MainActor final class Rig {
    let root: URL, c = Counters(), permissions: FakePermissions, config = ConfigStore()
    private(set) var session: Session!, bar: MenuBar!, catalog: WindowCatalog!
    let windows = FakeWindows()
    var history: [String] = []  // "<state>/<dot colour>" after each change that alters it

    init(_ test: XCTestCase, have: Set<Permission> = Set(Permission.allCases), grants: Set<Permission> = [], gate: Gate? = nil, loadFailures: Int = 0, every: TimeInterval = 3600, settings: [NSMenuItem] = []) {
        root = temporaryRoot(test)
        permissions = FakePermissions(have: have, grantsOnRequest: grants)
        c.loadFailures = loadFailures
        let c = self.c
        session = Session(paths: Paths(root: root), permissions: permissions, config: config, loader: {
            c.loads += 1
            await gate?.wait()
            if c.loadFailures > 0 {
                c.loadFailures -= 1
                throw Boom(description: "model download failed")
            }
            return CoreModels(transcriber: try await Models.transcriber.value, embedder: try await Models.embedder.value, vad: try await Models.vad.value)
        }, makeSource: { t in
            c.made[t.id, default: 0] += 1
            if c.gone.contains(t.id) { throw Boom(description: "not running") }
            if let s = c.provide[t.id] { return s }
            return try FileSource(url: Fixtures.conversationWav, id: t.id, tag: t.tag, clock: ContinuousClock())  // 99 s real time: it cannot end inside a test
        }, onStart: { _ in }, terminate: { c.terminated = true })
        catalog = WindowCatalog(permissions: permissions, every: every) { [windows] in
            windows.fetches += 1
            return windows.list
        }
        bar = MenuBar(session: session, catalog: catalog, settings: settings)
        session.observe { [unowned self] in
            let now = self.label + "/" + self.dot
            if self.history.last != now { self.history.append(now) }
        }
    }

    private var label: String {
        switch session.state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .failed: "failed"
        }
    }
    func submenu() -> NSMenu { bar.item.menu!.item(withTitle: "Attach to Apps")!.submenu! }
    func click(_ title: String) {
        let menu = bar.item.menu!, i = menu.indexOfItem(withTitle: title)
        XCTAssertNotEqual(i, -1, title)
        menu.performActionForItem(at: i)
    }
    var dot: String { dotColor(bar.item.button!.image!) }
    var status: String { bar.item.menu!.item(at: 0)!.title }
    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths(root: root).transcripts.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
    }
    func tail(_ id: SourceID) async -> Bool {
        guard let core = session.core else { return false }
        return await core.store.snapshot().tails.contains { $0.src == id }
    }
}

import AppKit
import TECore
import TEUI
import XCTest

@MainActor final class BarTests: XCTestCase {
    private let A = SourceID(rawValue: "A")
    private func view<T: NSView>(_ o: Overlay, _ id: String) -> T { find(id, in: o.panel.contentView!) }
    private func screenCentre(_ v: NSView, _ o: Overlay) -> NSPoint {
        let c = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return o.panel.convertPoint(toScreen: c)
    }
    private func tiff(_ symbol: String) -> Data? { NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.tiffRepresentation }
    /// What a relaunch does: the first window is gone and its saved frame stays. AppKit refuses a name a live window holds.
    private func second(_ rig: OverlayRig) -> Overlay {
        rig.overlay.panel.saveFrame(usingName: rig.autosaveName)
        rig.overlay.panel.setFrameAutosaveName("")
        let o = Overlay(config: ConfigStore(), attached: { [] }, autosaveName: rig.autosaveName)
        addTeardownBlock { @MainActor in o.panel.close() }
        return o
    }

    func testFrameRestoresFromTheAutosaveName() throws {
        let r = try OverlayRig(self), v = NSScreen.screens[0].visibleFrame
        r.overlay.panel.setFrameOrigin(NSPoint(x: v.minX + 123, y: v.minY + 321))
        let moved = r.overlay.panel.frame  // AppKit rounds the origin
        XCTAssertEqual(moved.minX, v.minX + 123, accuracy: 1)
        let o = second(r)
        XCTAssertEqual(o.panel.frame.minX, moved.minX)
        XCTAssertEqual(o.panel.frame.maxY, moved.maxY)
    }

    func testRestoredOffScreenFrameEndsOnARealScreen() throws {
        let r = try OverlayRig(self)
        r.overlay.panel.setFrameOrigin(NSPoint(x: 90000, y: 90000))
        XCTAssertEqual(r.overlay.panel.frame.minX, 90000, "the saved frame must really be off screen")
        let o = second(r)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(o.panel.frame) }, "\(o.panel.frame)")
    }

    func testGlyphsAndExpandShowsLinesOlderThanTwentySeconds() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        let grip: NSButton = view(o, "grip"), expand: NSButton = view(o, "expand")
        XCTAssertEqual(grip.attributedTitle.string, "\u{283F}")
        XCTAssertEqual(expand.attributedTitle.string, "\u{2303}")
        r.attached = [A]
        try await r.say("A", "Old line.")
        r.time.advance(by: 30)
        await o.refresh().value
        XCTAssertEqual(o.text.string, "")
        expand.performClick(nil)
        await o.refresh().value
        XCTAssertEqual(o.text.string, "Old line.")
        expand.performClick(nil)
        await o.refresh().value
        XCTAssertEqual(o.text.string, "")
    }

    func testEyeHidesCaptionsKeepsTheBarAndShareStateWithTheMenuItem() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        r.attached = [A]
        let eye: NSButton = view(o, "eye"), grip: NSButton = view(o, "grip"), expand: NSButton = view(o, "expand")
        try await r.say("A", "Hello there.")
        await o.refresh().value
        XCTAssertFalse(o.captionsHidden)
        XCTAssertEqual(eye.image?.tiffRepresentation, tiff("eye"))
        XCTAssertEqual(o.hideShowItem.title, "Hide")
        eye.performClick(nil)
        await o.refresh().value
        XCTAssertTrue(o.captionsHidden)
        XCTAssertEqual(o.panel.frame.height, 28)
        for c in [grip, expand, eye] {
            XCTAssertFalse(c.isHidden)
            XCTAssertNotNil(c.window)
        }
        XCTAssertEqual(eye.image?.tiffRepresentation, tiff("eye.slash"))
        XCTAssertEqual(o.hideShowItem.title, "Show")
        o.pollMouse(at: screenCentre(eye, o), pressed: 0)
        XCTAssertFalse(o.panel.ignoresMouseEvents)
        try await r.say("A", "Later line.")
        await o.refresh().value
        XCTAssertEqual(o.text.string, "Hello there.", "no draw while hidden")
        NSApp.sendAction(o.hideShowItem.action!, to: o.hideShowItem.target, from: o.hideShowItem)
        await o.refresh().value
        XCTAssertFalse(o.captionsHidden)
        XCTAssertEqual(o.text.string, "Hello there.\nLater line.")
        XCTAssertEqual(eye.image?.tiffRepresentation, tiff("eye"))
        XCTAssertEqual(o.hideShowItem.title, "Hide")
        XCTAssertGreaterThan(o.panel.frame.height, 28)
        NSApp.sendAction(o.hideShowItem.action!, to: o.hideShowItem.target, from: o.hideShowItem)
        XCTAssertTrue(o.captionsHidden)
        eye.performClick(nil)
        XCTAssertFalse(o.captionsHidden, "the eye and the menu item share one state")
    }

    func testFailureReasonShowsInTheBarEvenWhileHiddenUntilCleared() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        let note: NSTextField = view(o, "failure")
        r.failures = ["Zoom: no audio buffers for more than 1 second"]
        await o.refresh().value
        XCTAssertEqual(note.stringValue, r.failures[0])
        XCTAssertFalse(note.isHidden)
        let centre = screenCentre(note, o)
        o.pollMouse(at: centre, pressed: 0)
        XCTAssertFalse(o.panel.ignoresMouseEvents)
        o.toggleCaptions()
        r.failures = ["Zoom: no audio buffers for more than 1 second", "Mic: gone"]
        await o.refresh().value
        XCTAssertEqual(note.stringValue, "Zoom: no audio buffers for more than 1 second  Mic: gone")
        r.failures = []
        await o.refresh().value
        XCTAssertEqual(note.stringValue, "")
        XCTAssertTrue(note.isHidden)
        o.pollMouse(at: centre, pressed: 0)
        XCTAssertTrue(o.panel.ignoresMouseEvents)
    }

    func testAMinuteOfLinesAtFontFortyEightIsAllReachable() async throws {
        var c = Config()
        c.fontSize = 48
        let r = try OverlayRig(self, config: ConfigStore(c)), o = r.overlay!
        r.attached = [A]
        for k in 1...14 {
            try await r.say("A", "Line \(k).")
            r.time.advance(by: 4)
        }
        let expand: NSButton = view(o, "expand")
        expand.performClick(nil)
        await o.refresh().value
        XCTAssertGreaterThan(o.text.frame.height, o.scroll.frame.height, "the content must overflow")
        let lm = o.text.layoutManager!
        o.text.scroll(.zero)
        XCTAssertTrue(o.text.visibleRect.contains(lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).insetBy(dx: 1, dy: 1)))
        o.text.scroll(NSPoint(x: 0, y: o.text.frame.height - o.scroll.contentView.bounds.height))
        XCTAssertTrue(o.text.visibleRect.contains(lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil).insetBy(dx: 1, dy: 1)))
    }

    func testBarClickNeverTakesTheKeyboardButTextClickDoes() async throws {
        try XCTSkipIf(AppHarness.screenLocked, "screen locked: a synthesized click reaches no control there")
        let r = try OverlayRig(self), o = r.overlay!
        r.attached = [A]
        try await r.say("A", "Old line.")
        r.time.advance(by: 30)
        await o.refresh().value
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let expand: NSButton = view(o, "expand")
        click(o.panel, atWindowPoint: expand.convert(NSPoint(x: expand.bounds.midX, y: expand.bounds.midY), to: nil))
        await o.refresh().value
        XCTAssertEqual(o.text.string, "Old line.", "the action fired through the real dispatch")
        XCTAssertFalse(o.panel.isKeyWindow)
        let used = o.text.layoutManager!.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        click(o.panel, atWindowPoint: o.text.convert(NSPoint(x: used.midX, y: used.midY), to: nil))
        XCTAssertTrue(o.panel.isKeyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
}

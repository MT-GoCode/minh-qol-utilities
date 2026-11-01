import AppKit
import TECore
import TEUI
import XCTest

@MainActor final class SelectionTests: XCTestCase {
    private let three = "Hello there.\nSecond line.\nThird line."

    func testCopyWritesExactlyTheSelectionAndCommandCIsWiredToTheResponderChain() async throws {
        let r = try OverlayRig(self), t = r.overlay.text
        try await r.seed()
        r.selectThere()
        let pb = NSPasteboard(name: .init("te-sel-" + UUID().uuidString))
        addTeardownBlock { @MainActor in pb.releaseGlobally() }
        XCTAssertTrue(t.writeSelection(to: pb, types: t.writablePasteboardTypes))
        XCTAssertEqual(pb.string(forType: .string), "there")
        let items = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Copy")
        XCTAssertEqual(items[0].action, #selector(NSText.copy(_:)))
        XCTAssertEqual(items[0].keyEquivalent, "c")
        XCTAssertEqual(items[0].keyEquivalentModifierMask, .command)
        XCTAssertNil(items[0].target)
    }

    private func heldRig() async throws -> OverlayRig {
        let r = try OverlayRig(self)
        try await r.seed()
        r.selectThere()
        try await r.say("A", "Third line.")
        await r.overlay.refresh().value
        try await sleepSeconds(0.3)  // a redraw still queued from `say` would otherwise catch up by itself and hide a missing release path
        return r
    }

    func testDataArrivingWhileSelectedLeavesSelectionAndTextUnchanged() async throws {
        let r = try await heldRig(), t = r.overlay.text
        XCTAssertEqual(t.string, "Hello there.\nSecond line.")
        XCTAssertEqual(t.selectedRange(), (t.string as NSString).range(of: "there"))
    }

    func testDeselectCatchesUpWithoutAnyOtherEvent() async throws {
        let r = try await heldRig(), t = r.overlay.text
        t.setSelectedRange(NSRange(location: 0, length: 0))
        try await eventually("catch-up") { t.string == self.three }
    }

    func testResignKeyClearsTheSelectionAndShowsTheLatestLines() async throws {
        let r = try await heldRig(), t = r.overlay.text
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: r.overlay.panel)
        XCTAssertEqual(t.selectedRange().length, 0)
        try await eventually("latest") { t.string == self.three }
    }

    func testUserActionsEndTheSelectionAndAreNeverHeld() async throws {
        let r = try await heldRig(), o = r.overlay!
        o.toggleCaptions()
        XCTAssertEqual(o.text.selectedRange().length, 0)
        try await eventually("hidden") { o.panel.frame.height == 28 }
        o.toggleCaptions()
        try await eventually("shown") { o.text.string == self.three }
    }

    func testSelectedTextCannotBeDraggedOut() async throws {
        let r = try OverlayRig(self), o = r.overlay!, t = o.text
        try await r.seed()
        r.selectThere()
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: o.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertFalse(t.dragSelection(with: event, offset: .zero, slideBack: false))
        try XCTSkipIf(AppHarness.screenLocked, "screen locked: a real drag needs the unlocked Mac")
        NSPasteboard(name: .drag).clearContents()
        let lm = t.layoutManager!, word = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: t.selectedRange(), actualCharacterRange: nil), in: t.textContainer!)
        let from = t.convert(NSPoint(x: word.midX, y: word.midY), to: nil)
        drag(o.panel, from: from, to: NSPoint(x: from.x + 40, y: from.y))
        XCTAssertNil(NSPasteboard(name: .drag).string(forType: .string))
    }

    func testRealDragSelectsOnTheFirstClickAndHoldsUntilResign() async throws {
        try XCTSkipIf(AppHarness.screenLocked, "screen locked: a real drag needs the unlocked Mac")
        let r = try OverlayRig(self), o = r.overlay!, t = o.text
        try await r.seed()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fragment = t.layoutManager!.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        let p1 = t.convert(NSPoint(x: fragment.minX + 6, y: fragment.midY), to: nil)
        drag(o.panel, from: p1, to: NSPoint(x: p1.x + 100, y: p1.y))
        XCTAssertGreaterThan(t.selectedRange().length, 0)
        XCTAssertTrue("Hello there.".hasPrefix((t.string as NSString).substring(with: t.selectedRange())))
        XCTAssertTrue(o.panel.isKeyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
        try await r.say("A", "Third line.")
        await o.refresh().value
        XCTAssertEqual(t.string, "Hello there.\nSecond line.")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: o.panel)
        try await eventually("latest") { t.string == self.three }
    }
}

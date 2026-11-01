import AppKit
import ImageIO
import TECore
import TEUI
import Vision
import XCTest

@MainActor final class OverlayTests: XCTestCase {
    private let A = SourceID(rawValue: "A"), B = SourceID(rawValue: "B"), C = SourceID(rawValue: "C")

    private func overflowing() async throws -> OverlayRig {
        var c = Config()
        c.fontSize = 48
        let rig = try OverlayRig(self, config: ConfigStore(c))
        rig.attached = [A, B, C]
        for k in 1...12 { try await rig.say(["A", "B", "C"][k % 3], "Line \(k) from \(["A", "B", "C"][k % 3]).") }
        await rig.overlay.refresh().value
        return rig
    }
    private func lastLineVisible(_ o: Overlay) -> Bool {
        let lm = o.text.layoutManager!
        return o.text.visibleRect.contains(lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil).insetBy(dx: 1, dy: 1))
    }

    func testCaptionsAppearAsRenderedAndLeaveDuringSilence() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        r.attached = [A]
        try await r.say("A", "Hello there.")
        try await eventually("subscription") { o.text.string == "Hello there." }
        r.time.advance(by: 3)
        try await r.say("A", "Second line.")
        await o.refresh().value
        XCTAssertEqual(o.text.string, "Hello there.\nSecond line.")
        r.attached = [A, B]
        await o.refresh().value
        XCTAssertEqual(o.text.string, "[Zoom] Hello there.\n[Zoom] Second line.")
        r.time.advance(by: 17)
        await o.refresh().value
        XCTAssertEqual(o.text.string, "[Zoom] Hello there.\n[Zoom] Second line.", "the edge is inclusive")
        r.time.advance(by: 1)
        try await eventually("expiry") { o.text.string == "[Zoom] Second line." }
        r.time.advance(by: 3)
        try await eventually("all expired") { o.text.string == "" }
        XCTAssertEqual(o.panel.frame.height, 28)
    }

    func testWakeIsAfterTheEdgeNeverAtIt() async throws {
        let r = try OverlayRig(self)
        try await r.say("A", "One.")
        await r.overlay.refresh().value
        let edge = r.time.base.addingTimeInterval(20)
        XCTAssertFalse(r.time.deadlines.isEmpty)
        XCTAssertTrue(r.time.deadlines.allSatisfy { $0 > edge }, "\(r.time.deadlines)")
    }

    func testProvisionalTailShowsLastAndACommitReplacesItAtomically() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        r.attached = [A]
        try await r.say("A", "First.")
        await r.store.setTail(Provisional(src: A, tag: "Zoom", spk: 1, text: "and then"), epoch: await r.store.epoch(of: A))
        await o.refresh().value
        XCTAssertEqual(o.text.string, "First.\nand then")
        try await r.say("A", "And then we left.")
        await o.refresh().value
        XCTAssertEqual(o.text.string, "First.\nAnd then we left.")
    }

    func testOverflowKeepsTheNewestLineVisibleAtFontFortyEight() async throws {
        let r = try await overflowing(), o = r.overlay!
        XCTAssertGreaterThan(o.text.frame.height, o.scroll.frame.height, "the content must overflow")
        XCTAssertLessThanOrEqual(o.panel.frame.height, 28 + 0.4 * NSScreen.screens[0].visibleFrame.height + 0.5)
        XCTAssertTrue(lastLineVisible(o))
    }

    func testScrolledUpHoldsTheViewAndFollowingResumesAtTheBottom() async throws {
        let r = try await overflowing(), o = r.overlay!
        o.text.scroll(.zero)
        try await r.say("A", "Line 13 from A.")
        await o.refresh().value
        XCTAssertEqual(o.scroll.contentView.bounds.origin.y, 0, accuracy: 1)  // AppKit rounds on a fractional height
        XCTAssertTrue(o.text.string.hasSuffix("Line 13 from A."))
        o.text.scroll(NSPoint(x: 0, y: o.text.frame.height - o.scroll.contentView.bounds.height))
        try await r.say("B", "Line 14 from B.")
        await o.refresh().value
        XCTAssertTrue(lastLineVisible(o))
    }

    func testClickThroughFollowsTheMouseAndFreezesWhileAButtonIsDown() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        r.attached = [A]
        try await r.say("A", "Hello there.")
        await o.refresh().value
        let lm = o.text.layoutManager!, used = lm.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertLessThan(used.width, 756, "`away` must be blank")
        let over = o.panel.convertPoint(toScreen: o.text.convert(NSPoint(x: used.midX, y: used.midY), to: nil))
        let away = NSPoint(x: o.panel.frame.maxX - 2, y: over.y)
        o.pollMouse(at: away, pressed: 0)
        XCTAssertTrue(o.panel.ignoresMouseEvents)
        o.pollMouse(at: over, pressed: 0)
        XCTAssertFalse(o.panel.ignoresMouseEvents)
        o.pollMouse(at: away, pressed: 1)
        XCTAssertFalse(o.panel.ignoresMouseEvents, "frozen while a button is down")
        o.pollMouse(at: away, pressed: 0)
        XCTAssertTrue(o.panel.ignoresMouseEvents)
        o.pollMouse(at: over, pressed: 1)
        XCTAssertTrue(o.panel.ignoresMouseEvents, "frozen while a button is down")
    }

    func testAConfigChangeRedrawsWithoutAnyRefreshCall() async throws {
        let r = try OverlayRig(self), o = r.overlay!
        r.attached = [A]
        try await r.say("A", "Hello there.")
        await o.refresh().value
        func size() -> CGFloat? { (o.text.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize }
        XCTAssertEqual(size(), 22)
        try await sleepSeconds(0.3)  // a redraw still queued from `say` would otherwise pick up the new font and hide a missing subscription
        var c = Config()
        c.fontSize = 31
        try await r.config.set(c)
        try await eventually("font") { size() == 31 }
    }

    func testWindowCaptureIsTransparentAndOCRReadsTheLatestLine() async throws {
        executionTimeAllowance = 240
        try AppHarness.displayAwake.get()
        let root = temporaryRoot(self), png = resultsDir().appending(path: "overlay.png")
        let report = try await Task.detached { [png] in
            try AppHarness.run(root: root, steps: [["op": "overlay", "lines": ["Good morning everyone.", "The quick brown fox jumps over the lazy dog."], "png": png.path]])
        }.value
        let result = (report["results"] as! [[String: Any]])[0]
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL, nil)!, 0, nil)!
        let scale = Double(image.width) / (result["pointsWidth"] as! Double), w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func alpha(_ px: Int, _ py: Int) -> UInt8 { bytes[(py * w + px) * 4 + 3] }
        let right = w - Int(4 * scale)
        XCTAssertEqual(alpha(right, Int(14 * scale)), 0, "the bar is see-through")
        XCTAssertEqual(alpha(right, Int(38 * scale)), 0, "right of the first line is see-through")
        XCTAssertEqual(stride(from: Int(28 * scale), to: h, by: 1).map { y in (0..<w).map { alpha($0, y) }.max()! }.max(), 255, "the text is opaque")

        let black = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        black.setFillColor(.black)
        black.fill(CGRect(x: 0, y: 0, width: w, height: h))
        black.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: black.makeImage()!).perform([request])
        let read = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(normalize(read).joined(separator: " ").contains(normalize("The quick brown fox jumps over the lazy dog.").joined(separator: " ")), read)
    }
}

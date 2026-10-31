import AppKit
import EVPCore

/// The progress strip above the buttons: shows how far the video has played, seeks on click and drag, and shows the
/// time under the pointer in the lane above the track (inside the bar, never over the video).
final class ScrubBar: NSView {
    var fraction = 0.0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }
    var duration = 0.0
    var onSeek: ((Double) -> Void)?
    /// The pointer moved over the strip: the fraction under it and the screen point at the top of the strip there.
    /// nil when it leaves.
    var onHover: (((fraction: Double, top: NSPoint)?) -> Void)?

    private static let trackY: CGFloat = 6
    private static let trackHeight: CGFloat = 4
    private var hoverX: CGFloat? {
        didSet { needsDisplay = true }
    }
    private var hoverText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("scrub")
        setAccessibilityLabel("Progress")
    }

    required init?(coder: NSCoder) { fatalError("ScrubBar is created in code") }

    // A slider to accessibility: its value is the fraction played, and setting it seeks.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { fraction }
    override func setAccessibilityValue(_ value: Any?) {
        if let number = value as? NSNumber { onSeek?(min(max(number.doubleValue, 0), 1)) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        hoverText = ""
        onHover?(nil)
    }
    override func mouseDown(with event: NSEvent) { hover(event); seek(event) }
    override func mouseDragged(with event: NSEvent) { hover(event); seek(event) }

    private func position(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

    private func hover(_ event: NSEvent) {
        let x = position(event)
        let fraction = ScrubMath.fraction(x: x, width: bounds.width)
        hoverX = x
        hoverText = ScrubMath.tooltip(fraction: fraction, duration: duration)
        if let window { onHover?((fraction, window.convertPoint(toScreen: convert(NSPoint(x: x, y: bounds.maxY), to: nil)))) }
    }

    private func seek(_ event: NSEvent) { onSeek?(ScrubMath.fraction(x: position(event), width: bounds.width)) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: Self.trackY, width: bounds.width, height: Self.trackHeight)
        NSColor(white: 1, alpha: 0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.controlAccentColor.setFill()
        let played = NSRect(x: 0, y: track.minY, width: track.width * min(max(fraction, 0), 1), height: Self.trackHeight)
        NSBezierPath(roundedRect: played, xRadius: 2, yRadius: 2).fill()

        guard let hoverX else { return }
        let text = NSAttributedString(string: hoverText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let box = NSRect(x: min(max(hoverX - size.width / 2 - 4, 0), bounds.width - size.width - 8), y: Self.trackY + 10,
                         width: size.width + 8, height: size.height + 2)
        NSColor(white: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1))
    }
}

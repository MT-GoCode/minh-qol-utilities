import AppKit

/// The progress strip above the buttons. Shows `fraction` (0 to 1) of the video; interaction arrives with the time field.
final class ScrubBar: NSView {
    var fraction = 0.0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
        NSColor(white: 1, alpha: 0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: track.width * min(max(fraction, 0), 1), height: 4), xRadius: 2, yRadius: 2).fill()
    }
}

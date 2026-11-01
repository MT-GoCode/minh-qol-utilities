import AppKit

/// The thumbnail above the progress strip while the pointer hovers it: a borderless child window that never takes a
/// click or the focus, shown only during the hover.
final class PreviewBubble {
    private static let width: CGFloat = 160
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 90), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let picture = NSImageView()

    init() {
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.backgroundColor = .black
        picture.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = picture
    }

    /// Shows `jpeg` centred above `top` (a screen point), kept inside `parent`.
    func show(_ jpeg: Data, above top: NSPoint, in parent: NSWindow) {
        guard let image = NSImage(data: jpeg), image.size.width > 0 else { return }
        picture.image = image
        let size = NSSize(width: Self.width, height: (Self.width * image.size.height / image.size.width).rounded())
        let x = min(max(top.x - size.width / 2, parent.frame.minX), parent.frame.maxX - size.width)
        // 20 pt up: the hover time sits in the lane just above the strip.
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: top.y + 20), size: size), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

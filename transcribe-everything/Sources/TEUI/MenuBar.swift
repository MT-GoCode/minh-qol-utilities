import AppKit

@MainActor public final class MenuBar {
    public let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let session: Session

    public init(session: Session) {
        self.session = session
        item.menu = NSMenu()
        session.observe { [weak self] in self?.render() }
        render()
    }
    deinit { NSStatusBar.system.removeStatusItem(item) }

    /// Rebuilt from the session on every change, so an open menu stays current.
    private func render() {
        let (color, status): (NSColor, String) = switch session.state {
        case .stopped: (.systemGray, "Stopped")
        case .starting: (.systemYellow, "Starting…")
        case .running: (.systemGreen, "Running")
        case .failed(let reason): (.systemGray, reason)
        }
        item.button!.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in  // 16 pt square, 10 pt dot: menu-bar glyph scale
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        let menu = item.menu!
        menu.removeAllItems()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")  // no action: a disabled label
        menu.addItem(Row("Start transcription") { [session] in session.start() })
        menu.addItem(Row("Stop transcription") { [session] in Task { await session.stop() } })
        menu.addItem(.separator())
        menu.addItem(Row("Quit") { [session] in Task { await session.quit() } })
    }
}

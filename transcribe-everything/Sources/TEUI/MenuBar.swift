import AppKit

@MainActor public final class MenuBar {
    public let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let session: Session, catalog: WindowCatalog, settings: [NSMenuItem]

    /// `settings` are items owned elsewhere (the overlay's Hide/Show, the font slider); they sit right after the Attach row.
    public init(session: Session, catalog: WindowCatalog, settings: [NSMenuItem]) {
        self.session = session
        self.catalog = catalog
        self.settings = settings
        item.menu = NSMenu()
        session.observe { [weak self] in self?.render() }
        catalog.onChange = { [weak self] in self?.render() }
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
        menu.addItem(toggleRow("Microphone", .mic))
        let host = NSMenuItem(title: "Attach to Apps", action: nil, keyEquivalent: "")
        host.submenu = appsMenu()
        menu.addItem(host)
        settings.forEach(menu.addItem)
        for reason in session.failures.values.sorted() + [session.deleteError].compactMap({ $0 }) { menu.addItem(withTitle: reason, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(Row("Delete old transcriptions") { [session] in session.deleteOld() })
        menu.addItem(.separator())
        menu.addItem(Row("Quit") { [session] in Task { await session.quit() } })
    }

    private func appsMenu() -> NSMenu {
        let m = NSMenu()
        for (i, group) in WindowCatalog.groups(catalog.windows).enumerated() {
            if i > 0 { m.addItem(.separator()) }
            for w in group { m.addItem(toggleRow(w.title, .app(bundleId: w.bundleId, tag: String(w.title.prefix(5))))) }
        }
        for case .app(let bundleId, let tag) in session.attached where !catalog.windows.contains(where: { $0.bundleId == bundleId }) {
            m.addItem(toggleRow(tag, .app(bundleId: bundleId, tag: tag)))  // no window left: still detachable
        }
        if let e = catalog.error { m.addItem(withTitle: e, action: nil, keyEquivalent: "") }
        if m.items.isEmpty { m.addItem(withTitle: "No windows", action: nil, keyEquivalent: "") }
        return m
    }

    private func toggleRow(_ title: String, _ target: Target) -> Row {
        Row(title, on: session.attached.contains { $0.id == target.id }) { [session] in Task { await session.toggle(target) } }
    }
}

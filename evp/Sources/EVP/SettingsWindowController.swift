import AppKit
import EVPCore

/// What the Settings window needs from the app beyond the stored settings.
protocol SettingsHost: AnyObject {
    /// The reliable media keys' state, as shown ("Active", "Needs Accessibility", ...).
    var tapStatus: String { get }
    func enableTap()
    /// A refusal to show, or nil to store the change. Called before the change is stored.
    func accept(from old: Settings, to new: Settings) -> String?
    /// Called after a change is stored.
    func settingsChanged(from old: Settings, to new: Settings)
    func holdGlobalHotkey(_ held: Bool)
}

/// Settings (Cmd+,) in three tabs: General, Keybinds, Global. Each change is checked (`Settings.problems()`, the
/// keymap's conflict rule, the host) and only then stored, so windows read it on their next event. A refused change
/// shows the reason and the controls go back to what is stored.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private final class NumberField: NSTextField {
        var keyPath: WritableKeyPath<Settings, Double>!
    }

    private final class Toggle: NSButton {
        var keyPath: WritableKeyPath<Settings, Bool>!
    }

    private static let size = NSSize(width: 560, height: 560)

    private let store: StateStore
    private weak var host: SettingsHost?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let tapLabel = NSTextField(labelWithString: "")
    private var numbers: [NumberField] = []
    private var toggles: [Toggle] = []
    private var recorders: [Action: KeyRecorderField] = [:]

    init(store: StateStore, host: SettingsHost) {
        self.store = store
        self.host = host
        // A panel never becomes the main window, so the menus keep acting on the video behind it.
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let tabs = NSTabView()
        for (title, content) in [("General", generalTab()), ("Keybinds", keybindsTab()), ("Global", globalTab())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = content
            tabs.addTabViewItem(item)
        }
        message.textColor = .systemRed
        message.setAccessibilityIdentifier("settings-message")
        let root = NSStackView(views: [tabs, message])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tabs.widthAnchor.constraint(equalToConstant: Self.size.width - 24).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: Self.size.height - 80).isActive = true
        window.contentView = root
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindowController is created in code") }

    /// Accessibility may have been granted in System Settings meanwhile.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    /// A recorder left waiting would keep the global hotkey off; leaving the window ends any recording.
    func windowDidResignKey(_ notification: Notification) { window?.makeFirstResponder(nil) }

    /// Ends any recording and gives the keyboard back to the video behind.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        message.stringValue = ""
        NSApp.orderedWindows.first { $0 is PlayerWindow && $0.isVisible }?.makeKey()
    }

    // MARK: Tabs

    private func generalTab() -> NSView {
        column([
            toggle("Keep the media keys (F7, F8, F9) out of EVP", id: "setting-decouple", \.decoupleMediaKeys),
            toggle("Reopen the windows of the last session at launch", id: "setting-restore", \.restoreWindowsOnLaunch),
            tapRow(),
            number("Short seek step (seconds)", id: "setting-seekShort", \.seekShortSeconds),
            number("Long seek step (seconds)", id: "setting-seekLong", \.seekLongSeconds),
            number("Speed step", id: "setting-speedStep", \.speedStep),
            number("Volume step", id: "setting-volumeStep", \.volumeStep),
            number("Speed of a file never opened before", id: "setting-defaultSpeed", \.defaultSpeed),
            number("Volume of a file never opened before", id: "setting-defaultVolume", \.defaultVolume),
        ])
    }

    private func keybindsTab() -> NSView {
        let reset = NSButton(title: "Reset all to defaults", target: self, action: #selector(resetAll))
        reset.setAccessibilityIdentifier("bind-reset-all")
        let list = column(Action.allCases.filter { !Action.global.contains($0) }.map(bindingRow))
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.size.width - 60),
            scroll.heightAnchor.constraint(equalToConstant: Self.size.height - 170),
        ])
        let tab = NSStackView(views: [reset, scroll])
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return tab
    }

    private func globalTab() -> NSView {
        let note = NSTextField(wrappingLabelWithString: "This key works while EVP is in the background. It needs Ctrl, Alt or Cmd.")
        return column([bindingRow(.pauseAll), note])
    }

    private func column(_ rows: [NSView]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return stack
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.spacing = 8
        return stack
    }

    private func toggle(_ title: String, id: String, _ keyPath: WritableKeyPath<Settings, Bool>) -> NSView {
        let box = Toggle(checkboxWithTitle: title, target: self, action: #selector(toggled(_:)))
        box.keyPath = keyPath
        box.setAccessibilityIdentifier(id)
        toggles.append(box)
        return box
    }

    private func number(_ title: String, id: String, _ keyPath: WritableKeyPath<Settings, Double>) -> NSView {
        let field = NumberField()
        field.keyPath = keyPath
        field.target = self
        field.action = #selector(numberEdited(_:))
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.setAccessibilityIdentifier(id)
        numbers.append(field)
        return row(title, field)
    }

    /// Reliable media keys need the Accessibility permission; this row shows where that stands and asks for it.
    private func tapRow() -> NSView {
        tapLabel.setAccessibilityIdentifier("setting-tap-status")
        let button = NSButton(title: "Enable…", target: self, action: #selector(enableReliableKeys))
        button.setAccessibilityIdentifier("setting-tap-enable")
        return row("Reliable media keys (needs Accessibility)", NSStackView(views: [tapLabel, button]))
    }

    private func bindingRow(_ action: Action) -> NSView {
        let recorder = KeyRecorderField()
        recorder.onChord = { [weak self] chord in self?.changeKeymap { try $0.bind(chord, to: action) } }
        recorder.onClear = { [weak self] in self?.changeKeymap { $0.unbind(action) } }
        if Action.global.contains(action) { recorder.onRecording = { [weak self] in self?.host?.holdGlobalHotkey($0) } }
        recorder.setAccessibilityIdentifier("bind-\(action.rawValue)")
        recorders[action] = recorder
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetOne(_:)))
        reset.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        reset.setAccessibilityIdentifier("bind-reset-\(action.rawValue)")
        return row(action.title, NSStackView(views: [recorder, reset]))
    }

    // MARK: Changes

    @objc private func enableReliableKeys() {
        host?.enableTap()
        refresh()
    }

    @objc private func toggled(_ sender: Toggle) {
        let on = sender.state == .on
        commit { $0[keyPath: sender.keyPath] = on }
    }

    @objc private func numberEdited(_ sender: NumberField) {
        guard let value = Double(sender.stringValue.trimmingCharacters(in: .whitespaces)) else {
            message.stringValue = "\"\(sender.stringValue)\" is not a number."
            return refresh()
        }
        commit { $0[keyPath: sender.keyPath] = value }
    }

    @objc private func resetOne(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = Action(rawValue: raw) else { return }
        changeKeymap { try $0.reset(action) }
    }

    /// Resets this tab's keys; the global key lives on the Global tab and keeps its chord.
    @objc private func resetAll() {
        changeKeymap { keymap in
            let global = keymap.chords[.pauseAll]
            keymap.resetAll()
            if let global { try keymap.bind(global, to: .pauseAll) } else { keymap.unbind(.pauseAll) }
        }
    }

    private func changeKeymap(_ edit: (inout Keymap) throws -> Void) {
        var keymap = store.state.settings.keymap
        do {
            try edit(&keymap)
        } catch let conflict as Keymap.Conflict {
            message.stringValue = "\(conflict.chord) is already used by \"\(conflict.existing.title)\". Unbind that one first."
            return refresh()
        } catch {
            message.stringValue = "\(error)"
            return refresh()
        }
        commit { $0.keymap = keymap }
    }

    /// Applies `change` to a copy of the settings and stores it when the settings and the host accept it.
    private func commit(_ change: (inout Settings) -> Void) {
        let old = store.state.settings
        var new = old
        change(&new)
        guard new != old else { return refresh() }
        let problems = new.problems()
        if let refusal = problems.isEmpty ? host?.accept(from: old, to: new) : problems.joined(separator: " ") {
            message.stringValue = refusal
            return refresh()
        }
        message.stringValue = ""
        store.update { $0.settings = new }
        host?.settingsChanged(from: old, to: new)
        refresh()
    }

    /// Puts every control back to what is stored.
    private func refresh() {
        let settings = store.state.settings
        for field in numbers { field.stringValue = String(format: "%g", settings[keyPath: field.keyPath]) }
        for box in toggles { box.state = settings[keyPath: box.keyPath] ? .on : .off }
        for (action, recorder) in recorders { recorder.chord = settings.keymap.chords[action] }
        tapLabel.stringValue = host?.tapStatus ?? ""
    }
}

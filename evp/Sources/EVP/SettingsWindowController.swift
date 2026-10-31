import AppKit
import EVPCore

/// Settings (Cmd+,) in three tabs: General, Keybinds, Global. Each change is checked (`Settings.problems()`, the
/// keymap's conflict rule) and written to the store, so windows read it on their next event. A change that does not
/// pass is refused with the reason, and the controls go back to what is stored.
final class SettingsWindowController: NSWindowController {
    private final class NumberField: NSTextField {
        var keyPath: WritableKeyPath<Settings, Double>!
    }

    private final class Toggle: NSButton {
        var keyPath: WritableKeyPath<Settings, Bool>!
    }

    private let store: StateStore
    private let onChange: (_ old: Settings, _ new: Settings) -> Void
    private let tapStatus: () -> String
    private let enableTap: () -> Void
    private let tapLabel = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var numbers: [NumberField] = []
    private var toggles: [Toggle] = []
    private var recorders: [Action: KeyRecorderField] = [:]

    init(store: StateStore, tapStatus: @escaping () -> String, enableTap: @escaping () -> Void,
         onChange: @escaping (_ old: Settings, _ new: Settings) -> Void) {
        self.store = store
        self.tapStatus = tapStatus
        self.enableTap = enableTap
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

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
        window.contentView = root
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindowController is created in code") }

    // MARK: Tabs

    private func generalTab() -> NSView {
        let rows: [NSView] = [
            toggle("Keep the media keys (F7, F8, F9) out of EVP", id: "setting-decouple", \.decoupleMediaKeys),
            toggle("Reopen the windows of the last session at launch", id: "setting-restore", \.restoreWindowsOnLaunch),
            tapRow(),
            number("Short seek step (seconds)", id: "setting-seekShort", \.seekShortSeconds),
            number("Long seek step (seconds)", id: "setting-seekLong", \.seekLongSeconds),
            number("Speed step", id: "setting-speedStep", \.speedStep),
            number("Volume step", id: "setting-volumeStep", \.volumeStep),
            number("Speed of a file never opened before", id: "setting-defaultSpeed", \.defaultSpeed),
            number("Volume of a file never opened before", id: "setting-defaultVolume", \.defaultVolume),
        ]
        return column(rows)
    }

    /// Reliable media keys need the Accessibility permission; this row shows where that stands and asks for it.
    private func tapRow() -> NSView {
        tapLabel.setAccessibilityIdentifier("setting-tap-status")
        let button = NSButton(title: "Enable…", target: self, action: #selector(enableReliableKeys))
        button.setAccessibilityIdentifier("setting-tap-enable")
        return row("Reliable media keys (needs Accessibility)", NSStackView(views: [tapLabel, button]))
    }

    @objc private func enableReliableKeys() {
        enableTap()
        refresh()
    }

    private func keybindsTab() -> NSView {
        let reset = NSButton(title: "Reset all to defaults", target: self, action: #selector(resetAll))
        reset.setAccessibilityIdentifier("bind-reset-all")
        let rows = Action.allCases.filter { !Action.global.contains($0) }.map(bindingRow)
        let list = column(rows)
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tab = NSStackView(views: [reset, scroll])
        tab.orientation = .vertical
        tab.alignment = .leading
        return tab
    }

    private func globalTab() -> NSView {
        let note = NSTextField(wrappingLabelWithString: "This key works while EVP is in the background.")
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
        label.widthAnchor.constraint(equalToConstant: 300).isActive = true
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

    private func bindingRow(_ action: Action) -> NSView {
        let recorder = KeyRecorderField()
        recorder.onChord = { [weak self] chord in self?.changeKeymap { try $0.bind(chord, to: action) } }
        recorder.onClear = { [weak self] in self?.changeKeymap { $0.unbind(action) } }
        recorder.setAccessibilityIdentifier("bind-\(action.rawValue)")
        recorders[action] = recorder
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetOne(_:)))
        reset.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        reset.setAccessibilityIdentifier("bind-reset-\(action.rawValue)")
        return row(action.title, NSStackView(views: [recorder, reset]))
    }

    // MARK: Changes

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

    @objc private func resetAll() { changeKeymap { $0.resetAll() } }

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

    /// Applies `change` to a copy of the settings, and stores it when the result is valid.
    private func commit(_ change: (inout Settings) -> Void) {
        let old = store.state.settings
        var new = old
        change(&new)
        let problems = new.problems()
        guard problems.isEmpty else {
            message.stringValue = problems.joined(separator: " ")
            return refresh()
        }
        message.stringValue = ""
        if new != old {
            store.update { $0.settings = new }
            onChange(old, new)
        }
        refresh()
    }

    /// Puts every control back to what is stored.
    private func refresh() {
        let settings = store.state.settings
        for field in numbers { field.stringValue = String(format: "%g", settings[keyPath: field.keyPath]) }
        for box in toggles { box.state = settings[keyPath: box.keyPath] ? .on : .off }
        for (action, recorder) in recorders { recorder.chord = settings.keymap.chords[action] }
        tapLabel.stringValue = tapStatus()
    }
}

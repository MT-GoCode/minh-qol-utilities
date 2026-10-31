import AppKit
import EVPCore

/// A button that shows a chord. Clicking it (or pressing it from the keyboard) waits for the next key press and reports
/// it; Escape cancels and Delete unbinds.
final class KeyRecorderField: NSButton {
    var onChord: ((KeyChord) -> Void)?
    var onClear: (() -> Void)?
    private var recording = false {
        didSet { render() }
    }

    var chord: KeyChord? {
        didSet { render() }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        render()
    }

    required init?(coder: NSCoder) { fatalError("KeyRecorderField is created in code") }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    private func render() { title = recording ? "Press a key…" : chord.map(\.description) ?? "Not set" }

    @objc private func startRecording() {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        guard let pressed = KeyChord.chord(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: Modifiers(event.modifierFlags)) else { return }
        recording = false
        switch pressed.description {
        case "escape": break
        case "delete": onClear?()
        default: onChord?(pressed)
        }
    }

    /// Command shortcuts (such as the menu's) must be recordable too, so they are not left to the menu while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

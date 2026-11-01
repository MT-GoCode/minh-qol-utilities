import AppKit
import EVPCore

/// A button that shows a chord. Clicking it (or pressing it from the keyboard) waits for the next key press and reports
/// it; Escape cancels and Delete unbinds.
final class KeyRecorderField: NSButton {
    private static let cancel = KeyChord(key: "escape")!
    private static let clear = KeyChord(key: "delete")!

    var onChord: ((KeyChord) -> Void)?
    var onClear: (() -> Void)?
    /// Told when recording starts and stops.
    var onRecording: ((Bool) -> Void)?
    private var recording = false {
        didSet {
            render()
            if recording != oldValue { onRecording?(recording) }
        }
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
        recording = window?.makeFirstResponder(self) == true
    }

    override func keyDown(with event: NSEvent) {
        // A held key's repeat must not press the button again and restart the recording it just ended.
        guard recording || !event.isARepeat else { return }
        guard recording else { return super.keyDown(with: event) }
        guard let pressed = KeyChord.chord(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: Modifiers(event.modifierFlags)) else { return }
        recording = false
        switch pressed {
        case Self.cancel: break
        case Self.clear: onClear?()
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

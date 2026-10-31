import AppKit
import EVPCore

/// The current time, `4:52`. A double-click selects the whole text for editing: type or delete to replace it, Return
/// goes there if it is a valid time (`4:52`, `1:04:52`, `292`, `+30`, `-30`), a bad time flashes red and is dropped,
/// Escape or clicking away cancels. While editing, the ticking clock does not overwrite what is being typed.
final class TimeField: NSTextField, NSTextFieldDelegate {
    var onSubmit: ((TimeInput) -> Void)?
    private var shown = "0:00"
    private var isEditing = false

    init() {
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        textColor = .white
        alignment = .right
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 4
        delegate = self
        stringValue = shown
        setAccessibilityIdentifier("time")
    }

    required init?(coder: NSCoder) { fatalError("TimeField is created in code") }

    func show(seconds: Double) {
        shown = TimeFormat.format(seconds)
        if !isEditing { stringValue = shown }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keyboard and accessibility focus start the edit too, for people who cannot double-click. Focus that comes from a
    /// single mouse click does not: the mouse way in is the double-click.
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, !isEditing, NSApp.currentEvent?.type != .leftMouseDown {
            DispatchQueue.main.async { [weak self] in self?.beginEditing() }
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginEditing() } else { super.mouseDown(with: event) }
    }

    private func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        setAccessibilityHelp("editing")  // what tests read to know the field is ready for typing
        isEditable = true
        isSelectable = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        selectText(nil)  // starts the field editor (even when this field is already first responder) with everything selected
    }

    private func endEditing() {
        isEditing = false
        setAccessibilityHelp(nil)
        isEditable = false
        isSelectable = false
        layer?.backgroundColor = nil
        window?.makeFirstResponder(window?.contentView)
        stringValue = shown
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let typed = stringValue
            endEditing()
            if let input = TimeFormat.parse(typed) { onSubmit?(input) } else { flashRed() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere ends the edit without going anywhere.
    func controlTextDidEndEditing(_ notification: Notification) {
        if isEditing { endEditing() }
    }

    private func flashRed() {
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.isEditing == false { self?.layer?.backgroundColor = nil }
        }
    }
}

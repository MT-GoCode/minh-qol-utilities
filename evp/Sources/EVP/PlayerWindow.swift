import AppKit
import EVPCore

/// The player window. It offers every key press to `handleKey` before anything else sees it, so a focused button
/// never swallows the space bar; while text is being edited the keys go to the text.
final class PlayerWindow: NSWindow {
    /// Returns true when the key was a command.
    var handleKey: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !(firstResponder is NSText), handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self.init()
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

import Carbon
import EVPCore

/// One system-wide hotkey (Ctrl+Space by default) through Carbon's `RegisterEventHotKey`, which needs no permission.
/// One instance for the app's lifetime: `register` swaps the chord, the event handler is installed once.
final class GlobalHotkey {
    struct RegistrationFailed: Error, LocalizedError {
        let chord: KeyChord
        let status: OSStatus
        var errorDescription: String? { "\(chord) could not be registered as a global hotkey (error \(status)). Another app may own it." }
    }

    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            Unmanaged<GlobalHotkey>.fromOpaque(data!).takeUnretainedValue().onPress()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Replaces the registered chord. A chord without a key code, or one the system refuses, throws and leaves none.
    func register(_ chord: KeyChord) throws {
        unregister()
        guard let code = chord.virtualKeyCode else { throw RegistrationFailed(chord: chord, status: OSStatus(paramErr)) }
        var modifiers = 0
        if chord.modifiers.contains(.control) { modifiers |= controlKey }
        if chord.modifiers.contains(.option) { modifiers |= optionKey }
        if chord.modifiers.contains(.shift) { modifiers |= shiftKey }
        if chord.modifiers.contains(.command) { modifiers |= cmdKey }
        let status = RegisterEventHotKey(UInt32(code), UInt32(modifiers), EventHotKeyID(signature: 0x45565031, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { throw RegistrationFailed(chord: chord, status: status) }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

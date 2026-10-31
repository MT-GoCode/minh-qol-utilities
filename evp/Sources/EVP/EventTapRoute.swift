import AppKit
import ApplicationServices
import EVPCore

/// Reliable F7, F8 and F9: a session event tap sees the media keys before any other app and consumes them while a window
/// is playing. It needs the Accessibility permission, which is asked for only when the user turns coupling on, never at
/// launch and never while decoupled; without it the remote-command route (`MediaKeys`) keeps working.
final class EventTapRoute {
    enum Status: String {
        case active = "Active"
        case needsAccessibility = "Needs Accessibility"
        case inactive = "Off"
        case failed = "Could not start"
    }

    private var tap: CFMachPort?
    private var failedToStart = false
    private var router = MediaKeyRouter()
    private let decoupled: () -> Bool
    private let target: () -> PlayerWindowController?

    init(decoupled: @escaping () -> Bool, target: @escaping () -> PlayerWindowController?) {
        (self.decoupled, self.target) = (decoupled, target)
    }

    var status: Status {
        if tap != nil { return .active }
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        return failedToStart ? .failed : .inactive
    }

    /// Starts the tap. `prompt` lets the system ask for the permission (once: when already trusted or asked, the system
    /// shows nothing). Calling it again while the tap runs does nothing.
    func enable(prompt: Bool) {
        guard tap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1 << 14,
                                              callback: eventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            failedToStart = true
            return
        }
        failedToStart = false
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, created, 0), .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
    }

    func disable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard let system = NSEvent(cgEvent: event), system.type == .systemDefined, system.subtype.rawValue == 8,
              let key = MediaKey(systemKeyType: (system.data1 & 0xFFFF0000) >> 16) else { return pass }
        let isDown = ((system.data1 & 0xFF00) >> 8) == 0xA
        let isRepeat = system.data1 & 0x1 != 0
        switch router.decide(key, isKeyDown: isDown, decoupled: decoupled(), anythingPlaying: target() != nil) {
        case .pass:
            return pass
        case .consume(let action):
            if let action, action.runs(onRepeat: isRepeat) { target()?.perform(.action(action)) }
            return nil
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    Unmanaged<EventTapRoute>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
}

// Probe: Accessibility-gated CGEventTap on media keys. Consumes key 16 only.
import AppKit
import ApplicationServices

print("trusted=\(AXIsProcessTrusted())"); fflush(stdout)
let cb: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { print("TAP DISABLED"); fflush(stdout); return Unmanaged.passUnretained(event) }
    if type == .keyDown { print("TAP keyDown \(event.getIntegerValueField(.keyboardEventKeycode))"); fflush(stdout) }
    if let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 {
        let key = (ns.data1 & 0xFFFF0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        print("TAP key=\(key) down=\(down)"); fflush(stdout)
        if key == 16 { return nil }
    }
    return Unmanaged.passUnretained(event)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: (1 << 14) | (1 << 10), callback: cb, userInfo: nil) else {
    print("TAP CREATE FAILED"); exit(0)
}
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("tap enabled"); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 8) { print("exit"); exit(0) }
CFRunLoopRun()

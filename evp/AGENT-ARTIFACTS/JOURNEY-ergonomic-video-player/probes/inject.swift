// Posts media-key and ctrl+space events. args: keycodes... (16 play, 19 fast, 20 rewind, 17 next, 18 prev, 'hot' = ctrl+space)
import AppKit
func media(_ k: Int, _ down: Bool) {
    let flags = down ? 0xA00 : 0xB00
    let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (k << 16) | flags, data2: -1)!
    e.cgEvent!.post(tap: .cghidEventTap)
}
for a in CommandLine.arguments.dropFirst() {
    if a == "hot" {
        for d in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: d)!; e.flags = .maskControl; e.post(tap: .cghidEventTap) }
    } else if a == "x" {
        for d in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: d)!.post(tap: .cghidEventTap) }
    } else { media(Int(a)!, true); media(Int(a)!, false) }
    usleep(400_000)
}

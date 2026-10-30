// Test driver: synthetic input and window discovery. `key`, `media` and `snapshot` need GUI permissions, so run
// them as `rac exec`; `windows` works from any shell. Built by ./test into .build/evpdrive.
//   evpdrive windows <pid>               one JSON object per window: {"id":N,"x":..,"y":..,"w":..,"h":..}
//   evpdrive snapshot <window id> <png>  window-scoped screenshot
//   evpdrive key <pid|hid> <chord> [n]   chord like right, shift+right, j, space, ctrl+space; n>1 sends autorepeat
//   evpdrive media <code>...             media keys (16 play/pause, 17 next, 18 previous, 19 fast, 20 rewind)
import AppKit

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "k": 40, ",": 43,
    "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]
let modifiers: [String: CGEventFlags] = ["shift": .maskShift, "ctrl": .maskControl, "alt": .maskAlternate, "cmd": .maskCommand]

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }

func int(_ text: String) -> Int {
    guard let value = Int(text) else { fail("not a number: \(text)") }
    return value
}

func postKey(target: String, chord: String, count: Int) {
    let parts = chord.split(separator: "+").map(String.init)
    guard let name = parts.last, let code = codes[name] else { fail("unknown key in chord \(chord)") }
    var flags = CGEventFlags()
    for m in parts.dropLast() {
        guard let flag = modifiers[m] else { fail("unknown modifier \(m)") }
        flags.insert(flag)
    }
    for i in 0..<count {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            if i > 0 && down { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            if target == "hid" { event.post(tap: .cghidEventTap) } else { event.postToPid(pid_t(int(target))) }
        }
        usleep(30_000)  // about one macOS key-repeat interval
    }
}

func postMedia(_ key: Int) {
    for flags in [0xA00, 0xB00] {
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | flags, data2: -1)!
            .cgEvent!.post(tap: .cghidEventTap)
    }
    usleep(400_000)  // spacing at which every injected media key was delivered in the probes
}

func listWindows(pid: pid_t) {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    if mine.isEmpty { fail("no windows for pid \(pid)") }
    for w in mine {
        let b = w[kCGWindowBounds as String] as! [String: Double]
        print(#"{"id":\#(w[kCGWindowNumber as String]!),"x":\#(b["X"]!),"y":\#(b["Y"]!),"w":\#(b["Width"]!),"h":\#(b["Height"]!)}"#)
    }
}

func snapshot(window: Int, to path: String) {
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(window), path]
    try! shot.run()
    shot.waitUntilExit()
    if shot.terminationStatus != 0 { fail("screencapture failed for window \(window)") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "windows" where args.count == 2: listWindows(pid: pid_t(int(args[1])))
case "snapshot" where args.count == 3: snapshot(window: int(args[1]), to: args[2])
case "key" where args.count >= 3: postKey(target: args[1], chord: args[2], count: args.count > 3 ? int(args[3]) : 1)
case "media" where args.count >= 2: args.dropFirst().forEach { postMedia(int($0)) }
default: fail("usage: evpdrive windows <pid> | snapshot <window id> <png> | key <pid|hid> <chord> [n] | media <code>...")
}

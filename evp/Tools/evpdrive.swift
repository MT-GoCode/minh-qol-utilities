// Test driver: synthetic input and window discovery. `key`, `media` and `snapshot` need GUI permissions, so run
// them as `rac exec`; `windows` works from any shell. Built by ./test into .build/evpdrive.
//   evpdrive windows <pid>               one JSON object per window: {"id":N,"x":..,"y":..,"w":..,"h":..}
//   evpdrive resize <pid> <width> <height>  move the first window to the top-left, then set its frame size (needs Accessibility)
//   evpdrive press <pid> <id>            press the button with that accessibility identifier (needs Accessibility)
//   evpdrive perform <pid> <id> <action>   run the element's accessibility action whose name contains `action`
//   evpdrive setvalue <pid> <id> <number>  set the element's accessibility value (a slider's position, 0 to 1)
//   evpdrive type <pid> <text>             type the text (as characters, not key codes)
//   evpdrive focus <pid> <id>            give that element keyboard focus (needs Accessibility)
//   evpdrive read <pid> <id> [attribute] print the value, title or description of that element, or the named attribute
//   evpdrive tree <pid>                  print the accessibility tree (role and identifier), for debugging
//   evpdrive snapshot <window id> <png>  window-scoped screenshot
//   evpdrive key <pid|hid> <chord> [n]   chord like right, shift+right, j, space, ctrl+space; n presses in a row
//   evpdrive media <code>...             media keys (16 play/pause, 17 next, 18 previous, 19 fast, 20 rewind)
import AppKit
import ApplicationServices

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

enum Target {
    case hid
    case pid(pid_t)
}

func parseTarget(_ text: String) -> Target { text == "hid" ? .hid : .pid(pid_t(int(text))) }

func postKey(target: Target, chord: String, count: Int) {
    let parts = chord.split(separator: "+").map(String.init)
    guard let name = parts.last, let code = codes[name] else { fail("unknown key in chord \(chord)") }
    var flags = CGEventFlags()
    for m in parts.dropLast() {
        guard let flag = modifiers[m] else { fail("unknown modifier \(m)") }
        flags.insert(flag)
    }
    // macOS drops synthetic key-downs that carry the autorepeat flag, so `count` is that many separate presses.
    for i in 0..<count {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            switch target {
            case .hid: event.post(tap: .cghidEventTap)
            case .pid(let pid): event.postToPid(pid)
            }
        }
        usleep(30_000)  // the fastest macOS key-repeat setting; also lets the events arrive before this tool exits
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

func resize(pid: pid_t, width: Double, height: Double) {
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows) == .success,
          let window = (windows as? [AXUIElement])?.first else { fail("no accessible window for pid \(pid)") }
    // A window cannot grow past the screen edge, so start from the corner (just below the menu bar).
    var origin = CGPoint(x: 0, y: 40)
    guard let position = AXValueCreate(.cgPoint, &origin),
          AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else { fail("could not move the window of pid \(pid)") }
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else { fail("could not resize the window of pid \(pid)") }
}

func element(pid: pid_t, id: String) -> AXUIElement {
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func search(_ element: AXUIElement) -> AXUIElement? {
        if attribute(element, "AXIdentifier") as? String == id { return element }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.lazy.compactMap(search).first
    }
    guard let found = search(AXUIElementCreateApplication(pid)) else { fail("no element \(id) in pid \(pid)") }
    return found
}

func tree(pid: pid_t) {
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func walk(_ element: AXUIElement, depth: Int) {
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let id = attribute(element, "AXIdentifier") as? String ?? ""
        print(String(repeating: "  ", count: depth) + role + (id.isEmpty ? "" : " #" + id))
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.forEach { walk($0, depth: depth + 1) }
    }
    walk(AXUIElementCreateApplication(pid), depth: 0)
}

func press(pid: pid_t, id: String) {
    guard AXUIElementPerformAction(element(pid: pid, id: id), kAXPressAction as CFString) == .success else { fail("could not press \(id)") }
}

func frame(pid: pid_t, id: String) -> CGRect {
    let target = element(pid: pid, id: id)
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(target, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size else { fail("\(id) has no frame") }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

func perform(pid: pid_t, id: String, action: String) {
    var names: CFArray?
    let target = element(pid: pid, id: id)
    guard AXUIElementCopyActionNames(target, &names) == .success,
          let match = (names as? [String])?.first(where: { $0.contains(action) }) else {
        fail("\(id) has no action matching \(action); it has \((names as? [String]) ?? [])")
    }
    guard AXUIElementPerformAction(target, match as CFString) == .success else { fail("could not perform \(match) on \(id)") }
}

func setValue(pid: pid_t, id: String, value: Double) {
    guard AXUIElementSetAttributeValue(element(pid: pid, id: id), kAXValueAttribute as CFString, NSNumber(value: value)) == .success else {
        fail("could not set the value of \(id)")
    }
}

func typeText(pid: pid_t, text: String) {
    for character in text {
        let characters = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            event.postToPid(pid)
        }
        usleep(30_000)
    }
}

func focus(pid: pid_t, id: String) {
    guard AXUIElementSetAttributeValue(element(pid: pid, id: id), kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { fail("could not focus \(id)") }
}

func read(pid: pid_t, id: String, attribute: String?) {
    let target = element(pid: pid, id: id)
    for name in attribute.map({ [$0] }) ?? [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, name as CFString, &value) == .success, let value, !"\(value)".isEmpty { print("\(value)"); return }
    }
    fail("\(id) has no value, title or description")
}

func snapshot(window: Int, to path: String) {
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(window), path]
    do { try shot.run() } catch { fail("could not start screencapture: \(error)") }
    shot.waitUntilExit()
    if shot.terminationStatus != 0 { fail("screencapture failed for window \(window)") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "windows" where args.count == 2: listWindows(pid: pid_t(int(args[1])))
case "resize" where args.count == 4: resize(pid: pid_t(int(args[1])), width: Double(int(args[2])), height: Double(int(args[3])))
case "tree" where args.count == 2: tree(pid: pid_t(int(args[1])))
case "press" where args.count == 3: press(pid: pid_t(int(args[1])), id: args[2])
case "perform" where args.count == 4: perform(pid: pid_t(int(args[1])), id: args[2], action: args[3])
case "setvalue" where args.count == 4: setValue(pid: pid_t(int(args[1])), id: args[2], value: Double(args[3]) ?? { fail("not a number: \(args[3])") }())
case "type" where args.count == 3: typeText(pid: pid_t(int(args[1])), text: args[2])
case "focus" where args.count == 3: focus(pid: pid_t(int(args[1])), id: args[2])
case "read" where args.count == 3 || args.count == 4: read(pid: pid_t(int(args[1])), id: args[2], attribute: args.count == 4 ? args[3] : nil)
case "snapshot" where args.count == 3: snapshot(window: int(args[1]), to: args[2])
case "key" where args.count >= 3: postKey(target: parseTarget(args[1]), chord: args[2], count: args.count > 3 ? int(args[3]) : 1)
case "media" where args.count >= 2: args.dropFirst().forEach { postMedia(int($0)) }
default: fail("usage: evpdrive windows <pid> | resize <pid> <w> <h> | press <pid> <id> | perform <pid> <id> <action> | setvalue <pid> <id> <number> | type <pid> <text> | focus <pid> <id> | read <pid> <id> [attribute] | snapshot <window id> <png> | key <pid|hid> <chord> [n] | media <code>...")
}

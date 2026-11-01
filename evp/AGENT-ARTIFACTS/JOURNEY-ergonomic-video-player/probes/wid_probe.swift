// Feasibility probe: libmpv embedded in an NSView via `wid`, plus property reads.
import AppKit
import CMpv

let file = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
                   styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
win.title = "probe"
let view = NSView(frame: win.contentView!.bounds)
view.autoresizingMask = [.width, .height]
win.contentView!.addSubview(view)
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

let h = mpv_create()!
var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)
mpv_set_option_string(h, "vo", "gpu")
mpv_set_option_string(h, "keep-open", "yes")
precondition(mpv_initialize(h) == 0)
func cmd(_ a: [String]) {
    var cs: [UnsafePointer<CChar>?] = a.map { UnsafePointer(strdup($0)) } + [nil]
    mpv_command(h, &cs)
}
cmd(["loadfile", file])

func prop(_ n: String) -> String {
    guard let c = mpv_get_property_string(h, n) else { return "nil" }
    defer { mpv_free(c) }
    return String(cString: c)
}
let t0 = Date()
Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
    print("time-pos=\(prop("time-pos")) vo=\(prop("current-vo")) hwdec=\(prop("hwdec-current")) wh=\(prop("width"))x\(prop("height")) windowID=\(win.windowNumber)")
    fflush(stdout)
}
Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
    print("done after \(Date().timeIntervalSince(t0))"); exit(0)
}
app.run()

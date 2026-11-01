// Probe: libmpv render API (OpenGL) into an NSOpenGLView, resizable, letterboxed by mpv.
import AppKit
import OpenGL.GL3
import CMpv

let file = CommandLine.arguments[1]
var mpv: OpaquePointer!
var rctx: OpaquePointer?

final class GLView: NSOpenGLView {
    override func prepareOpenGL() {
        var one: GLint = 1
        openGLContext!.setValues(&one, for: .swapInterval)
        openGLContext!.makeCurrentContext()
        let gpa: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            let sym = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
            return CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString), sym)
        }
        var initp = mpv_opengl_init_params(get_proc_address: gpa, get_proc_address_ctx: nil)
        var api = strdup(MPV_RENDER_API_TYPE_OPENGL)
        withUnsafeMutablePointer(to: &initp) { ip in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                          mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: ip),
                          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            let r = mpv_render_context_create(&rctx, mpv, &params)
            print("render_context_create=\(r)"); fflush(stdout)
        }
        free(api)
        mpv_render_context_set_update_callback(rctx, { _ in DispatchQueue.main.async { glView.needsDisplay = true } }, nil)
        var cs: [UnsafePointer<CChar>?] = ["loadfile", file].map { UnsafePointer(strdup($0)) } + [nil]
        mpv_command(mpv, &cs)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let rctx else { return }
        let s = convertToBacking(bounds).size
        var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(s.width), h: Int32(s.height), internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fp in
            withUnsafeMutablePointer(to: &flip) { lp in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fp),
                              mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: lp),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                mpv_render_context_render(rctx, &params)
            }
        }
        openGLContext!.flushBuffer()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500),
                   styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
win.title = "glprobe"
let pf = NSOpenGLPixelFormat(attributes: [UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
                                          UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), 0])!
let glView = GLView(frame: win.contentView!.bounds, pixelFormat: pf)!
glView.autoresizingMask = [.width, .height]
glView.wantsBestResolutionOpenGLSurface = true
win.contentView!.addSubview(glView)

mpv = mpv_create()
mpv_set_option_string(mpv, "vo", "libmpv")
mpv_set_option_string(mpv, "keep-open", "yes"); mpv_set_option_string(mpv, "terminal", "yes"); mpv_set_option_string(mpv, "msg-level", "all=v")
mpv_set_option_string(mpv, "input-media-keys", "no")
precondition(mpv_initialize(mpv) == 0)
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

func prop(_ n: String) -> String {
    guard let c = mpv_get_property_string(mpv, n) else { return "nil" }
    defer { mpv_free(c) }
    return String(cString: c)
}
Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
    print("time-pos=\(prop("time-pos")) hwdec=\(prop("hwdec-current")) wh=\(prop("width"))x\(prop("height")) windowID=\(win.windowNumber)"); fflush(stdout)
}
Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in print("done"); exit(0) }
app.run()

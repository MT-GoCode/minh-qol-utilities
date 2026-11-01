import CMpv
import Foundation

public struct MpvError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let code: Int32
    public var description: String { String(cString: mpv_error_string(code)) }
    /// What an alert shows: mpv's own words, not the bridged "error 1".
    public var errorDescription: String? { "mpv: \(description) (\(code))" }

    public static let unknownFormat = MpvError(code: MPV_ERROR_UNKNOWN_FORMAT.rawValue)
}

public struct Track: Equatable {
    public enum Kind: String {
        case video, audio, sub
    }

    public let id: Int
    public let kind: Kind
    public let language: String?
    public let title: String?
    public let selected: Bool

    public init(id: Int, kind: Kind, language: String?, title: String?, selected: Bool) {
        (self.id, self.kind, self.language, self.title, self.selected) = (id, kind, language, title, selected)
    }
}

/// The only code that touches libmpv. Create it and use it on the main thread; events arrive on the main queue.
public final class MpvPlayer {
    public enum Event: Equatable {
        case fileLoaded
        case loadFailed(MpvError)
        /// The first frame of a load, or of a seek that has landed, is ready.
        case playbackRestart
        case time(Double)
        case duration(Double)
        case paused(Bool)
        case speed(Double)
        case volume(Double)
        case muted(Bool)
        case endOfFile(Bool)
    }

    /// Every observed property: the tag sent to mpv, its name and its wire format, in one place so observing
    /// and decoding cannot disagree. A new case is a compile error in `drain` until it is handled.
    private enum Observed: UInt64, CaseIterable {
        case time = 1, duration, paused, speed, volume, muted, endOfFile

        var name: String {
            switch self {
            case .time: return "time-pos"
            case .duration: return "duration"
            case .paused: return "pause"
            case .speed: return "speed"
            case .volume: return "volume"
            case .muted: return "mute"
            case .endOfFile: return "eof-reached"
            }
        }

        var format: mpv_format {
            switch self {
            case .time, .duration, .speed, .volume: return MPV_FORMAT_DOUBLE
            case .paused, .muted, .endOfFile: return MPV_FORMAT_FLAG
            }
        }
    }

    /// Where the player sends picture and sound. `video` draws through a render context (`attachRenderer`) and
    /// plays audio; `headless` has neither, for tests.
    public enum Output {
        case headless
        case video
        /// Small silent frames for thumbnails: no sound decoded, every frame scaled to 320 wide, screenshots as JPEG.
        case preview

        fileprivate var options: [(String, String)] {
            switch self {
            case .headless: return [("vo", "null"), ("ao", "null")]
            case .video: return [("vo", "libmpv")]
            case .preview: return [("vo", "null"), ("ao", "null"), ("aid", "no"), ("vf", "scale=320:-2"), ("screenshot-format", "jpg")]
            }
        }
    }

    public static var libraryVersion: String {
        let version = mpv_client_api_version()
        return "\(version >> 16).\(version & 0xFFFF)"
    }

    public var onEvent: ((Event) -> Void)?
    /// The render context has a new frame to draw.
    public var onNeedsRedraw: (() -> Void)?
    private let output: Output
    private let handle: OpaquePointer
    private let wake: Unmanaged<WakeBox>
    private var renderContext: OpaquePointer?

    /// Lets the wakeup callback (any thread) reach the player without keeping it alive.
    /// `pending` keeps a frame's burst of wakeups to one main-queue block: `drain` reads every waiting event anyway.
    private final class WakeBox {
        weak var player: MpvPlayer?
        private let lock = NSLock()
        private var pending = false

        func wake() {
            guard lock.withLock({ defer { pending = true }; return !pending }) else { return }
            DispatchQueue.main.async {
                self.lock.withLock { self.pending = false }  // before draining: an event after this point schedules another drain
                self.player?.drain()
            }
        }
    }

    public convenience init() throws { try self.init(output: .headless) }

    public init(output: Output) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        self.output = output
        // mpv requires the C numeric locale; AppKit may have set another one.
        setlocale(LC_NUMERIC, "C")
        guard let h = mpv_create() else { throw MpvError(code: MPV_ERROR_NOMEM.rawValue) }
        handle = h
        wake = Unmanaged.passRetained(WakeBox())
        wake.takeUnretainedValue().player = self
        // keep-open: at the end of a file mpv pauses on the last frame instead of unloading it, so position and
        // duration stay readable and MPV_EVENT_END_FILE does not fire (the `endOfFile` property event does); the resume rule near the end relies on this.
        // auto-copy-safe: hardware decoding with each frame copied back to memory. Zero-copy frames stay on the GPU,
        // where mpv's screenshot cannot read them ("videotoolbox not supported by libswscale").
        let options = output.options + [("hwdec", "auto-copy-safe"), ("keep-open", "yes"), ("input-media-keys", "no")]
        for (name, value) in options { try Self.check(mpv_set_option_string(h, name, value)) }
        try Self.check(mpv_initialize(h))
        // mpv holds wakeup_lock while calling the callback, and setting it to nil takes the same lock,
        // so deinit cannot release `wake` under a running callback.
        mpv_set_wakeup_callback(h, { ctx in
            Unmanaged<WakeBox>.fromOpaque(ctx!).takeUnretainedValue().wake()
        }, wake.toOpaque())
        for observed in Observed.allCases {
            try Self.check(mpv_observe_property(h, observed.rawValue, observed.name, observed.format))
        }
    }

    deinit {
        detachRenderer()
        mpv_set_wakeup_callback(handle, nil, nil)
        wake.release()
        mpv_terminate_destroy(handle)
    }

    // MARK: Playback

    /// Starts playing `url`, at `start` seconds when given. A video player must have its renderer attached first:
    /// mpv decides the video pipeline when the file opens.
    public func load(_ url: URL, start: Double? = nil) throws {
        precondition(url.isFileURL, "only file URLs can be loaded")
        precondition(output != .video || renderContext != nil, "attach the renderer before loading")
        try command(start.map { ["loadfile", url.path, "replace", "-1", "start=\($0)"] } ?? ["loadfile", url.path])
    }

    // MARK: Rendering (OpenGL)

    /// Creates the render context. Call with the OpenGL context current, before `load`.
    public func attachRenderer() throws {
        precondition(output == .video && renderContext == nil, "attachRenderer is for a video player, once")
        let api = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(api) }
        var glInit = mpv_opengl_init_params(get_proc_address: Self.glProcAddress, get_proc_address_ctx: nil)
        try withUnsafeMutablePointer(to: &glInit) { glInitPointer in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                          mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glInitPointer),
                          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            try Self.check(mpv_render_context_create(&renderContext, handle, &params))
        }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let box = Unmanaged<WakeBox>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { box.player?.onNeedsRedraw?() }
        }, wake.toOpaque())
    }

    /// Draws the current frame into the default framebuffer of the current OpenGL context, fitted with black bars.
    public func render(width: Int32, height: Int32) {
        guard let renderContext else { preconditionFailure("render before attachRenderer") }
        var framebuffer = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1
        let code = withUnsafeMutablePointer(to: &framebuffer) { fbo in
            withUnsafeMutablePointer(to: &flipY) { flip in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fbo),
                              mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flip),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                return mpv_render_context_render(renderContext, &params)
            }
        }
        precondition(code >= 0, "mpv_render_context_render failed: \(MpvError(code: code))")
    }

    /// Tell mpv the frame was shown (it uses this for timing).
    public func didSwap() { mpv_render_context_report_swap(renderContext) }

    /// Frees the render context. Call with the OpenGL context current, before the context is destroyed.
    public func detachRenderer() {
        guard let context = renderContext else { return }
        mpv_render_context_set_update_callback(context, nil, nil)
        mpv_render_context_free(context)
        renderContext = nil
    }

    private static let glProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
        let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
        return CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString), symbol)
    }

    public func setPaused(_ paused: Bool) throws { try set("pause", paused ? "yes" : "no") }

    /// Relative seek, frame-exact (`exact`): the pause state is left as it was.
    public func seek(by seconds: Double) throws { try command(["seek", String(seconds), "relative+exact"]) }

    /// Frame-exact jump to `seconds` from the start.
    public func seek(to seconds: Double) throws { try command(["seek", String(seconds), "absolute+exact"]) }

    /// Jump to the keyframe nearest `seconds`: fast, not frame-exact.
    public func seek(keyframeNear seconds: Double) throws { try command(["seek", String(seconds), "absolute+keyframes"]) }

    public func seek(toFraction fraction: Double) throws { try command(["seek", String(fraction * 100), "absolute-percent+exact"]) }

    /// Steps `count` frames forward, or back when negative.
    public func frameStep(_ count: Int) throws {
        for _ in 0..<abs(count) { try command([count > 0 ? "frame-step" : "frame-back-step"]) }
    }

    /// Saves the frame being shown as a PNG at the video's own resolution, without subtitles or on-screen text.
    public func screenshot(to url: URL) throws { try command(["screenshot-to-file", url.path, "video"]) }

    public func toggleMute() throws { try command(["cycle", "mute"]) }

    // MARK: Speed and volume

    public func speed() throws -> Double { try number("speed") }
    public func volume() throws -> Double { try number("volume") }

    public func setSpeed(_ speed: Double) throws { try set("speed", String(speed)) }
    public func setVolume(_ volume: Double) throws { try set("volume", String(volume)) }

    /// Adds `delta`, rounded to 2 decimals so repeated 0.1 steps stay exact, and clamps to mpv's limits.
    public func adjustSpeed(by delta: Double) throws {
        let target = ((try speed() + delta) * 100).rounded() / 100
        try setSpeed(min(max(target, PlaybackLimits.speed.lowerBound), PlaybackLimits.speed.upperBound))
    }

    public func adjustVolume(by delta: Double) throws {
        try setVolume(min(max(try volume() + delta, PlaybackLimits.volume.lowerBound), PlaybackLimits.volume.upperBound))
    }

    // MARK: Tracks

    public func tracks() throws -> [Track] {
        guard let json = try property("track-list") else { return [] }
        guard let list = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw MpvError(code: MPV_ERROR_PROPERTY_FORMAT.rawValue)
        }
        return list.compactMap { entry in
            guard let id = entry["id"] as? Int, let kind = Track.Kind(rawValue: entry["type"] as? String ?? "") else { return nil }
            return Track(id: id, kind: kind, language: entry["lang"] as? String, title: entry["title"] as? String,
                         selected: entry["selected"] as? Bool ?? false)
        }
    }

    /// Selects track `id` of `kind`, or turns that kind off when `id` is nil.
    public func select(_ kind: Track.Kind, id: Int?) throws {
        let name: String
        switch kind {
        case .video: name = "vid"
        case .audio: name = "aid"
        case .sub: name = "sid"
        }
        try set(name, id.map(String.init) ?? "no")
    }

    // MARK: Properties

    /// The property as text; nil only when mpv reports it unavailable (for example no video stream).
    /// Any other failure, such as a misspelled name, throws.
    public func property(_ name: String) throws -> String? {
        var text: UnsafeMutablePointer<CChar>?
        let code = mpv_get_property(handle, name, MPV_FORMAT_STRING, &text)
        if code == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue { return nil }
        try Self.check(code)
        defer { mpv_free(text) }
        return String(cString: text!)
    }

    private func number(_ name: String) throws -> Double {
        var value = 0.0
        try Self.check(mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value))
        return value
    }

    private func set(_ name: String, _ value: String) throws { try Self.check(mpv_set_property_string(handle, name, value)) }

    private static func check(_ code: Int32) throws {
        guard code >= 0 else { throw MpvError(code: code) }
    }

    private func command(_ args: [String]) throws {
        var argv: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { argv.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
        try Self.check(mpv_command(handle, &argv))
    }

    private func drain() {
        while true {
            let event = mpv_wait_event(handle, 0).pointee
            switch event.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_QUEUE_OVERFLOW:
                preconditionFailure("mpv event queue overflowed: events were lost")
            case MPV_EVENT_FILE_LOADED:
                onEvent?(.fileLoaded)
            case MPV_EVENT_PLAYBACK_RESTART:
                onEvent?(.playbackRestart)
            case MPV_EVENT_END_FILE:
                let end = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR { onEvent?(.loadFailed(MpvError(code: end.error))) }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let observed = Observed(rawValue: event.reply_userdata) else {
                    preconditionFailure("property change with unknown tag \(event.reply_userdata)")
                }
                let p = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let data = p.data else { continue }
                // The payload has the format registered for the tag: read only the matching width.
                func number() -> Double { data.assumingMemoryBound(to: Double.self).pointee }
                func flag() -> Bool { data.assumingMemoryBound(to: Int32.self).pointee != 0 }
                switch observed {
                case .time: onEvent?(.time(number()))
                case .duration: onEvent?(.duration(number()))
                case .speed: onEvent?(.speed(number()))
                case .volume: onEvent?(.volume(number()))
                case .paused: onEvent?(.paused(flag()))
                case .muted: onEvent?(.muted(flag()))
                case .endOfFile: onEvent?(.endOfFile(flag()))
                }
            default:
                break
            }
        }
    }
}

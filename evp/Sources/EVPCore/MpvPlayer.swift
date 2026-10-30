import CMpv
import Foundation

public struct MpvError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public var description: String { String(cString: mpv_error_string(code)) }
}

/// The only code that touches libmpv. Create it and use it on the main thread; events arrive on the main queue.
public final class MpvPlayer {
    public enum Event: Equatable {
        case fileLoaded
        case loadFailed(MpvError)
        case time(Double)
        case duration(Double)
        case paused(Bool)
    }

    /// Every observed property: the tag sent to mpv, its name and its wire format, in one place so observing
    /// and decoding cannot disagree. A new case is a compile error in `drain` until it is handled.
    private enum Observed: UInt64, CaseIterable {
        case time = 1, duration, paused

        var name: String {
            switch self {
            case .time: return "time-pos"
            case .duration: return "duration"
            case .paused: return "pause"
            }
        }

        var format: mpv_format {
            switch self {
            case .time, .duration: return MPV_FORMAT_DOUBLE
            case .paused: return MPV_FORMAT_FLAG
            }
        }
    }

    public var onEvent: ((Event) -> Void)?
    private let handle: OpaquePointer
    private let wake: Unmanaged<WakeBox>

    /// Lets the wakeup callback (any thread) reach the player without keeping it alive.
    private final class WakeBox { weak var player: MpvPlayer? }

    /// A headless player: no video or audio output.
    public init() throws {
        // mpv requires the C numeric locale; AppKit may have set another one.
        setlocale(LC_NUMERIC, "C")
        guard let h = mpv_create() else { throw MpvError(code: MPV_ERROR_NOMEM.rawValue) }
        handle = h
        wake = Unmanaged.passRetained(WakeBox())
        wake.takeUnretainedValue().player = self
        // keep-open: at the end of a file mpv pauses on the last frame instead of unloading it, so position and
        // duration stay readable and no end-of-file event fires; the resume rule near the end relies on this.
        let options = [("vo", "null"), ("ao", "null"), ("hwdec", "auto-safe"), ("keep-open", "yes"), ("input-media-keys", "no")]
        for (name, value) in options { try Self.check(mpv_set_option_string(h, name, value)) }
        try Self.check(mpv_initialize(h))
        // mpv holds wakeup_lock while calling the callback, and setting it to nil takes the same lock,
        // so deinit cannot release `wake` under a running callback.
        mpv_set_wakeup_callback(h, { ctx in
            let box = Unmanaged<WakeBox>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { box.player?.drain() }
        }, wake.toOpaque())
        for observed in Observed.allCases {
            try Self.check(mpv_observe_property(h, observed.rawValue, observed.name, observed.format))
        }
    }

    deinit {
        mpv_set_wakeup_callback(handle, nil, nil)
        wake.release()
        mpv_terminate_destroy(handle)
    }

    public func load(_ url: URL) throws { try command(["loadfile", url.path]) }

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
            case MPV_EVENT_FILE_LOADED:
                onEvent?(.fileLoaded)
            case MPV_EVENT_END_FILE:
                let end = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR { onEvent?(.loadFailed(MpvError(code: end.error))) }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let observed = Observed(rawValue: event.reply_userdata) else {
                    preconditionFailure("property change with unknown tag \(event.reply_userdata)")
                }
                let p = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let data = p.data else { continue }
                switch observed {
                case .time: onEvent?(.time(data.assumingMemoryBound(to: Double.self).pointee))
                case .duration: onEvent?(.duration(data.assumingMemoryBound(to: Double.self).pointee))
                case .paused: onEvent?(.paused(data.assumingMemoryBound(to: Int32.self).pointee != 0))
                }
            default:
                break
            }
        }
    }
}

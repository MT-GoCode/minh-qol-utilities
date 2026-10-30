import CMpv
import Foundation

public struct MpvError: Error, CustomStringConvertible {
    public let code: Int32
    public var description: String { String(cString: mpv_error_string(code)) }
}

/// The only code that touches libmpv. Events are delivered on the main queue.
/// This initialiser creates a headless player (no video or audio output).
public final class MpvPlayer {
    public enum Event: Equatable {
        case fileLoaded
        case ended(failed: Bool)
        case time(Double)
        case duration(Double)
        case paused(Bool)
    }

    public var onEvent: ((Event) -> Void)?
    private var handle: OpaquePointer?
    private let wake: Unmanaged<WakeBox>

    /// Lets the wakeup callback (any thread) reach the player without keeping it alive.
    private final class WakeBox { weak var player: MpvPlayer? }

    public init() throws {
        guard let h = mpv_create() else { throw MpvError(code: MPV_ERROR_NOMEM.rawValue) }
        handle = h
        wake = Unmanaged.passRetained(WakeBox())
        wake.takeUnretainedValue().player = self
        let options = ["vo": "null", "ao": "null", "hwdec": "auto-safe", "keep-open": "yes", "input-media-keys": "no"]
        for (name, value) in options {
            let r = mpv_set_option_string(h, name, value)
            guard r >= 0 else { throw MpvError(code: r) }
        }
        let r = mpv_initialize(h)
        guard r >= 0 else { throw MpvError(code: r) }
        mpv_observe_property(h, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, "pause", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(h, { ctx in
            let box = Unmanaged<WakeBox>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { box.player?.drain() }
        }, wake.toOpaque())
    }

    deinit {
        mpv_set_wakeup_callback(handle, nil, nil)
        wake.release()
        mpv_terminate_destroy(handle)
    }

    public func load(_ url: URL) throws { try command(["loadfile", url.path]) }

    public func property(_ name: String) -> String? {
        guard let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    private func command(_ args: [String]) throws {
        var argv: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { argv.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
        let r = mpv_command(handle, &argv)
        guard r >= 0 else { throw MpvError(code: r) }
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
                onEvent?(.ended(failed: end.reason == MPV_END_FILE_REASON_ERROR))
            case MPV_EVENT_PROPERTY_CHANGE:
                let p = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let data = p.data else { continue }
                switch String(cString: p.name) {
                case "time-pos": onEvent?(.time(data.assumingMemoryBound(to: Double.self).pointee))
                case "duration": onEvent?(.duration(data.assumingMemoryBound(to: Double.self).pointee))
                case "pause": onEvent?(.paused(data.assumingMemoryBound(to: Int32.self).pointee != 0))
                default: break
                }
            default:
                break
            }
        }
    }
}

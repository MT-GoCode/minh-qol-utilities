import CMpv
import Foundation

public struct MpvError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public var description: String { String(cString: mpv_error_string(code)) }

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
}

/// The only code that touches libmpv. Create it and use it on the main thread; events arrive on the main queue.
public final class MpvPlayer {
    public enum Event: Equatable {
        case fileLoaded
        case loadFailed(MpvError)
        /// Playback (re)started: a seek has landed.
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

    /// mpv's documented limits for `speed`; the volume range is this app's decision (no boost above 100).
    private static let speedRange = 0.01...100.0
    private static let volumeRange = 0.0...100.0

    public var onEvent: ((Event) -> Void)?
    private let handle: OpaquePointer
    private let wake: Unmanaged<WakeBox>

    /// Lets the wakeup callback (any thread) reach the player without keeping it alive.
    private final class WakeBox { weak var player: MpvPlayer? }

    /// A headless player: no video or audio output.
    public init() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        // mpv requires the C numeric locale; AppKit may have set another one.
        setlocale(LC_NUMERIC, "C")
        guard let h = mpv_create() else { throw MpvError(code: MPV_ERROR_NOMEM.rawValue) }
        handle = h
        wake = Unmanaged.passRetained(WakeBox())
        wake.takeUnretainedValue().player = self
        // keep-open: at the end of a file mpv pauses on the last frame instead of unloading it, so position and
        // duration stay readable and MPV_EVENT_END_FILE does not fire (the `endOfFile` property event does); the resume rule near the end relies on this.
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

    // MARK: Playback

    public func load(_ url: URL) throws {
        precondition(url.isFileURL, "only file URLs can be loaded")
        try command(["loadfile", url.path])
    }

    public func setPaused(_ paused: Bool) throws { try set("pause", paused ? "yes" : "no") }

    /// Relative seek, frame-exact (`exact`): the pause state is left as it was.
    public func seek(by seconds: Double) throws { try command(["seek", String(seconds), "relative+exact"]) }

    public func seek(toFraction fraction: Double) throws { try command(["seek", String(fraction * 100), "absolute-percent+exact"]) }

    /// Steps `count` frames forward, or back when negative.
    public func frameStep(_ count: Int) throws {
        for _ in 0..<abs(count) { try command([count > 0 ? "frame-step" : "frame-back-step"]) }
    }

    public func toggleMute() throws { try command(["cycle", "mute"]) }

    // MARK: Speed and volume

    public func speed() throws -> Double { try number("speed") }
    public func volume() throws -> Double { try number("volume") }

    public func setSpeed(_ speed: Double) throws { try set("speed", String(speed)) }
    public func setVolume(_ volume: Double) throws { try set("volume", String(volume)) }

    /// Adds `delta`, rounded to 2 decimals so repeated 0.1 steps stay exact, and clamps to mpv's limits.
    public func adjustSpeed(by delta: Double) throws {
        let target = ((try speed() + delta) * 100).rounded() / 100
        try setSpeed(min(max(target, Self.speedRange.lowerBound), Self.speedRange.upperBound))
    }

    public func adjustVolume(by delta: Double) throws {
        try setVolume(min(max(try volume() + delta, Self.volumeRange.lowerBound), Self.volumeRange.upperBound))
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

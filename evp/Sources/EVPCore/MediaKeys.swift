/// The media keys on a Mac keyboard (F7, F8, F9), as the system names them.
public enum MediaKey: Equatable {
    case previous, playPause, next

    /// The code of the system key event (`NX_KEYTYPE_*`): play 16, next 17, previous 18, fast 19, rewind 20. Holding F7 or
    /// F9 sends rewind and fast, and a tap sends previous and next, depending on the route; both mean the same here.
    public init?(systemKeyType code: Int) {
        switch code {
        case 16: self = .playPause
        case 17, 19: self = .next
        case 18, 20: self = .previous
        default: return nil
        }
    }
}

/// Whether EVP takes a media key, and what it does with it. It remembers the keys it took on key-down, so the matching
/// key-up is taken too even if the decision would now differ (F8 pausing the only playing video).
public struct MediaKeyRouter {
    public enum Decision: Equatable {
        /// Leave the key to whatever else wants it.
        case pass
        /// EVP takes the key. `action` is nil for the key-up of a key EVP took on key-down.
        case consume(Action?)
    }

    private var taken: Set<MediaKey> = []

    public init() {}

    /// With decoupling on, EVP never touches the keys. With it off, EVP takes them while a video is open, playing or
    /// paused (F8 must resume what it paused): F8 plays and pauses, F7 and F9 seek by the long step. With no video open
    /// the keys stay with the music app.
    public mutating func decide(_ key: MediaKey, isKeyDown: Bool, decoupled: Bool, videoOpen: Bool) -> Decision {
        guard isKeyDown else { return taken.remove(key) == nil ? .pass : .consume(nil) }
        guard !decoupled, videoOpen else { return .pass }
        taken.insert(key)
        switch key {
        case .playPause: return .consume(.playPause)
        case .previous: return .consume(.seekBackLong)
        case .next: return .consume(.seekForwardLong)
        }
    }
}

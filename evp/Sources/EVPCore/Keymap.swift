import Foundation

/// Which chord triggers which action. At most one chord per action and one action per chord.
public struct Keymap: Equatable {
    public struct Conflict: Error, Equatable {
        public let chord: KeyChord
        public let existing: Action
    }

    public private(set) var chords: [Action: KeyChord]

    /// Minh's keys. `screenshot` has no default key.
    public static let defaults: Keymap = {
        let table: [(Action, String)] = [
            (.playPause, "space"), (.seekBackShort, "left"), (.seekForwardShort, "right"), (.seekBackLong, "j"),
            (.seekForwardLong, "l"), (.speedUp, "d"), (.speedDown, "s"), (.volumeUp, "up"), (.volumeDown, "down"),
            (.jump0, "0"), (.jump1, "1"), (.jump2, "2"), (.jump3, "3"), (.jump4, "4"), (.jump5, "5"), (.jump6, "6"),
            (.jump7, "7"), (.jump8, "8"), (.jump9, "9"), (.frameBack, ","), (.frameForward, "."), (.mute, "m"),
            (.fullscreen, "f"), (.toggleBar, "tab"), (.pauseAll, "ctrl+space"),
        ]
        var keymap = Keymap(chords: [:])
        for (action, text) in table { try! keymap.bind(KeyChord(text)!, to: action) }
        return keymap
    }()

    private init(chords: [Action: KeyChord]) { self.chords = chords }

    public func action(for chord: KeyChord) -> Action? { chords.first { $0.value == chord }?.key }

    /// Binds `chord` to `action`, replacing the action's previous chord. Throws, and changes nothing, when the
    /// chord already belongs to another action.
    public mutating func bind(_ chord: KeyChord, to action: Action) throws {
        if let existing = self.action(for: chord), existing != action { throw Conflict(chord: chord, existing: existing) }
        chords[action] = chord
    }

    public mutating func unbind(_ action: Action) { chords[action] = nil }

    /// Puts `action` back on its default chord (or off, if it has none). Throws, and changes nothing, when another
    /// action has taken that chord since.
    public mutating func reset(_ action: Action) throws {
        guard let chord = Keymap.defaults.chords[action] else { return unbind(action) }
        try bind(chord, to: action)
    }

    /// Every action back on its default chord.
    public mutating func resetAll() { self = Keymap.defaults }
}

/// Stored as one entry per action, `null` meaning the user unbound it. An action missing from the file (added by a
/// newer version) takes its default chord unless another action already holds it; names of removed actions are ignored.
extension Keymap: Codable {
    public init(from decoder: Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([String: KeyChord?].self)
        self.init(chords: [:])
        for (name, chord) in stored {
            guard let action = Action(rawValue: name), let chord else { continue }
            do { try bind(chord, to: action) } catch let conflict as Conflict {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(chord) bound to \(action) and \(conflict.existing)"))
            }
        }
        for action in Action.allCases where stored[action.rawValue] == nil {
            if let chord = Keymap.defaults.chords[action], self.action(for: chord) == nil { chords[action] = chord }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, chords[$0]) }))
    }
}

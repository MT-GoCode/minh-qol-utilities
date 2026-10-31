import Foundation

public struct Modifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1)
    public static let option = Modifiers(rawValue: 2)
    public static let shift = Modifiers(rawValue: 4)
    public static let command = Modifiers(rawValue: 8)
}

/// A key plus modifiers, written like `ctrl+space` or `shift+right`. Keys are lowercase single characters
/// (not `+`) or one of the named keys; the same notation the test driver uses.
public struct KeyChord: Hashable, Codable, CustomStringConvertible {
    public static let namedKeys: Set<String> = ["space", "tab", "left", "right", "up", "down", "return", "escape", "delete"]
    /// Display and storage order of modifiers.
    private static let modifierNames: [(String, Modifiers)] = [("ctrl", .control), ("alt", .option), ("shift", .shift), ("cmd", .command)]

    public let key: String
    public let modifiers: Modifiers

    public init?(key: String, modifiers: Modifiers = []) {
        let isCharacter = key.count == 1 && key != "+" && key == key.lowercased()
            && key.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
        guard isCharacter || Self.namedKeys.contains(key) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    public init?(_ text: String) {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var modifiers = Modifiers()
        for name in tokens.dropLast() {
            guard let modifier = Self.modifierNames.first(where: { $0.0 == name })?.1, !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        guard let key = tokens.last else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    /// The Mac virtual key codes of the named keys; every other key is named by the character it types.
    private static let namedKeyCodes: [UInt16: String] = [
        49: "space", 48: "tab", 123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 53: "escape", 51: "delete",
    ]

    /// US-layout virtual key codes of the character keys, for registering a chord with the system.
    private static let characterKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// The Mac virtual key code that types this chord's key; nil for a key this table does not know.
    public var virtualKeyCode: UInt16? {
        Self.namedKeyCodes.first { $0.value == key }?.key ?? Self.characterKeyCodes[key]
    }

    /// The chord for a key press: `characters` is what the key types without command or control (letters arrive
    /// lowercased, the `shift` modifier records the case). A shifted symbol or digit keeps its shifted character, so
    /// shift plus `,` is the chord `shift+<`. nil for keys that have no chord.
    public static func chord(keyCode: UInt16, characters: String, modifiers: Modifiers) -> KeyChord? {
        KeyChord(key: namedKeyCodes[keyCode] ?? characters.lowercased(), modifiers: modifiers)
    }

    public var description: String {
        (Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0) + [key]).joined(separator: "+")
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid key chord \(text)"))
        }
        self = chord
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

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

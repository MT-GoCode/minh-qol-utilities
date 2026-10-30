import EVPCore
import XCTest

final class UnitKeymapTests: XCTestCase {
    func testDefaultsAreExactlyMinhsKeys() {
        // From NORTH-STAR.md: space; left/right and J/L; d/s; up/down; 0-9; comma/period; m; f; tab; ctrl+space.
        let expected: [Action: String] = [
            .playPause: "space", .seekBackShort: "left", .seekForwardShort: "right", .seekBackLong: "j", .seekForwardLong: "l",
            .speedUp: "d", .speedDown: "s", .volumeUp: "up", .volumeDown: "down",
            .jump0: "0", .jump1: "1", .jump2: "2", .jump3: "3", .jump4: "4", .jump5: "5", .jump6: "6", .jump7: "7", .jump8: "8", .jump9: "9",
            .frameBack: ",", .frameForward: ".", .mute: "m", .fullscreen: "f", .toggleBar: "tab", .pauseAll: "ctrl+space",
        ]
        XCTAssertEqual(Keymap.defaults.chords.mapValues(\.description), expected)
        XCTAssertNil(Keymap.defaults.chords[.screenshot])
    }

    func testChordParsingAndCanonicalForm() {
        XCTAssertEqual(KeyChord("shift+ctrl+j")?.description, "ctrl+shift+j")
        XCTAssertEqual(KeyChord("cmd+alt+shift+ctrl+space")?.description, "ctrl+alt+shift+cmd+space")
        XCTAssertEqual(KeyChord(",")?.key, ",")
        for text in ["", "ctrl+", "+", "J", "ctrl+J", "ctrl+ctrl+j", "meta+j", "enter", "jj", "ctrl++"] {
            XCTAssertNil(KeyChord(text), text)
        }
    }

    func testConflictNamesTheOwnerAndChangesNothing() throws {
        var keymap = Keymap.defaults
        let space = try XCTUnwrap(KeyChord("space"))
        XCTAssertThrowsError(try keymap.bind(space, to: .mute)) { error in
            let conflict = error as? Keymap.Conflict
            XCTAssertEqual(conflict?.existing, .playPause)
            XCTAssertEqual(conflict?.chord, space)
        }
        XCTAssertEqual(keymap, Keymap.defaults)
    }

    func testRebindReplacesAndFreesTheOldChord() throws {
        var keymap = Keymap.defaults
        try keymap.bind(try XCTUnwrap(KeyChord("e")), to: .speedUp)
        XCTAssertEqual(keymap.action(for: try XCTUnwrap(KeyChord("e"))), .speedUp)
        XCTAssertNil(keymap.action(for: try XCTUnwrap(KeyChord("d"))))
        try keymap.bind(try XCTUnwrap(KeyChord("e")), to: .speedUp)  // rebinding to its own chord is not a conflict
    }

    func testJsonRoundTrip() throws {
        var keymap = Keymap.defaults
        keymap.unbind(.mute)
        try keymap.bind(try XCTUnwrap(KeyChord("shift+right")), to: .seekForwardLong)
        let decoded = try JSONDecoder().decode(Keymap.self, from: JSONEncoder().encode(keymap))
        XCTAssertEqual(decoded, keymap)
    }

    func testCorruptKeymapJsonIsRejected() {
        let unknownAction = Data(#"{"fly":"f"}"#.utf8)
        let twoActionsOneChord = Data(#"{"mute":"m","fullscreen":"m"}"#.utf8)
        let badChord = Data(#"{"mute":"M"}"#.utf8)
        for data in [unknownAction, twoActionsOneChord, badChord] {
            XCTAssertThrowsError(try JSONDecoder().decode(Keymap.self, from: data), String(decoding: data, as: UTF8.self))
        }
    }

    func testJumpFractionsAndGlobalActions() {
        XCTAssertEqual(Action.allCases.compactMap(\.jumpFraction), [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
        XCTAssertEqual(Action.global, [.pauseAll])
    }
}

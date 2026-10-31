import EVPCore
import XCTest

final class UnitKeyChordTests: XCTestCase {
    private func chord(_ keyCode: UInt16, _ characters: String, _ modifiers: Modifiers = []) -> String? {
        KeyChord.chord(keyCode: keyCode, characters: characters, modifiers: modifiers)?.description
    }

    func testKeyPressesBecomeTheChordsOfMinhsKeys() {
        // Virtual key codes and typed characters of a US keyboard.
        XCTAssertEqual(chord(49, " "), "space")
        XCTAssertEqual(chord(123, "\u{F702}"), "left")
        XCTAssertEqual(chord(124, "\u{F703}"), "right")
        XCTAssertEqual(chord(125, "\u{F701}"), "down")
        XCTAssertEqual(chord(126, "\u{F700}"), "up")
        XCTAssertEqual(chord(38, "j"), "j")
        XCTAssertEqual(chord(37, "l"), "l")
        XCTAssertEqual(chord(2, "d"), "d")
        XCTAssertEqual(chord(1, "s"), "s")
        XCTAssertEqual(chord(29, "0"), "0")
        XCTAssertEqual(chord(25, "9"), "9")
        XCTAssertEqual(chord(43, ","), ",")
        XCTAssertEqual(chord(47, "."), ".")
        XCTAssertEqual(chord(46, "m"), "m")
        XCTAssertEqual(chord(3, "f"), "f")
        XCTAssertEqual(chord(48, "\t"), "tab")
        XCTAssertEqual(chord(49, " ", .control), "ctrl+space")
    }

    func testEveryDefaultBindingIsReachableFromARealKeyPress() {
        let presses: [String: (UInt16, String)] = [
            "space": (49, " "), "left": (123, ""), "right": (124, ""), "j": (38, "j"), "l": (37, "l"), "d": (2, "d"), "s": (1, "s"),
            "up": (126, ""), "down": (125, ""), "0": (29, "0"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"),
            "5": (23, "5"), "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"), ",": (43, ","), ".": (47, "."),
            "m": (46, "m"), "f": (3, "f"), "tab": (48, "\t"),
        ]
        for (action, key) in Keymap.defaults.chords where !Action.global.contains(action) {
            let (code, characters) = presses[key.description] ?? (0, "?")
            XCTAssertEqual(KeyChord.chord(keyCode: code, characters: characters, modifiers: key.modifiers), key, "\(action)")
        }
    }

    func testShiftOnlyChangesTheCaseNotTheChord() {
        XCTAssertEqual(chord(37, "L", .shift), "shift+l")
        XCTAssertEqual(chord(124, "", .shift), "shift+right")
        XCTAssertEqual(chord(43, "<", .shift), "shift+<", "a shifted symbol is the shifted character")
    }

    func testKeysWithoutAChordAreNil() {
        XCTAssertNil(chord(122, ""))        // a function key types nothing
        XCTAssertNil(chord(0, "ab"))        // more than one character
    }

    func testAHeldKeyRepeatsOnlyThoseActionsAndEveryFirstPressRuns() {
        for action in Action.allCases {
            XCTAssertTrue(action.runs(onRepeat: false), "\(action) first press")
            XCTAssertEqual(action.runs(onRepeat: true), action.repeatsWhenHeld, "\(action) repeat")
        }
        XCTAssertFalse(Action.playPause.runs(onRepeat: true))
        XCTAssertFalse(Action.fullscreen.runs(onRepeat: true))
        XCTAssertTrue(Action.volumeDown.runs(onRepeat: true))
        XCTAssertTrue(Action.seekForwardShort.runs(onRepeat: true))
    }

    func testOnlySeekVolumeSpeedAndFrameKeysRepeatWhenHeld() {
        let repeating = Action.allCases.filter(\.repeatsWhenHeld)
        XCTAssertEqual(Set(repeating), [.seekBackShort, .seekForwardShort, .seekBackLong, .seekForwardLong, .volumeUp, .volumeDown,
                                        .speedUp, .speedDown, .frameBack, .frameForward])
    }

    func testVirtualKeyCodesMatchTheKeysOfAMacKeyboard() throws {
        let known: [(String, UInt16)] = [("space", 49), ("ctrl+space", 49), ("a", 0), ("m", 46), (",", 43), ("/", 44), ("left", 123), ("tab", 48), ("5", 23)]
        for (text, code) in known { XCTAssertEqual(KeyChord(text)?.virtualKeyCode, code, text) }
        XCTAssertNil(KeyChord(key: "é")?.virtualKeyCode, "a key outside the US table has no code")
    }

    func testEveryKeyThatHasACodeComesBackAsItself() throws {
        for key in KeyChord.namedKeys.union(Set("abcdefghijklmnopqrstuvwxyz0123456789,./;'[]-=`\\".map(String.init))) {
            let chord = try XCTUnwrap(KeyChord(key: key))
            let code = try XCTUnwrap(chord.virtualKeyCode, key)
            let named = KeyChord.namedKeys.contains(key)
            XCTAssertEqual(KeyChord.chord(keyCode: code, characters: named ? "" : key, modifiers: []), chord, "\(key) via code \(code)")
        }
    }
}

import EVPCore
import XCTest

final class UnitSettingsTests: XCTestCase {
    func testTheDefaultsAreUsable() {
        XCTAssertEqual(Settings().problems(), [])
    }

    func testEachBadValueIsNamedOnce() {
        var settings = Settings()
        settings.seekShortSeconds = 0
        settings.seekLongSeconds = -2
        settings.speedStep = 0
        settings.volumeStep = 500
        settings.defaultSpeed = 0
        settings.defaultVolume = 500
        XCTAssertEqual(settings.problems().count, 6)
        for word in ["short seek", "long seek", "speed step", "volume step", "default speed", "default volume"] {
            XCTAssertEqual(settings.problems().filter { $0.lowercased().contains(word) }.count, 1, word)
        }
    }

    func testNotANumberAndTheEdgesOfTheRanges() {
        var settings = Settings()
        settings.seekShortSeconds = .nan
        XCTAssertEqual(settings.problems().count, 1)
        settings = Settings()
        (settings.defaultSpeed, settings.defaultVolume, settings.volumeStep) = (0.01, 0, 100)
        XCTAssertEqual(settings.problems(), [], "the limits themselves are valid")
        (settings.defaultSpeed, settings.defaultVolume) = (100.5, 100.5)
        XCTAssertEqual(settings.problems().count, 2)
    }

    func testTheGlobalKeyNeedsAModifierThatIsNotShift() throws {
        var settings = Settings()
        for (chord, ok) in [("ctrl+space", true), ("alt+p", true), ("cmd+shift+p", true), ("a", false), ("shift+a", false)] {
            settings.keymap.unbind(.pauseAll)
            try settings.keymap.bind(try XCTUnwrap(KeyChord(chord)), to: .pauseAll)
            XCTAssertEqual(settings.problems().isEmpty, ok, chord)
        }
        settings.keymap.unbind(.pauseAll)
        XCTAssertEqual(settings.problems(), [], "no global key at all is allowed")
    }
}

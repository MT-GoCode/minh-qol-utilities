import EVPCore
import XCTest

/// The global pause key over real players of real media.
final class IntegrationPauseAllTests: XCTestCase {
    private func playing(_ name: String = "t.mp4") throws -> Session { try Session(loading: name) }

    private func isPaused(_ session: Session) throws -> Bool { try session.player.isPaused() }

    func testItPausesWhatPlaysAndResumesExactlyThose() throws {
        let (a, b, byHand) = (try playing(), try playing("tv.mp4"), try playing())
        try byHand.player.setPaused(true)
        try byHand.waitFor(.paused(true))
        let pauseAll = PauseAll()
        let players: [Pausable] = [a.player, b.player, byHand.player]

        try pauseAll.press(over: players)
        XCTAssertEqual([try isPaused(a), try isPaused(b), try isPaused(byHand)], [true, true, true])

        try pauseAll.press(over: players)
        XCTAssertEqual([try isPaused(a), try isPaused(b)], [false, false], "the two it paused play again")
        XCTAssertTrue(try isPaused(byHand), "the one the user paused by hand stays paused")

        try pauseAll.press(over: players)
        XCTAssertEqual([try isPaused(a), try isPaused(b)], [true, true], "a third press pauses again: the key is a toggle")
        try pauseAll.press(over: players)
        XCTAssertEqual([try isPaused(a), try isPaused(b)], [false, false])
    }

    func testAVideoOpenedWhileEverythingWasPausedIsNotTouched() throws {
        let a = try playing()
        let pauseAll = PauseAll()
        try pauseAll.press(over: [a.player])
        let late = try playing("tv.mp4")
        try pauseAll.press(over: [a.player, late.player])
        XCTAssertFalse(try isPaused(a))
        XCTAssertFalse(try isPaused(late), "a video that was not paused by the key is left alone")
    }

    func testNothingPlayingAndNothingRememberedDoesNothing() throws {
        let a = try playing()
        try a.player.setPaused(true)
        try a.waitFor(.paused(true))
        try PauseAll().press(over: [a.player])
        XCTAssertTrue(try isPaused(a))
        try PauseAll().press(over: [])
    }

    func testAWindowClosedWhilePausedIsSkipped() throws {
        let pauseAll = PauseAll()
        var closing: Session? = try playing()
        let staying = try playing("tv.mp4")
        try pauseAll.press(over: [closing!.player, staying.player])
        closing = nil
        try pauseAll.press(over: [staying.player])
        XCTAssertFalse(try isPaused(staying))
    }

    func testAFailedResumeKeepsTheWholeSetSoTheNextPressRetries() throws {
        struct Refusal: Error {}
        final class Flaky: Pausable {
            var paused = false
            var refuses = false
            func isPaused() throws -> Bool { paused }
            func setPaused(_ value: Bool) throws {
                if refuses && !value { throw Refusal() }
                paused = value
            }
        }
        let (first, second) = (Flaky(), Flaky())
        let pauseAll = PauseAll()
        try pauseAll.press(over: [first, second])
        second.refuses = true
        XCTAssertThrowsError(try pauseAll.press(over: [first, second]))
        second.refuses = false
        try pauseAll.press(over: [first, second])
        XCTAssertEqual([first.paused, second.paused], [false, false], "the retry resumed both, nothing was forgotten")
    }

    func testIfTheUserResumedEverythingByHandTheNextPressPausesAgain() throws {
        final class Fake: Pausable {
            var paused = false
            func isPaused() throws -> Bool { paused }
            func setPaused(_ value: Bool) throws { paused = value }
        }
        let (first, second) = (Fake(), Fake())
        let pauseAll = PauseAll()
        try pauseAll.press(over: [first, second])
        first.paused = false
        second.paused = false
        try pauseAll.press(over: [first, second])
        XCTAssertEqual([first.paused, second.paused], [true, true], "the key is not dead after a hand resume")
        try pauseAll.press(over: [first, second])
        XCTAssertEqual([first.paused, second.paused], [false, false])
    }

    func testOnlyTheRememberedVideosStillPausedAreResumed() throws {
        final class Fake: Pausable {
            var paused = false
            func isPaused() throws -> Bool { paused }
            func setPaused(_ value: Bool) throws { paused = value }
        }
        let (first, second) = (Fake(), Fake())
        let pauseAll = PauseAll()
        try pauseAll.press(over: [first, second])
        first.paused = false
        try pauseAll.press(over: [first, second])
        XCTAssertEqual([first.paused, second.paused], [false, false], "second is resumed, first was already playing and stays so")
    }
}

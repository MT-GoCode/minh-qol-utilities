import EVPCore
import XCTest

/// The engine's command surface against real libmpv and real media (fixtures are 20 s, 30 fps).
final class IntegrationPlayerTests: XCTestCase {
    func testPauseTransitionsAreReportedAndReadBack() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        try s.waitFor(.paused(true))
        XCTAssertEqual(try s.player.property("pause"), "yes")
        let mark = s.events.count
        try s.player.setPaused(false)
        try s.waitFor(.paused(false), after: mark)
        XCTAssertEqual(try s.player.property("pause"), "no")
    }

    func testRelativeSeekLandsExactlyAndKeepsPaused() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        try s.waitFor(.paused(true))
        try s.player.seek(by: 5)
        try s.waitForPosition(near: 5, within: 0.1)
        try s.player.seek(by: -2)
        try s.waitForPosition(near: 3, within: 0.1)
        XCTAssertEqual(try s.player.property("pause"), "yes")
    }

    func testRelativeSeekWhilePlayingKeepsPlaying() throws {
        let s = try Session(loading: "t.mp4")
        let mark = s.events.count
        try s.player.seek(by: 10)
        try s.waitFor(.playbackRestart, after: mark)
        XCTAssertGreaterThanOrEqual(try s.position(), 10)
        XCTAssertEqual(try s.player.property("pause"), "no")
    }

    func testRapidSeeksLikeAHeldKeyAllLand() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        try s.player.seek(toFraction: 0.95)
        try s.waitForPosition(near: 19, within: 0.1)
        for _ in 0..<10 { try s.player.seek(by: -1) }
        try s.waitForPosition(near: 9, within: 0.1)
    }

    func testJumpToFraction() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        try s.player.seek(toFraction: 0.5)
        try s.waitForPosition(near: 10, within: 0.1)
    }

    func testSpeedStepsStayExactAndClampToMpvLimits() throws {
        let s = try Session()
        for _ in 0..<3 { try s.player.adjustSpeed(by: 0.1) }
        XCTAssertEqual(try s.player.speed(), 1.3)
        try s.player.adjustSpeed(by: -100)
        XCTAssertEqual(try s.player.speed(), 0.01)
        try s.player.adjustSpeed(by: 1000)
        XCTAssertEqual(try s.player.speed(), 100)
    }

    func testVolumeClampsToZeroAndOneHundred() throws {
        let s = try Session()
        try s.player.setVolume(98)
        try s.player.adjustVolume(by: 5)
        XCTAssertEqual(try s.player.volume(), 100)
        try s.player.adjustVolume(by: -500)
        XCTAssertEqual(try s.player.volume(), 0)
    }

    func testMuteToggles() throws {
        let s = try Session()
        try s.player.toggleMute()
        try s.waitFor(.muted(true))
        let mark = s.events.count
        try s.player.toggleMute()
        try s.waitFor(.muted(false), after: mark)
    }

    func testFrameStepMovesExactlyOneFrame() throws {
        let s = try Session(loading: "t.mp4")
        try s.player.setPaused(true)
        let mark = s.events.count
        try s.player.seek(by: 5)
        try s.waitFor(.playbackRestart, after: mark)  // a step issued before the seek has landed is dropped
        try s.waitForPosition(near: 5, within: 0.01)
        try s.player.frameStep(1)
        try s.waitForPosition(near: 5 + 1.0 / 30, within: 0.01)
        try s.player.frameStep(-1)
        try s.waitForPosition(near: 5, within: 0.01)
    }

    func testTrackListAndSelection() throws {
        let s = try Session(loading: "t2.mkv")
        let audio = try s.player.tracks().filter { $0.kind == .audio }
        XCTAssertEqual(audio.map(\.id), [1, 2])
        XCTAssertEqual(audio.map(\.selected), [true, false])
        try s.player.select(.audio, id: 2)
        XCTAssertEqual(try s.player.property("aid"), "2")
        XCTAssertEqual(try s.player.tracks().filter { $0.kind == .audio }.map(\.selected), [false, true])
    }
}

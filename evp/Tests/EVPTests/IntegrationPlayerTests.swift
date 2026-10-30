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

    func testLoadingAtAStartPositionBeginsThere() throws {
        let s = try Session(loading: "t.mp4", start: 7)
        try s.waitForPosition(near: 7, within: 0.5)
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

    func testEachObservedPropertyReportsItsOwnValue() throws {
        let s = try Session(loading: "t.mp4")
        try s.until("duration reported as 20 s") { s.events.contains { if case .duration(let d) = $0 { return abs(d - 20) < 0.1 } else { return false } } }
        try s.until("time advancing past 1 s") { s.events.contains { if case .time(let t) = $0 { return t > 1 } else { return false } } }
        try s.player.setSpeed(1.3)
        try s.waitFor(.speed(1.3))
        try s.player.setVolume(60)
        try s.waitFor(.volume(60))
        try s.waitFor(.endOfFile(false))  // mpv reports the initial value first; only a later true is the real end
        let mark = s.events.count
        try s.player.seek(toFraction: 0.99)
        try s.waitFor(.endOfFile(true), after: mark)
    }

    func testCommandsActAndReportFeedbackUsingTheSettings() throws {
        var settings = Settings()
        settings.seekShortSeconds = 3
        settings.seekLongSeconds = 7
        let s = try Session(loading: "t.mp4")
        let player = s.player
        XCTAssertEqual(try player.perform(.action(.playPause), settings: settings), .done(feedback: "Paused"))
        XCTAssertEqual(try player.property("pause"), "yes")
        XCTAssertEqual(try player.perform(.action(.seekForwardLong), settings: settings), .done(feedback: "+7s"))
        try s.waitForPosition(near: 7, within: 0.2)
        XCTAssertEqual(try player.perform(.action(.seekBackShort), settings: settings), .done(feedback: "-3s"))
        try s.waitForPosition(near: 4, within: 0.2)
        XCTAssertEqual(try player.perform(.action(.seekForwardShort), settings: settings), .done(feedback: "+3s"))
        try s.waitForPosition(near: 7, within: 0.2)
        XCTAssertEqual(try player.perform(.action(.seekBackLong), settings: settings), .done(feedback: "-7s"))
        try s.waitForPosition(near: 0, within: 0.2)
        XCTAssertEqual(try player.perform(.action(.jump5), settings: settings), .done(feedback: "50%"))
        try s.waitForPosition(near: 10, within: 0.2)
        XCTAssertEqual(try player.perform(.seekFraction(0.25), settings: settings), .done(feedback: nil))
        try s.waitForPosition(near: 5, within: 0.2)
        for _ in 0..<2 { _ = try player.perform(.action(.speedUp), settings: settings) }
        XCTAssertEqual(try player.perform(.action(.speedUp), settings: settings), .done(feedback: "Speed 1.3x"))
        XCTAssertEqual(try player.perform(.action(.speedReset), settings: settings), .done(feedback: "Speed 1x"))
        XCTAssertEqual(try player.perform(.action(.volumeDown), settings: settings), .done(feedback: "Volume 95%"))
        XCTAssertEqual(try player.perform(.setVolume(40), settings: settings), .done(feedback: nil))
        XCTAssertEqual(try player.volume(), 40)
        XCTAssertEqual(try player.perform(.action(.mute), settings: settings), .done(feedback: "Muted"))
        XCTAssertEqual(try player.perform(.action(.mute), settings: settings), .done(feedback: "Unmuted"))
        XCTAssertEqual(try player.perform(.action(.playPause), settings: settings), .done(feedback: "Playing"))
        for interfaceAction in [Action.fullscreen, .toggleBar, .screenshot, .pauseAll] {
            XCTAssertEqual(try player.perform(.action(interfaceAction), settings: settings), .notAnEngineCommand, "\(interfaceAction)")
        }
    }

    func testTrackListAndSelection() throws {
        let s = try Session(loading: "t2.mkv")
        let audio = try s.player.tracks().filter { $0.kind == .audio }
        XCTAssertEqual(audio.map(\.id), [1, 2])
        XCTAssertEqual(audio.map(\.selected), [true, false])
        XCTAssertEqual(audio.map(\.language), ["eng", "fra"])
        try s.player.select(.audio, id: 2)
        XCTAssertEqual(try s.player.property("aid"), "2")
        XCTAssertEqual(try s.player.tracks().filter { $0.kind == .audio }.map(\.selected), [false, true])
    }
}

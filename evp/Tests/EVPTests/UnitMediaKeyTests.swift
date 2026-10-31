import EVPCore
import XCTest

final class UnitMediaKeyTests: XCTestCase {
    private let all: [MediaKey] = [.previous, .playPause, .next]

    func testSystemKeyCodesMapToTheThreeKeys() {
        let table: [(Int, MediaKey?)] = [(16, .playPause), (17, .next), (19, .next), (18, .previous), (20, .previous), (0, nil), (21, nil), (-1, nil)]
        for (code, key) in table { XCTAssertEqual(MediaKey(systemKeyType: code), key, "code \(code)") }
    }

    func testCoupledAndPlayingEvpTakesTheKeys() {
        let cases: [(MediaKey, Action)] = [(.playPause, .playPause), (.previous, .seekBackLong), (.next, .seekForwardLong)]
        for (key, action) in cases {
            var router = MediaKeyRouter()
            XCTAssertEqual(router.decide(key, isKeyDown: true, decoupled: false, anythingPlaying: true), .consume(action), "\(key)")
            XCTAssertEqual(router.decide(key, isKeyDown: false, decoupled: false, anythingPlaying: true), .consume(nil), "\(key) up is taken without acting")
        }
    }

    func testTheKeyUpFollowsTheKeyDownEvenWhenNothingPlaysAnymore() {
        var router = MediaKeyRouter()
        XCTAssertEqual(router.decide(.playPause, isKeyDown: true, decoupled: false, anythingPlaying: true), .consume(.playPause))
        XCTAssertEqual(router.decide(.playPause, isKeyDown: false, decoupled: false, anythingPlaying: false), .consume(nil), "F8 just paused the only video")
        XCTAssertEqual(router.decide(.playPause, isKeyDown: false, decoupled: false, anythingPlaying: false), .pass, "a stray second key-up is not ours")
    }

    func testTheKeyUpOfAKeyEvpPassedIsPassedEvenIfSomethingPlaysNow() {
        var router = MediaKeyRouter()
        XCTAssertEqual(router.decide(.next, isKeyDown: true, decoupled: false, anythingPlaying: false), .pass)
        XCTAssertEqual(router.decide(.next, isKeyDown: false, decoupled: false, anythingPlaying: true), .pass, "the music app saw the key-down, so it must see the key-up")
    }

    func testDecoupledEvpNeverTakesAKey() {
        for key in all {
            for down in [true, false] {
                var router = MediaKeyRouter()
                XCTAssertEqual(router.decide(key, isKeyDown: down, decoupled: true, anythingPlaying: true), .pass)
                XCTAssertEqual(router.decide(key, isKeyDown: down, decoupled: true, anythingPlaying: false), .pass)
            }
        }
    }

    func testAnIdleEvpLeavesTheKeysToTheMusicApp() {
        for key in all {
            var router = MediaKeyRouter()
            XCTAssertEqual(router.decide(key, isKeyDown: true, decoupled: false, anythingPlaying: false), .pass)
        }
    }
}

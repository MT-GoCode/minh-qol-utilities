import EVPCore
import XCTest

final class UnitMediaKeyTests: XCTestCase {
    func testSystemKeyCodesMapToTheThreeKeys() {
        let table: [(Int, MediaKey?)] = [(16, .playPause), (17, .next), (19, .next), (18, .previous), (20, .previous), (0, nil), (21, nil), (-1, nil)]
        for (code, key) in table { XCTAssertEqual(MediaKey(systemKeyType: code), key, "code \(code)") }
    }

    func testCoupledAndPlayingEvpTakesTheKeys() {
        let cases: [(MediaKey, Action)] = [(.playPause, .playPause), (.previous, .seekBackLong), (.next, .seekForwardLong)]
        for (key, action) in cases {
            XCTAssertEqual(MediaKeyRouting.decide(key, isKeyDown: true, decoupled: false, anythingPlaying: true), .consume(action), "\(key)")
            XCTAssertEqual(MediaKeyRouting.decide(key, isKeyDown: false, decoupled: false, anythingPlaying: true), .consume(nil), "\(key) up is taken without acting")
        }
    }

    func testDecoupledEvpNeverTakesAKey() {
        for key in [MediaKey.previous, .playPause, .next] {
            for down in [true, false] {
                XCTAssertEqual(MediaKeyRouting.decide(key, isKeyDown: down, decoupled: true, anythingPlaying: true), .pass)
                XCTAssertEqual(MediaKeyRouting.decide(key, isKeyDown: down, decoupled: true, anythingPlaying: false), .pass)
            }
        }
    }

    func testAnIdleEvpLeavesTheKeysToTheMusicApp() {
        for key in [MediaKey.previous, .playPause, .next] {
            XCTAssertEqual(MediaKeyRouting.decide(key, isKeyDown: true, decoupled: false, anythingPlaying: false), .pass)
        }
    }
}

import XCTest
@testable import DemonlockCore

/// The valve lifecycle decision is the brick-critical state machine: the wrong action here either
/// re-denies a disarmed machine (trap) or hands out sudo when it shouldn't. `decide` is pure, so every
/// transition is checked directly, and each case names the defect it catches.
final class ReleaseValveDecideTests: XCTestCase {
    private let T = 1000.0   // "now"

    private func idle() -> ReleaseValveState { ReleaseValveState() }
    private func pending(eligibleAt: Double) -> ReleaseValveState {
        var s = ReleaseValveState(); s.requestedAt = 0; s.eligibleAt = eligibleAt; s.requestedDurationSec = 600; return s
    }
    private func granted(expiresAt: Double) -> ReleaseValveState {
        var s = ReleaseValveState(); s.requestedAt = 0; s.eligibleAt = 0; s.requestedDurationSec = 600
        s.grantedAt = 0; s.grantExpiresAt = expiresAt; return s
    }

    // DISARMED: the valve must get out of the way, never act on sudo.
    func testDisarmedIdleDoesNothing() {
        XCTAssertEqual(ReleaseValve.decide(armed: false, state: idle(), nowSec: T, gateOpen: true), .none)
    }
    func testDisarmedPendingStandsDown() {   // catches: a pending request surviving a disarm
        XCTAssertEqual(ReleaseValve.decide(armed: false, state: pending(eligibleAt: 0), nowSec: T, gateOpen: true), .standDown)
    }
    func testDisarmedGrantedStandsDown() {   // catches THE TRAP: a live grant re-denying after disarm
        XCTAssertEqual(ReleaseValve.decide(armed: false, state: granted(expiresAt: T + 100), nowSec: T, gateOpen: true), .standDown)
        // and it must NOT expire (which would write the DENY) just because we're past expiry while disarmed
        XCTAssertEqual(ReleaseValve.decide(armed: false, state: granted(expiresAt: T - 100), nowSec: T, gateOpen: true), .standDown)
    }

    // ARMED lifecycle.
    func testArmedIdleDoesNothing() {
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: idle(), nowSec: T, gateOpen: true), .none)
    }
    func testArmedPendingBeforeEligibleWaits() {   // catches: granting before the delay elapses
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: pending(eligibleAt: T + 100), nowSec: T, gateOpen: true), .none)
    }
    func testArmedEligibleButGateClosedWaits() {   // catches: granting while out of the allowed window
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: pending(eligibleAt: T - 100), nowSec: T, gateOpen: false), .none)
    }
    func testArmedEligibleAndGateOpenGrants() {
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: pending(eligibleAt: T - 100), nowSec: T, gateOpen: true), .grant)
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: pending(eligibleAt: T), nowSec: T, gateOpen: true), .grant)   // boundary
    }
    func testArmedGrantedBeforeExpiryHolds() {
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: granted(expiresAt: T + 100), nowSec: T, gateOpen: true), .none)
    }
    func testArmedGrantedAtExpiryExpires() {   // catches: a grant that never ends
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: granted(expiresAt: T - 100), nowSec: T, gateOpen: true), .expire)
        XCTAssertEqual(ReleaseValve.decide(armed: true, state: granted(expiresAt: T), nowSec: T, gateOpen: true), .expire)   // boundary
    }
}

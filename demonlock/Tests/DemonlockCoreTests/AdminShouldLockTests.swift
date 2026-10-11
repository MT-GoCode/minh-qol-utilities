import XCTest
@testable import DemonlockCore

/// The lock decision the enforcer applies every tick. Pure, so every case is checked directly; each
/// names the defect it catches. The I/O side (reconcile's dseditgroup + sudoers writes) is exercised by
/// the live harness, not here.
final class AdminShouldLockTests: XCTestCase {
    func testArmedAndIdleLocks() {
        XCTAssertTrue(Admin.shouldLock(armed: true, noSudo: false, valvePhase: "idle"))
    }
    func testArmedButGrantedUnlocks() {   // catches: tick re-denying during a live valve grant
        XCTAssertFalse(Admin.shouldLock(armed: true, noSudo: false, valvePhase: "granted"))
    }
    func testArmedWhileWaitingStillLocks() {   // delay/waiting are NOT a grant — stay locked
        XCTAssertTrue(Admin.shouldLock(armed: true, noSudo: false, valvePhase: "delay"))
        XCTAssertTrue(Admin.shouldLock(armed: true, noSudo: false, valvePhase: "waiting"))
    }
    func testNoSudoLatchLocksEvenWhenNotArmed() {   // catches: tick undoing a `nosudo` lock
        XCTAssertTrue(Admin.shouldLock(armed: false, noSudo: true, valvePhase: "idle"))
    }
    func testNoSudoLatchStillYieldsToAGrant() {
        XCTAssertFalse(Admin.shouldLock(armed: false, noSudo: true, valvePhase: "granted"))
    }
    func testDisarmedAndNoLatchUnlocks() {   // catches: a disarmed machine staying locked (brick)
        for phase in ["idle", "delay", "waiting", "granted"] {
            XCTAssertFalse(Admin.shouldLock(armed: false, noSudo: false, valvePhase: phase))
        }
    }
}

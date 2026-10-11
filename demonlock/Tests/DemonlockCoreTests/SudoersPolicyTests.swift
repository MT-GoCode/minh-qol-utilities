import XCTest
import MacUtilsCore
@testable import DemonlockCore

/// demonlock's sudoers file is the one artifact whose malformation costs the machine its root: a syntax
/// error anywhere under @includedir makes sudo refuse to run at all. So the real `visudo` parses both
/// real generated policies here, on every run, rather than on the machine they would brick.
final class SudoersPolicyTests: XCTestCase {
    private func visudoAccepts(_ body: String) -> Bool {
        let p = NSTemporaryDirectory() + "sudoers-policy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: p) }
        guard (try? body.write(toFile: p, atomically: true, encoding: .utf8)) != nil else { return false }
        return Proc.run("/usr/sbin/visudo", ["-cf", p], quiet: true) == 0
    }

    func testDenyPolicyParses() { XCTAssertTrue(visudoAccepts(Admin.denyBody("minhtrinh"))) }
    func testAllowPolicyParses() { XCTAssertTrue(visudoAccepts(Admin.allowBody("minhtrinh"))) }

    func testVisudoWouldRejectAMalformedRule() {
        XCTAssertFalse(visudoAccepts("minhtrinh ALL=(ALL:ALL !ALL\n"))
    }

    /// `sudoState` routes on what the file says, so a policy it cannot classify would silently read as
    /// "allowed" — the dangerous direction. Both real bodies must classify as themselves.
    func testEachPolicyClassifiesAsItself() {
        for (body, expected) in [(Admin.denyBody("minhtrinh"), Admin.SudoState.denied),
                                 (Admin.allowBody("minhtrinh"), Admin.SudoState.allowed)] {
            let p = NSTemporaryDirectory() + "sudostate-\(UUID().uuidString)"
            try? body.write(toFile: p, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: p) }
            XCTAssertEqual(Admin.sudoState(path: p), expected)
        }
    }

    func testMissingFileReadsAsUnmanagedRatherThanAllowed() {
        XCTAssertEqual(Admin.sudoState(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString)"), .unmanaged)
    }

    /// sudo parses /etc/sudoers.d in sorted lexical order and the last match wins, so demonlock's file
    /// must sort BEFORE the narrow NOPASSWD grants that `arm` and `nosudo` re-exec through — otherwise a
    /// deny would override them and those verbs could no longer run themselves.
    func testPolicySortsBeforeTheGrantFiles() {
        let name = (Admin.policyPath as NSString).lastPathComponent
        XCTAssertLessThan(name, "demonlock")
        XCTAssertLessThan(name, "stayup")
    }

    /// A staging name containing a `.` is skipped by @includedir, which is what makes the write atomic
    /// from sudo's point of view — it can never parse a half-written file.
    func testStagingNameIsInvisibleToSudo() {
        XCTAssertTrue((Admin.stagingPath as NSString).lastPathComponent.contains("."))
        XCTAssertFalse((Admin.policyPath as NSString).lastPathComponent.contains("."))
    }
}

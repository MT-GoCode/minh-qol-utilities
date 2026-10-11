import Foundation
import MacUtilsCore

/// Sudo grant/revoke, done entirely through ONE sudoers file. EVERY grant path (release-valve) and
/// EVERY revoke path (release-valve expiry / abort, `arm`, `nosudo`) routes through here, so the state
/// is always exactly what the last completed transition wrote.
///
/// WHY SUDOERS AND NOT THE `admin` GROUP. Two reasons, and the second is why this file touches the
/// group not at all:
///   • Correctness. Group membership does not hold on a managed Mac: an MDM re-adds the user to `admin`
///     on its own schedule (observed hourly — `dseditgroup -o edit -a <user> -t user admin`, logged
///     "promoted local account"), which would silently restore sudo. A sudoers `!ALL` rule overrides
///     `%admin` no matter who is in the group, and sudo re-reads it on every invocation, so it bites
///     instantly in already-open shells with no membership cache to lag behind it.
///   • Quiet. Removing the user from `admin` is the ONE action an MDM notices — it finds the user
///     missing on its next sweep and re-promotes, logging an event each time. Churning the group
///     therefore produces a visible tug-of-war on the MDM's side. Leaving the group untouched means
///     the MDM finds nothing to do and stays silent; enforcement happens somewhere it never reads
///     (observed: the MDM's daemon log never mentions sudoers). So the group is left ALONE, in both
///     directions, deliberately.
///
/// ONE FILE, TWO CONTENTS. The file either DENIES sudo or grants it passwordless; it cannot say both,
/// and there is no third content to get wrong. Absent means demonlock has no opinion yet (fresh
/// install) and `%admin` governs as macOS shipped it. Every transition is a single atomic rename, so
/// the state is whatever the last completed transition wrote.
///
/// LIMITS — documented, not fixable, and by design out of the threat model: this governs the sudo
/// command only. The user stays in `admin`, so Authorization Services still grants root in the GUI
/// (`system.privilege.admin` is `group: admin`): AppleScript's "with administrator privileges",
/// System Settings unlocks and installer packages remain available. That was already true within an
/// hour of arming under any design (the MDM re-promotes), and closing it is what made the machine
/// noisy, so it is accepted. The REQUEST DELAY is the commitment gate; this is anti-accident — stop
/// terminal sudo lingering by mistake — not a GUI containment boundary. [M1]
enum Admin {
    private static let visudo = "/usr/sbin/visudo"

    /// The `00-` prefix is load-bearing. sudo parses /etc/sudoers.d in sorted lexical order with the
    /// include directive LAST in /etc/sudoers, and the last matching rule wins — so this file lands
    /// after `%admin ALL=(ALL) ALL` (which it must override) and before the narrow NOPASSWD grants
    /// demonlock and its siblings install (which must keep working: `arm` and `nosudo` re-exec through
    /// theirs, and a deny sorting after them would stop those verbs running themselves).
    static let policyPath = "/etc/sudoers.d/00-demonlock"

    /// Staging name for the atomic write. `@includedir` skips any filename containing a `.`, so sudo
    /// cannot parse this even while it is half-written.
    static var stagingPath: String { policyPath + ".tmp" }

    /// Separate from the write so the exact text that could cost a machine its root is checkable by
    /// `visudo` in the test suite, not only on the machine it would brick.
    static func denyBody(_ user: String) -> String {
        """
        # demonlock: sudo DENIED. Delete this file to restore macOS's default `%admin` rule.
        # Replaced automatically by a release-valve grant and by `demonlock disarm`.
        \(user) ALL=(ALL:ALL) !ALL
        """
    }

    /// Passwordless because the delay is the gate, not the password: once the valve has opened, a PIN
    /// prompt on every command is friction that protects nothing.
    static func allowBody(_ user: String) -> String {
        """
        # demonlock: sudo ALLOWED, passwordless, until `arm`/`nosudo` or the release-valve grant expires.
        \(user) ALL=(ALL:ALL) NOPASSWD: ALL
        """
    }

    /// `unmanaged` is the pre-install state: no file, so macOS's own `%admin` rule governs. Keeping it
    /// distinct from `allowed` means status can never report demonlock's passwordless grant when all
    /// that is really there is stock macOS.
    enum SudoState: String { case denied, allowed, unmanaged }

    /// What the sudoers file currently says. One read, no subprocess. The file is 0440 root:wheel, so
    /// only the root enforcer can call this meaningfully; the unprivileged CLI/GUI render the value the
    /// enforcer publishes into the state snapshot instead of reading the file themselves.
    static func sudoState(path: String = policyPath) -> SudoState {
        guard FileManager.default.fileExists(atPath: path) else { return .unmanaged }
        // Present but unreadable: report DENIED, never "allowed" — no false reassurance.
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return .denied }
        return s.contains("!ALL") ? .denied : .allowed
    }

    /// Grant passwordless sudo to `user` (idempotent).
    @discardableResult
    static func grant(_ user: String) -> Bool { allowSudo(user) }

    /// Deny sudo to `user` (idempotent).
    @discardableResult
    static func revoke(_ user: String) -> Bool { denySudo(user) }

    @discardableResult
    static func denySudo(_ user: String) -> Bool { writePolicy(denyBody(user)) }

    @discardableResult
    static func allowSudo(_ user: String) -> Bool { writePolicy(allowBody(user)) }

    /// Remove the policy file, handing sudo back to macOS's `%admin` rule. disarm's fallback when the
    /// enforced user can't be resolved: a delete needs no username and no visudo, so it can't fail the
    /// way a write can.
    @discardableResult
    static func unmanageSudo() -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(atPath: stagingPath)
        guard fm.fileExists(atPath: policyPath) else { return true }
        return (try? fm.removeItem(atPath: policyPath)) != nil
    }

    /// Publish a sudoers policy atomically. `visudo -cf` gates the publish because a syntax error
    /// anywhere under the include directive disables sudo entirely, which on a machine with no known
    /// account password is unrecoverable. `rename(2)` cannot be observed partially, so sudo sees either
    /// the whole previous policy or the whole new one — never a mixture, and never nothing.
    private static func writePolicy(_ body: String) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(atPath: stagingPath)
        guard fm.createFile(atPath: stagingPath, contents: Data((body + "\n").utf8),
                            attributes: [.posixPermissions: 0o440,
                                         .ownerAccountID: 0,
                                         .groupOwnerAccountID: 0]) else { return false }
        guard Proc.run(visudo, ["-cf", stagingPath], quiet: true) == 0 else {
            try? fm.removeItem(atPath: stagingPath)
            return false
        }
        return rename(stagingPath, policyPath) == 0
    }
}

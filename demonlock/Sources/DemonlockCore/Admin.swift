import Foundation
import MacUtilsCore

/// Admin (sudo) grant/revoke. The enforcer is already root, so there's no setuid dance and no shared
/// secret: it writes ONE sudoers file and edits the `admin` group. EVERY grant path (release-valve) and
/// EVERY revoke path (release-valve expiry / abort, `arm`, `nosudo`) routes through here, so the two
/// halves can never drift apart.
///
/// WHY SUDOERS AND NOT THE GROUP. Group membership does not hold on a managed Mac: an MDM re-adds the
/// user to `admin` on its own schedule (observed hourly — `dseditgroup -o edit -a <user> -t user admin`,
/// logged as "promoted local account"), silently restoring sudo while demonlock still reports ARMED.
/// The group edit is therefore cosmetic and best-effort; the load-bearing half is the sudoers file,
/// which no MDM touches and which sudo re-reads on every invocation — so it bites instantly in
/// already-open shells, with no membership cache to lag behind it.
///
/// ONE FILE, TWO CONTENTS. The file either DENIES sudo or grants it passwordless; it cannot say both,
/// and there is no third content to get wrong. Absent means demonlock has no opinion yet (fresh
/// install) and `%admin` governs as macOS shipped it. Every transition is a single atomic rename, so
/// the state is whatever the last completed transition wrote.
///
/// LIMITS — documented, not fixable, and by design out of the threat model: this governs sudo only.
/// While an MDM keeps the user in `admin`, Authorization Services still grants root in the GUI
/// (`system.privilege.admin` is `group: admin`), so AppleScript's "with administrator privileges",
/// System Settings unlocks and installer packages remain open. A determined user can also plant residue
/// revoke won't clean (a root LaunchDaemon, a root shell). The REQUEST DELAY is the commitment gate;
/// this is anti-accident — stop sudo lingering by mistake — not a containment boundary. [M1]
enum Admin {
    private static let dseditgroup = "/usr/sbin/dseditgroup"
    private static let dsmemberutil = "/usr/bin/dsmemberutil"
    private static let visudo = "/usr/sbin/visudo"
    private static let sudoTSDir = "/var/db/sudo/ts"

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
    /// prompt on every command is friction that protects nothing. Independent of the `admin` group, so
    /// a grant works whether or not the MDM has promoted the user at that moment.
    static func allowBody(_ user: String) -> String {
        """
        # demonlock: sudo ALLOWED, passwordless, until `arm`/`nosudo` or the release-valve grant expires.
        \(user) ALL=(ALL:ALL) NOPASSWD: ALL
        """
    }

    static func isAdmin(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "checkmember", "-m", user, "admin"], quiet: true) == 0
    }

    /// `unmanaged` is the pre-install state: no file, so macOS's own `%admin` rule governs. Keeping it
    /// distinct from `allowed` means status can never report demonlock's passwordless grant when all
    /// that is really there is stock macOS.
    enum SudoState: String { case denied, allowed, unmanaged }

    /// What the sudoers file currently says. A single read, so `status` can render it on every refresh
    /// without spawning anything — and it reports the gate demonlock actually owns rather than
    /// inferring it from group membership.
    static func sudoState(path: String = policyPath) -> SudoState {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return .unmanaged }
        return s.contains("!ALL") ? .denied : .allowed
    }

    /// Grant admin to `user` (idempotent). The sudoers flip happens LAST: if it fails, sudo stays as it
    /// was rather than the grant half-landing.
    @discardableResult
    static func grant(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "edit", "-a", user, "-t", "user", "admin"], quiet: true)
        flushMembershipCache()
        return allowSudo(user)
    }

    /// Revoke admin from `user` (idempotent). Returns true only if the sudoers deny actually landed —
    /// the group edit is best-effort because an MDM may undo it, so it is not part of the verdict.
    @discardableResult
    static func revoke(_ user: String) -> Bool {
        if isAdmin(user) {
            Proc.run(dseditgroup, ["-o", "edit", "-d", user, "-t", "user", "admin"], quiet: true)
        }
        flushMembershipCache()
        clearSudoCache()
        return denySudo(user)
    }

    @discardableResult
    static func denySudo(_ user: String) -> Bool { writePolicy(denyBody(user)) }

    @discardableResult
    static func allowSudo(_ user: String) -> Bool { writePolicy(allowBody(user)) }

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

    /// macOS caches group membership, so `dseditgroup -o checkmember` — and sudo's own `%admin` check —
    /// can keep answering "yes" for minutes about a user who was just removed.
    private static func flushMembershipCache() {
        Proc.run(dsmemberutil, ["flushcache"], quiet: true)
    }

    /// Wipe cached sudo timestamps so an open terminal re-authenticates rather than riding out sudo's
    /// grace window.
    private static func clearSudoCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sudoTSDir) else { return }
        for e in entries { try? fm.removeItem(atPath: sudoTSDir + "/" + e) }
    }
}

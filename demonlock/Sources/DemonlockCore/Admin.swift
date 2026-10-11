import Foundation
import MacUtilsCore

/// The lock. demonlock shuts TWO doors to root, and this type is their single owner:
///   • the TERMINAL door — macOS's `%admin` sudoers rule — shut with a sudoers `!ALL` file that overrides
///     it. sudo re-reads sudoers every call, so this bites instantly, even in already-open shells, and no
///     MDM touches it.
///   • the GUI door — Authorization Services (the "enter your password" prompts for installers, System
///     Settings, `osascript … with administrator privileges`) — which trusts the `admin` GROUP. Shut by
///     removing the user from `admin`.
///
/// Shutting only the sudoers door leaves the GUI door open; shutting only the group door is undone by a
/// managed Mac's MDM, which re-adds the user to `admin` on a schedule. So the enforcer TICK calls
/// `reconcile` every second as the single writer, re-shutting whatever drifted — on a managed Mac that
/// out-removes the MDM within a second; on a personal Mac it is a no-op after the first tick.
///
/// GUI-door caveat: removing the user from `admin` reliably locks a NEW login, but macOS caches group
/// membership for an already-open login session, so a GUI prompt in the CURRENT session can keep working
/// until the next logout. The sudoers door has no such lag. That is why `arm` tells the user to log out
/// and back in. The sudoers `!ALL` is the instant, un-cached guarantee; the group removal is the GUI
/// backstop. [M1: the request delay is the commitment gate; this is the lock, not a containment proof]
enum Admin {
    private static let dseditgroup = "/usr/sbin/dseditgroup"
    private static let visudo = "/usr/sbin/visudo"

    /// The `00-` prefix is load-bearing. sudo parses /etc/sudoers.d in sorted lexical order with the
    /// include directive LAST in /etc/sudoers, and the last matching rule wins — so this lands after
    /// `%admin ALL=(ALL) ALL` (which it must override) and before the narrow NOPASSWD grants demonlock
    /// and its siblings install (which must keep working: `arm`/`nosudo` re-exec through theirs).
    static let policyPath = "/etc/sudoers.d/00-demonlock"
    static var stagingPath: String { policyPath + ".tmp" }

    // ---- sudoers door (the Terminal lock) ----

    /// Separate from the write so the exact text that could cost a machine its root is checkable by
    /// `visudo` in the test suite, not only on the machine it would brick.
    static func denyBody(_ user: String) -> String {
        """
        # demonlock: sudo DENIED. Delete this file to restore macOS's default `%admin` rule.
        # Rewritten automatically by a release-valve grant and by `demonlock disarm`.
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
    /// distinct from `allowed` means status can never report demonlock's passwordless grant when all that
    /// is really there is stock macOS.
    enum SudoState: String { case denied, allowed, unmanaged }

    /// What the sudoers file currently says. The file is 0440 root:wheel, so only the root enforcer can
    /// read it meaningfully; the unprivileged CLI/GUI render the value the enforcer publishes.
    static func sudoState(path: String = policyPath) -> SudoState {
        guard FileManager.default.fileExists(atPath: path) else { return .unmanaged }
        // Present but unreadable: report DENIED, never "allowed" — no false reassurance.
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return .denied }
        return s.contains("!ALL") ? .denied : .allowed
    }

    /// Cross-process lock serializing create→validate→rename. Dotted + outside sudoers.d, so it is never
    /// parsed as sudoers; a process that dies holding it releases it on fd close.
    private static let lockPath = Paths.supportDir + "/.sudoers-write.lock"

    /// Publish a sudoers policy atomically. `visudo -cf` gates the publish because a syntax error anywhere
    /// under the include directive disables sudo entirely, unrecoverable on a box with no known password.
    /// `rename(2)` cannot be observed partially, so sudo sees the whole old policy or the whole new one.
    private static func writePolicy(_ body: String) -> Bool {
        let fm = FileManager.default
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }

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

    private static func denySudo(_ user: String) -> Bool { writePolicy(denyBody(user)) }
    private static func allowSudo(_ user: String) -> Bool { writePolicy(allowBody(user)) }

    /// Remove the policy file, handing the Terminal door back to `%admin`. disarm's fallback when the
    /// enforced user can't be resolved: a delete needs no username and no visudo, so it can't fail the
    /// way a write can.
    @discardableResult
    static func unmanageSudo() -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(atPath: stagingPath)
        guard fm.fileExists(atPath: policyPath) else { return true }
        return (try? fm.removeItem(atPath: policyPath)) != nil
    }

    // ---- group door (the GUI lock) ----

    static func isAdmin(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "checkmember", "-m", user, "admin"], quiet: true) == 0
    }

    @discardableResult
    private static func addAdmin(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "edit", "-a", user, "-t", "user", "admin"], quiet: true) == 0
    }

    @discardableResult
    private static func removeAdmin(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "edit", "-d", user, "-t", "user", "admin"], quiet: true) == 0
    }

    // ---- single owner ----

    /// When should sudo be locked? Pure, so the tick's decision is unit-testable. Locked when demonlock
    /// wants it — the arm flag OR the nosudo latch — AND the release valve is not currently granting a
    /// window. A live grant (phase "granted") always unlocks, which is how the valve hands sudo back.
    static func shouldLock(armed: Bool, noSudo: Bool, valvePhase: String) -> Bool {
        (armed || noSudo) && valvePhase != "granted"
    }

    /// Make both doors match `locked`, idempotently: reads current state and writes only on a difference,
    /// so a steady tick is a couple of cheap reads and no writes. `changed` is set when either door was
    /// actually moved, so the tick logs only transitions. Returns true once the SUDOERS door — the
    /// instant, un-cached lock — is in the desired state; the group door is best-effort (an MDM may fight
    /// it and the next tick re-wins).
    @discardableResult
    static func reconcile(locked: Bool, user: String, changed: inout Bool) -> Bool {
        changed = false
        if locked {
            if isAdmin(user) { _ = removeAdmin(user); changed = true }
            if sudoState() != .denied { _ = denySudo(user); changed = true }
            return sudoState() == .denied
        } else {
            if !isAdmin(user) { _ = addAdmin(user); changed = true }
            if sudoState() != .allowed { _ = allowSudo(user); changed = true }
            return sudoState() == .allowed
        }
    }

    @discardableResult
    static func reconcile(locked: Bool, user: String) -> Bool {
        var ignored = false
        return reconcile(locked: locked, user: user, changed: &ignored)
    }
}

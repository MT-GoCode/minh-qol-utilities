import Foundation

/// Which windows are open, kept in the state file so the next launch can bring every one of them back. Closing one
/// window removes it; quitting does not (the windows close one by one while the app quits, and they must all return).
public final class SessionRegistry {
    private let store: StateStore
    private var terminating = false

    public init(store: StateStore) { self.store = store }

    public var windows: [WindowState] { store.state.windows }

    public func opened(_ window: WindowState) {
        store.update { state in
            if let index = state.windows.firstIndex(where: { $0.id == window.id }) { state.windows[index] = window } else { state.windows.append(window) }
        }
    }

    public func moved(_ id: UUID, to frame: Frame) { change(id) { $0.frame = frame } }

    public func barToggled(_ id: UUID, hidden: Bool) { change(id) { $0.barHidden = hidden } }

    public func closed(_ id: UUID) {
        guard !terminating else { return }
        store.update { $0.windows.removeAll { $0.id == id } }
    }

    /// The app is quitting: from here on closing a window keeps its entry.
    public func beginTermination() { terminating = true }

    /// The windows to bring back at launch. Entries whose file is gone are dropped from the state and returned in
    /// `missing`, so the app can say so instead of silently losing them.
    public func windowsToRestore(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (restore: [WindowState], missing: [WindowState]) {
        let (restore, missing) = windows.reduce(into: ([WindowState](), [WindowState]())) { split, window in
            if fileExists(window.path) { split.0.append(window) } else { split.1.append(window) }
        }
        if !missing.isEmpty { store.update { state in state.windows = restore } }
        return (restore, missing)
    }

    private func change(_ id: UUID, _ edit: (inout WindowState) -> Void) {
        store.update { state in
            guard let index = state.windows.firstIndex(where: { $0.id == id }) else { return }
            edit(&state.windows[index])
        }
    }
}

/// One line of the Open Recent menu: the file name and where it was left (`4:52`).
public struct RecentEntry: Equatable {
    public let path: String
    public let title: String
    public let position: String

    /// Ten, like the Open Recent menus of macOS apps and VSCode (a decision, recorded in DECISIONS.md).
    public static let menuLimit = 10

    /// The most recent first, at most `limit`, each with its remembered position.
    public static func entries(from state: State, limit: Int = RecentEntry.menuLimit) -> [RecentEntry] {
        state.recents.prefix(limit).map { path in
            RecentEntry(path: path, title: URL(fileURLWithPath: path).lastPathComponent,
                        position: TimeFormat.format(state.files[path]?.position ?? 0))
        }
    }
}

import AppKit
import EVPCore

/// What a line of the Audio or Subtitles menu does when chosen.
private final class TrackChoice {
    let kind: Track.Kind
    let trackID: Int?
    weak var window: PlayerWindowController?

    init(kind: Track.Kind, trackID: Int?, window: PlayerWindowController) { (self.kind, self.trackID, self.window) = (kind, trackID, window) }
}

/// The app-wide parts: the state, the session, the open windows, the global hotkey, the media keys and the menus.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SettingsHost {
    var recentMenu: NSMenu?
    var audioMenu: NSMenu?
    var subtitleMenu: NSMenu?
    private var players: [PlayerWindowController] = []
    private var cascadePoint = NSPoint.zero
    private var store: StateStore!
    private var session: SessionRegistry!
    /// Taken before any open request is handled, so a file opened at launch is not also restored as a second window.
    private var toRestore: [WindowState] = []
    private var missing: [WindowState] = []
    private var reportedFlushError = false
    private let pauseAll = PauseAll()
    private lazy var hotkey = GlobalHotkey { [weak self] in self?.pauseAllPressed() }
    private var mediaKeys: MediaKeys!
    private var eventTap: EventTapRoute!
    private var settingsWindow: SettingsWindowController?

    private var settings: Settings { store.state.settings }

    /// `EVP_HOME` moves the state elsewhere (the tests use a scratch folder).
    private static var stateDirectory: URL {
        ProcessInfo.processInfo.environment["EVP_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EVP")
    }

    /// Before any open request arrives. An unreadable state file, or settings that are not valid, stop the app: the
    /// file is never replaced.
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            store = try StateStore(directory: Self.stateDirectory) { [weak self] error in
                guard let self, !self.reportedFlushError else { return }
                self.reportedFlushError = true
                NSAlert(error: error).runModal()
            }
        } catch {
            stop("The saved state cannot be read", "\(error.localizedDescription)\n\nThe file is left as it is. Fix or move \(Self.stateDirectory.path)/state.json and start again.")
        }
        let problems = store.state.settings.problems()
        if !problems.isEmpty {
            stop("The saved settings are not valid", problems.joined(separator: "\n") + "\n\nFix \(Self.stateDirectory.path)/state.json and start again.")
        }
        session = SessionRegistry(store: store)
        if settings.restoreWindowsOnLaunch { (toRestore, missing) = session.windowsToRestore() }
        store.update { $0.windows = [] }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)
        let decoupled = { [weak self] in self?.settings.decoupleMediaKeys ?? true }
        let target = { [weak self] in self?.playingWindow() }
        mediaKeys = MediaKeys(decoupled: decoupled, target: target)
        eventTap = EventTapRoute(decoupled: decoupled, target: target)
        if !settings.decoupleMediaKeys { eventTap.enable(prompt: false) }
        if let chord = settings.keymap.chords[.pauseAll] {
            do { try hotkey.register(chord) } catch { NSAlert(error: error).runModal() }
        }
        for state in toRestore where !players.contains(where: { $0.path == state.path }) {
            show(URL(fileURLWithPath: state.path), restoring: state)
        }
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(missing.count) video\(missing.count == 1 ? "" : "s") could not be reopened"
            alert.informativeText = "These files are gone:\n" + missing.map(\.path).joined(separator: "\n")
            alert.runModal()
        }
        (toRestore, missing) = ([], [])
    }

    private func stop(_ message: String, _ detail: String) -> Never {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        exit(1)
    }

    /// Finder opens, `open file`, and `evp://` URLs from the `evp` command all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do { show(try OpenRequest(url: url)) } catch { NSAlert(error: error).runModal() }
        }
    }

    private func show(_ file: URL, restoring: WindowState) {
        do { show(try OpenRequest(url: file), restoring: restoring) } catch { NSAlert(error: error).runModal() }
    }

    private func show(_ request: OpenRequest, restoring: WindowState? = nil) {
        do {
            let controller = try PlayerWindowController(request, store: store, session: session, restoring: restoring)
            controller.onClose = { [weak self] closed in self?.players.removeAll { $0 === closed } }
            controller.onPlayingChanged = { [weak self] in self?.mediaKeys.refresh() }
            players.append(controller)
            cascadePoint = controller.show(cascadingFrom: cascadePoint)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The window the media keys act on: the main window if it plays, else any playing window.
    private func playingWindow() -> PlayerWindowController? {
        players.first { $0.isPlaying && $0.window?.isMainWindow == true } ?? players.first { $0.isPlaying }
    }

    /// The window the menus act on: the main window (still the video while Settings is the key window).
    private var frontWindow: PlayerWindowController? { NSApp.mainWindow?.windowController as? PlayerWindowController ?? players.first }

    private func pauseAllPressed() {
        do { try pauseAll.press(over: players.map(\.pausable)) } catch { frontWindow?.showFeedback("Error: \(error)") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.beginTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        do { try store.flushNow() } catch { NSAlert(error: error).runModal() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Settings

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: store, host: self) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    var tapStatus: String { eventTap.status.rawValue }

    func enableTap() { eventTap.enable(prompt: true) }

    /// The global hotkey is the one setting the system can refuse, so it is registered before the change is stored.
    func accept(from old: Settings, to new: Settings) -> String? {
        let (was, now) = (old.keymap.chords[.pauseAll], new.keymap.chords[.pauseAll])
        guard was != now else { return nil }
        guard let now else {
            hotkey.unregister()
            return nil
        }
        guard !now.modifiers.subtracting(.shift).isEmpty else {
            return "A global key needs Ctrl, Alt or Cmd: \(now) alone would be taken from every app."
        }
        do {
            try hotkey.register(now)
            return nil
        } catch {
            guard let was else { return error.localizedDescription }
            do { try hotkey.register(was) } catch { return "\(error.localizedDescription) The previous key \(was) could not be registered again either." }
            return error.localizedDescription
        }
    }

    /// What is not read per event: the media keys' routes and the bar's labels.
    func settingsChanged(from old: Settings, to new: Settings) {
        mediaKeys.refresh()
        if new.decoupleMediaKeys { eventTap.disable() } else if old.decoupleMediaKeys { eventTap.enable(prompt: true) }
        players.forEach { $0.settingsChanged() }
    }

    /// While the Global tab records a chord, the current one must reach the recorder, not pause every video.
    func holdGlobalHotkey(_ held: Bool) {
        if held { return hotkey.unregister() }
        guard let chord = settings.keymap.chords[.pauseAll] else { return }
        do { try hotkey.register(chord) } catch { NSAlert(error: error).runModal() }
    }

    // MARK: File menu

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        application(NSApp, open: panel.urls)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        application(NSApp, open: [URL(fileURLWithPath: path)])
    }

    /// None of these menus has key equivalents, so AppKit need not rebuild them on every Cmd+key press.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    /// Menus are rebuilt each time they open, from the state or the playing file, so they never go stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === recentMenu {
            for (index, entry) in RecentEntry.entries(from: store.state).enumerated() {
                let item = NSMenuItem(title: "\(entry.title)  (\(entry.position))", action: #selector(openRecent(_:)), keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier("recent-\(index)")
                item.target = self
                item.representedObject = entry.path
                menu.addItem(item)
            }
        } else if menu === audioMenu {
            fillTrackMenu(menu, .audio)
        } else if menu === subtitleMenu {
            fillTrackMenu(menu, .sub)
        }
    }

    private func fillTrackMenu(_ menu: NSMenu, _ kind: Track.Kind) {
        guard let window = frontWindow else {
            menu.addItem(withTitle: "No video open", action: nil, keyEquivalent: "")
            return
        }
        do {
            let items = try window.trackItems(kind)
            for line in items {
                let item = NSMenuItem(title: line.title, action: #selector(selectTrack(_:)), keyEquivalent: "")
                item.target = self
                item.state = line.isChecked ? .on : .off
                item.identifier = NSUserInterfaceItemIdentifier("menu-\(kind.rawValue)-\(line.trackID.map(String.init) ?? "off")")
                item.representedObject = TrackChoice(kind: kind, trackID: line.trackID, window: window)
                menu.addItem(item)
            }
            if items.isEmpty { menu.addItem(withTitle: "None in this file", action: nil, keyEquivalent: "") }
        } catch {
            menu.addItem(withTitle: "Error: \(error)", action: nil, keyEquivalent: "")
        }
    }

    @objc private func selectTrack(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TrackChoice else { return }
        choice.window?.select(choice.kind, trackID: choice.trackID)
    }
}

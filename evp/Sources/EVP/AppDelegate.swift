import AppKit
import EVPCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var players: [PlayerWindowController] = []
    private var cascadePoint = NSPoint.zero
    private var store: StateStore!
    private var session: SessionRegistry!
    private var reportedFlushError = false
    private let pauseAll = PauseAll()
    private var hotkey: GlobalHotkey?
    private var mediaKeys: MediaKeys?
    private var eventTap: EventTapRoute?
    private var settingsWindow: SettingsWindowController?

    /// `EVP_HOME` moves the state elsewhere (the tests use a scratch folder).
    private static var stateDirectory: URL {
        ProcessInfo.processInfo.environment["EVP_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EVP")
    }

    /// Before any open request arrives. An unreadable state file stops the app: it is never replaced.
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            store = try StateStore(directory: Self.stateDirectory) { [weak self] error in
                guard let self, !self.reportedFlushError else { return }
                self.reportedFlushError = true
                NSAlert(error: error).runModal()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "\(error.localizedDescription)\n\nThe file is left as it is. Fix or move \(Self.stateDirectory.path)/state.json and start again."
            alert.runModal()
            exit(1)
        }
        let problems = store.state.settings.problems()
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "The saved settings are not valid"
            alert.informativeText = problems.joined(separator: "\n") + "\n\nFix \(Self.stateDirectory.path)/state.json and start again."
            alert.runModal()
            exit(1)
        }
        session = SessionRegistry(store: store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)
        mediaKeys = MediaKeys(decoupled: store.state.settings.decoupleMediaKeys) { [weak self] in self?.playingWindow() }
        registerPauseAllHotkey()
        let tap = EventTapRoute(decoupled: { [weak self] in self?.store.state.settings.decoupleMediaKeys ?? true }) { [weak self] in self?.playingWindow() }
        eventTap = tap
        if !store.state.settings.decoupleMediaKeys { tap.enable(prompt: false) }
        guard store.state.settings.restoreWindowsOnLaunch else {
            store.update { $0.windows = [] }
            return
        }
        let (restore, missing) = session.windowsToRestore()
        for state in restore { show(URL(fileURLWithPath: state.path), restoring: state) }
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(missing.count) video\(missing.count == 1 ? "" : "s") could not be reopened"
            alert.informativeText = "These files are gone:\n" + missing.map(\.path).joined(separator: "\n")
            alert.runModal()
        }
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
            controller.onPlayingChanged = { [weak self] in self?.mediaKeys?.refresh() }
            players.append(controller)
            cascadePoint = controller.show(cascadingFrom: cascadePoint)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The window the media keys act on: the key window if it plays, else any playing window.
    private func playingWindow() -> PlayerWindowController? {
        players.first { $0.isPlaying && $0.window?.isKeyWindow == true } ?? players.first { $0.isPlaying }
    }

    private func registerPauseAllHotkey() {
        hotkey?.unregister()
        hotkey = nil
        guard let chord = store.state.settings.keymap.chords[.pauseAll] else { return }
        hotkey = GlobalHotkey { [weak self] in
            guard let self else { return }
            do { try self.pauseAll.press(over: self.players.map(\.pausable)) } catch { self.players.first?.showFeedback("Error: \(error)") }
        }
        do { try hotkey?.register(chord) } catch { NSAlert(error: error).runModal() }
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
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, tapStatus: { [weak self] in self?.eventTap?.status.rawValue ?? "Off" },
                                                      enableTap: { [weak self] in self?.eventTap?.enable(prompt: true) },
                                                      onChange: { [weak self] old, new in self?.settingsChanged(from: old, to: new) })
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// What cannot be read per event is told here: the media keys' route and the global hotkey.
    private func settingsChanged(from old: Settings, to new: Settings) {
        mediaKeys?.decoupled = new.decoupleMediaKeys
        if new.decoupleMediaKeys { eventTap?.disable() } else if old.decoupleMediaKeys { eventTap?.enable(prompt: true) }
        if old.keymap.chords[.pauseAll] != new.keymap.chords[.pauseAll] { registerPauseAllHotkey() }
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

    /// The Open Recent menu is rebuilt each time it opens, from the state, so it never goes stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in RecentEntry.entries(from: store.state) {
            let item = NSMenuItem(title: "\(entry.title)  (\(entry.position))", action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            menu.addItem(item)
        }
    }
}

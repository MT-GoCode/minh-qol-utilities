import AppKit
import EVPCore

/// One window playing one file. `perform` is the single place every user action ends up.
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private struct NoOpenGL: LocalizedError {
        var errorDescription: String? { "OpenGL is not available" }
    }

    var onClose: ((PlayerWindowController) -> Void)?
    /// Called when this window starts or stops playing.
    var onPlayingChanged: (() -> Void)?
    private(set) var isPlaying = false
    private let player: MpvPlayer
    private let content: PlayerContentView
    private let id: UUID
    private let path: String
    private let session: SessionRegistry
    private let restored: Bool
    private let store: StateStore
    private var settings: Settings { store.state.settings }

    private var bar: ControlBar { content.bar }
    private var video: GLVideoView { content.video }

    /// `restoring` is the saved state of a window from the last run: it comes back at its frame, with its bar, paused
    /// at the position the file was left at.
    init(_ request: OpenRequest, store: StateStore, session: SessionRegistry, restoring: WindowState? = nil) throws {
        player = try MpvPlayer(output: .video)
        guard let video = GLVideoView(player: player) else { throw NoOpenGL() }
        let bar = ControlBar(settings: store.state.settings)
        content = PlayerContentView(video: video, bar: bar)
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.contentMinSize = NSSize(width: bar.minimumWidth, height: PlayerLayout.barHeight + 1)
        window.collectionBehavior = .fullScreenPrimary
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = request.file.lastPathComponent
        window.representedURL = request.file
        window.isReleasedWhenClosed = false
        id = restoring?.id ?? UUID()
        path = request.file.path
        self.session = session
        self.store = store
        restored = restoring != nil
        if let restoring {
            window.setFrame(restoring.frame.rect, display: false)
            content.barHidden = restoring.barHidden
        }
        super.init(window: window)
        window.delegate = self
        window.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        bar.onCommand = { [weak self] in self?.perform($0) }
        let memory = FileMemory(store: store, file: request.file)
        player.onEvent = { [weak self] event in
            guard let self else { return }
            do { try memory.handle(event, player: self.player) } catch { self.bar.showFeedback("Error: \(error)") }
            self.handle(event)
        }
        video.onReady = { [weak self] in
            guard let self else { return }
            do {
                if self.restored { try self.player.setPaused(true) }
                try memory.open(request.file, in: self.player, start: request.start)
            } catch { self.fail(error) }
        }
    }

    required init?(coder: NSCoder) { fatalError("PlayerWindowController is created in code") }

    /// Shows the window and returns the point the next window should cascade from. A restored window stays where it was.
    func show(cascadingFrom point: NSPoint) -> NSPoint {
        guard let window else { return point }
        var next = point
        if !restored {
            if point == .zero { window.center() }
            next = window.cascadeTopLeft(from: point == .zero ? NSPoint(x: window.frame.minX, y: window.frame.maxY) : point)
        }
        showWindow(nil)
        session.opened(WindowState(id: id, path: path, frame: Frame(window.frame), barHidden: content.barHidden))
        return next
    }

    func windowWillClose(_ notification: Notification) {
        video.shutdown()
        session.closed(id)
        isPlaying = false
        onClose?(self)
        onPlayingChanged?()
    }

    /// What the global pause key acts on.
    var pausable: Pausable { player }

    func showFeedback(_ text: String) { bar.showFeedback(text) }

    func windowDidMove(_ notification: Notification) { reportFrame() }

    func windowDidResize(_ notification: Notification) { reportFrame() }

    /// A full-screen window reports nothing: the frame to bring back is the one it had before.
    private func reportFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        session.moved(id, to: Frame(window.frame))
    }

    // MARK: Commands

    /// A key press: looked up in the keymap, run once per press unless the action repeats when held. Global actions
    /// are not the window's.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord.chord(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: Modifiers(event.modifierFlags)),
              let action = settings.keymap.action(for: chord), !Action.global.contains(action) else { return false }
        if action.runs(onRepeat: event.isARepeat) { perform(.action(action)) }
        return true
    }

    func perform(_ command: Command) {
        do {
            switch try player.perform(command, settings: settings) {
            case .done(let feedback): feedback.map(bar.showFeedback)
            case .interface(let action): performInterface(action)
            }
        } catch {
            bar.showFeedback("Error: \(error)")
        }
    }

    private func performInterface(_ action: InterfaceAction) {
        switch action {
        case .fullscreen: window?.toggleFullScreen(nil)
        case .toggleBar:
            content.barHidden.toggle()
            session.barToggled(id, hidden: content.barHidden)
        case .screenshot: copyScreenshot()
        case .pauseAll: bar.showFeedback("\(action) is not available yet")
        }
    }

    /// The frame being shown, as a PNG on the clipboard and nowhere else.
    private func copyScreenshot() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("evp-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try player.screenshot(to: file)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(try Data(contentsOf: file), forType: .png)
            bar.showFeedback("Screenshot copied")
        } catch {
            bar.showFeedback("Error: \(error)")
        }
    }

    private func handle(_ event: MpvPlayer.Event) {
        switch event {
        case .loadFailed(let error): fail(error)
        case .time(let seconds): bar.setTime(seconds)
        case .duration(let seconds): bar.setDuration(seconds)
        case .paused(let paused):
            bar.setPaused(paused)
            isPlaying = !paused
            onPlayingChanged?()
        case .speed(let speed): bar.setSpeed(speed)
        case .volume(let volume): bar.setVolume(volume)
        case .fileLoaded, .playbackRestart, .muted, .endOfFile: break
        }
    }

    private func fail(_ error: Error) {
        NSAlert(error: error).runModal()
        close()
    }
}

extension Frame {
    init(_ rect: NSRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
    var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

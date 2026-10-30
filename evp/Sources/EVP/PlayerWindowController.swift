import AppKit
import EVPCore

/// One window playing one file. `perform` is the single place every user action ends up.
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private struct NoOpenGL: LocalizedError {
        var errorDescription: String? { "OpenGL is not available" }
    }

    var onClose: ((PlayerWindowController) -> Void)?
    private let player: MpvPlayer
    private let content: PlayerContentView
    private var settings = Settings()

    private var bar: ControlBar { content.bar }
    private var video: GLVideoView { content.video }

    init(_ request: OpenRequest) throws {
        player = try MpvPlayer(output: .video)
        guard let video = GLVideoView(player: player) else { throw NoOpenGL() }
        let bar = ControlBar(settings: settings)
        content = PlayerContentView(video: video, bar: bar)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.contentMinSize = NSSize(width: bar.minimumWidth, height: PlayerLayout.barHeight + 1)
        window.collectionBehavior = .fullScreenPrimary
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = request.file.lastPathComponent
        window.representedURL = request.file
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        bar.onCommand = { [weak self] in self?.perform($0) }
        player.onEvent = { [weak self] in self?.handle($0) }
        video.onReady = { [weak self] in
            do { try self?.player.load(request.file, start: request.start) } catch { self?.fail(error) }
        }
    }

    required init?(coder: NSCoder) { fatalError("PlayerWindowController is created in code") }

    /// Shows the window and returns the point the next window should cascade from.
    func show(cascadingFrom point: NSPoint) -> NSPoint {
        guard let window else { return point }
        if point == .zero { window.center() }
        let next = window.cascadeTopLeft(from: point == .zero ? NSPoint(x: window.frame.minX, y: window.frame.maxY) : point)
        showWindow(nil)
        return next
    }

    func windowWillClose(_ notification: Notification) {
        video.shutdown()
        onClose?(self)
    }

    // MARK: Commands

    func perform(_ command: Command) {
        do {
            switch try player.perform(command, settings: settings) {
            case .done(let feedback): feedback.map(bar.showFeedback)
            case .notAnEngineCommand: performInterface(command)
            }
        } catch {
            bar.showFeedback("Error: \(error)")
        }
    }

    private func performInterface(_ command: Command) {
        switch command {
        case .action(.fullscreen): window?.toggleFullScreen(nil)
        case .action(.toggleBar): content.barHidden.toggle()
        case .action, .seekFraction, .setVolume: preconditionFailure("\(command) is not handled by the window")
        }
    }

    private func handle(_ event: MpvPlayer.Event) {
        switch event {
        case .loadFailed(let error): fail(error)
        case .time(let seconds): bar.setTime(seconds)
        case .duration(let seconds): bar.setDuration(seconds)
        case .paused(let paused): bar.setPaused(paused)
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

import AppKit
import EVPCore

/// One window playing one file.
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private struct NoOpenGL: LocalizedError {
        var errorDescription: String? { "OpenGL is not available" }
    }

    var onClose: ((PlayerWindowController) -> Void)?
    private let player: MpvPlayer
    private let video: GLVideoView

    init(_ request: OpenRequest) throws {
        player = try MpvPlayer(output: .video)
        guard let video = GLVideoView(player: player) else { throw NoOpenGL() }
        self.video = video
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = video
        window.title = request.file.lastPathComponent
        window.representedURL = request.file
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        player.onEvent = { [weak self] event in
            if case .loadFailed(let error) = event { self?.fail(error) }
        }
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

    private func fail(_ error: Error) {
        NSAlert(error: error).runModal()
        close()
    }
}

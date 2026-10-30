import AppKit
import EVPCore

/// Draws the player's frames. mpv fits the picture into the view with black bars, whatever the view's size.
final class GLVideoView: NSOpenGLView {
    private let player: MpvPlayer
    /// The renderer is attached: the file can be loaded now.
    var onReady: (() -> Void)?

    init?(player: MpvPlayer) {
        self.player = player
        let attributes: [NSOpenGLPixelFormatAttribute] = [UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
                                                          UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), 0]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { return nil }
        super.init(frame: .zero, pixelFormat: format)
        wantsBestResolutionOpenGLSurface = true
        player.onNeedsRedraw = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("GLVideoView is created in code") }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        var vsync: Int32 = 1
        openGLContext?.setValues(&vsync, for: .swapInterval)
        openGLContext?.makeCurrentContext()
        do { try player.attachRenderer() } catch { preconditionFailure("render context: \(error)") }
        onReady?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = convertToBacking(bounds).size
        guard size.width >= 1, size.height >= 1 else { return }
        player.render(width: Int32(size.width), height: Int32(size.height))
        openGLContext?.flushBuffer()
        player.didSwap()
    }

    /// Frees mpv's GL resources while the context is still alive.
    func shutdown() {
        openGLContext?.makeCurrentContext()
        player.detachRenderer()
    }
}

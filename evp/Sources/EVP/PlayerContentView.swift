import AppKit
import EVPCore

/// The window's content: the video above the control bar, laid out by `PlayerLayout` so they never overlap.
final class PlayerContentView: NSView {
    let video: GLVideoView
    let bar: ControlBar
    var barHidden = false {
        didSet { needsLayout = true }
    }

    init(video: GLVideoView, bar: ControlBar) {
        (self.video, self.bar) = (video, bar)
        super.init(frame: .zero)
        addSubview(video)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("PlayerContentView is created in code") }

    override func layout() {
        super.layout()
        let frames = PlayerLayout.frames(in: bounds, barHidden: barHidden)
        video.frame = frames.video
        bar.frame = frames.bar
        bar.isHidden = barHidden
    }
}

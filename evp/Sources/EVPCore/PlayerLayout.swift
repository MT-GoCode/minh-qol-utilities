import CoreGraphics

/// Where the video and the control bar go in a window: the bar is a fixed strip below the video, never over it.
public enum PlayerLayout {
    /// The controls row (28) with 8 below, 6 between the rows, the progress strip (26: a 16 pt track area with 10 pt
    /// above it for the hover time) and 4 above: 8 + 28 + 6 + 26 + 4.
    public static let barHeight: CGFloat = 72

    /// Frames in AppKit coordinates (origin at the bottom left). With the bar hidden the video fills `bounds`.
    public static func frames(in bounds: CGRect, barHidden: Bool) -> (video: CGRect, bar: CGRect) {
        guard !barHidden else { return (bounds, .zero) }
        let bar = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(barHeight, bounds.height))
        let video = CGRect(x: bounds.minX, y: bar.maxY, width: bounds.width, height: bounds.height - bar.height)
        return (video, bar)
    }
}

/// Which of the bar's foldable items fit; the rest go into the `…` menu.
public enum BarLayout {
    /// `foldableWidths` are in keep-first order. Returns how many fit next to `essentialWidth`, counting the
    /// overflow button when anything is folded. Items are separated by `gap`.
    public static func visibleCount(available: CGFloat, essentialWidth: CGFloat, foldableWidths: [CGFloat], gap: CGFloat, overflowWidth: CGFloat) -> Int {
        var used = essentialWidth
        var count = 0
        for width in foldableWidths {
            let next = used + gap + width
            let reserve = count + 1 < foldableWidths.count ? gap + overflowWidth : 0
            guard next + reserve <= available else { break }
            used = next
            count += 1
        }
        return count
    }
}

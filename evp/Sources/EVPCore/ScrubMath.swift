import CoreGraphics

/// The arithmetic of the progress strip: where in the video a point on the strip is.
public enum ScrubMath {
    /// The fraction (0 to 1) of the video at horizontal position `x` on a strip `width` wide; outside the strip it clamps.
    public static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// The hover time shown above the pointer.
    public static func tooltip(fraction: Double, duration: Double) -> String {
        TimeFormat.format(fraction * duration)
    }
}

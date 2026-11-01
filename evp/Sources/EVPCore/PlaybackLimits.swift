/// The ranges playback accepts. Settings validates against them and the engine clamps to them; neither owns them.
public enum PlaybackLimits {
    /// mpv's documented limits for `speed`.
    public static let speed = 0.01...100.0
    /// This app's decision: no boost above 100.
    public static let volume = 0.0...100.0

    /// Two decimals, the engine's precision, with at least one kept: `1.0x`, `1.3x`, `1.25x`.
    public static func label(speed: Double) -> String {
        let text = String(format: "%.2f", speed)
        return (text.hasSuffix("0") ? String(text.dropLast()) : text) + "x"
    }
}

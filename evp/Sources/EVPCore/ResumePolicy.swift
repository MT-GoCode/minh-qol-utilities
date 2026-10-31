public enum ResumePolicy {
    /// A video within this many seconds of its end reopens from the start ("about 5 seconds", Minh's accepted proposal).
    public static let endMargin = 5.0

    /// Call only once the duration is known: an unknown duration of 0 would reset every position.
    public static func startPosition(saved: Double, duration: Double) -> Double {
        saved >= duration - endMargin ? 0 : max(saved, 0)
    }
}

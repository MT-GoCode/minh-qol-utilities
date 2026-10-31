/// What the window controller executes: a bindable `Action`, or an operation that carries a value no key can name.
public enum Command: Equatable {
    case action(Action)
    /// From the time field: go to a position, or move by an offset.
    case seek(TimeInput)
    /// From the scrub bar: a fraction (0 to 1) of the video.
    case seekFraction(Double)
    /// From the volume slider: an absolute volume (0 to 100).
    case setVolume(Double)
}

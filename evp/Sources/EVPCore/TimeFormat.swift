import Foundation

public enum TimeInput: Equatable {
    case absolute(Double)
    case relative(Double)
}

/// The `4:52` notation of the time field: `m:ss`, `h:mm:ss`, plain seconds, and a leading `+` or `-` for relative.
public enum TimeFormat {
    /// nil for anything that is not a valid time.
    public static func parse(_ text: String) -> TimeInput? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        var sign: Double?
        if let first = body.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            body = body.dropFirst()
        }
        guard let seconds = clock(body) else { return nil }
        return sign.map { .relative($0 * seconds) } ?? .absolute(seconds)
    }

    /// `m:ss`, or `h:mm:ss` from one hour up; fractions are dropped.
    public static func format(_ seconds: Double) -> String {
        let total = Int(exactly: seconds.rounded(.down)).map { max(0, $0) } ?? 0
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func clock(_ text: Substring) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        // Every field after the first is minutes or seconds.
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return Double(numbers.reduce(0) { $0 * 60 + $1 })
    }
}

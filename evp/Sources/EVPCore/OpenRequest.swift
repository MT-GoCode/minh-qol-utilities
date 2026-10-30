import Foundation

/// A request to play one file, from Finder (a file URL) or from the `evp` command (`evp://open?path=...&time=4:52`).
public struct OpenRequest: Equatable {
    public struct Failure: Error, Equatable, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    public let file: URL
    /// Absolute start position in seconds.
    public let start: Double?

    public init(url: URL) throws {
        if url.isFileURL {
            (file, start) = (url.standardizedFileURL, nil)
            return
        }
        guard url.scheme == "evp", url.host == "open", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw Failure(reason: "not an evp://open URL: \(url.absoluteString)")
        }
        guard let path = items.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else {
            throw Failure(reason: "evp://open needs an absolute path")
        }
        file = URL(fileURLWithPath: path)
        switch items.first(where: { $0.name == "time" })?.value.map(TimeFormat.parse) {
        case nil: start = nil
        case .some(.absolute(let seconds)): start = seconds
        case .some: throw Failure(reason: "time must be a position such as 4:52, not an offset or text")
        }
    }
}

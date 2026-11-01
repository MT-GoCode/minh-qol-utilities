import Foundation

public struct Paths: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".transcribe-everything")) {
        self.root = root
    }
    public var config: URL { root.appending(path: "config.json") }
    public var transcripts: URL { root.appending(path: "transcripts") }
}

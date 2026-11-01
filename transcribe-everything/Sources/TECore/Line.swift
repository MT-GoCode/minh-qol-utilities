import Foundation

public struct Line: Codable, Equatable, Sendable {
    public var t: Date  // wall clock at commit
    public var src: SourceID
    public var tag: String
    public var spk: Int
    public var text: String
    public var start: Double, end: Double  // seconds on the source's sample clock
    public init(t: Date, src: SourceID, tag: String, spk: Int, text: String, start: Double, end: Double) {
        self.t = t
        self.src = src
        self.tag = tag
        self.spk = spk
        self.text = text
        self.start = start
        self.end = end
    }
}

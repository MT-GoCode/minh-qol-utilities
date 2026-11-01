public struct SourceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct Chunk: Sendable {
    public static let sampleRate = 16_000
    public let samples: [Float]
    public let index: Int  // sample index of samples[0] on the source's clock
    public init(samples: [Float], index: Int) {
        self.samples = samples
        self.index = index
    }
}

public protocol AudioSource: Sendable {
    var id: SourceID { get }
    var tag: String { get }
    /// Finishing means the source ended; throwing means it failed.
    func chunks() -> AsyncThrowingStream<Chunk, Error>
    func stop()
}

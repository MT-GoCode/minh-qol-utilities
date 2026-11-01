import FluidAudio

public actor Embedder {
    private let diarizer: DiarizerManager
    private init(_ diarizer: DiarizerManager) { self.diarizer = diarizer }

    public static func load() async throws -> Embedder {
        let d = DiarizerManager()
        d.initialize(models: try await DiarizerModels.download())
        return Embedder(d)
    }

    public func embed(_ window: [Float]) throws -> [Float] { try diarizer.extractSpeakerEmbedding(from: window) }
}

import FluidAudio

public actor Transcriber {
    private let asr: AsrManager
    private init(_ asr: AsrManager) { self.asr = asr }

    public static func load() async throws -> Transcriber {
        let version = AsrModelVersion.ultra
        let asr = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))
        return Transcriber(asr)
    }

    public func transcribe(_ samples: [Float]) async throws -> ASRResult {
        // FluidAudio rejects audio under 0.3 s.
        let short = max(0, ASRConstants.minimumRequiredSamples(forSampleRate: Chunk.sampleRate) - samples.count)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples + [Float](repeating: 0, count: short), decoderState: &state)
    }
}

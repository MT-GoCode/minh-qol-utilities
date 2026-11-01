import FluidAudio
import Foundation

public enum Priority: Sendable { case commit, provisional }

/// One finished decode, for latency tests.
public struct Decode: Sendable {
    public let priority: Priority
    public let submitted, started, finished: Date
}

public actor Transcriber {
    private let asr: AsrManager
    private var busy = false
    private var waiting: [(priority: Priority, go: CheckedContinuation<Void, Never>)] = []
    private var onDecode: (@Sendable (Decode) -> Void)?
    private init(_ asr: AsrManager) { self.asr = asr }

    public static func load() async throws -> Transcriber {
        let version = AsrModelVersion.ultra
        let asr = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))
        return Transcriber(asr)
    }

    public var pending: Int { waiting.count + (busy ? 1 : 0) }
    public func observe(_ f: (@Sendable (Decode) -> Void)?) { onDecode = f }

    /// One decode at a time. Commits first; provisionals in arrival order, which is round-robin because each source queues at most one.
    public func transcribe(_ samples: [Float], priority: Priority = .commit) async throws -> ASRResult {
        let submitted = Date()
        if busy {
            await withCheckedContinuation { waiting.append((priority, $0)) }
        } else {
            busy = true
        }
        let started = Date()
        defer {
            onDecode?(Decode(priority: priority, submitted: submitted, started: started, finished: Date()))
            if let i = waiting.firstIndex(where: { $0.priority == .commit }) ?? waiting.indices.first {
                waiting.remove(at: i).go.resume()  // `busy` stays true: the model passes straight to the next
            } else {
                busy = false
            }
        }
        // FluidAudio rejects audio under 0.3 s.
        let short = max(0, ASRConstants.minimumRequiredSamples(forSampleRate: Chunk.sampleRate) - samples.count)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples + [Float](repeating: 0, count: short), decoderState: &state)
    }
}

import FluidAudio
import Foundation

struct SourcePipeline: Sendable {
    let source: any AudioSource
    let chunks: AsyncThrowingStream<Chunk, Error>
    let vad: VadManager
    let transcriber: Transcriber
    let store: TranscriptStore
    let config: ConfigStore

    private struct Open {
        var start: Int
        var probs: [(end: Int, p: Float)] = []
    }

    /// Returns when the source finishes; rethrows its failure after committing the open segment.
    func run() async throws {
        let sr = Chunk.sampleRate, chunk = VadManager.chunkSize
        var base = 0, samples: [Float] = []  // samples[0] is source sample `base`
        var fed = 0  // next sample not yet sent to the VAD
        var state = VadStreamState.initial()
        var cfg = await config.current
        var open: Open?

        func commit(_ s: Int, _ e: Int) async throws {
            let text = try await transcriber.transcribe(Array(samples[(s - base)..<(e - base)])).text
            // A cut in silence, a VAD blip or a silent tail decodes to nothing; never a blank caption.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await store.append(Line(t: Date(), src: source.id, tag: source.tag, spk: 1, text: text,
                                        start: Double(s) / Double(sr), end: Double(e) / Double(sr)))
        }
        func flush() async throws {
            guard let o = open else { return }
            open = nil
            try await commit(o.start, base + samples.count)
        }

        do {
            for try await c in chunks {
                precondition(c.index == base + samples.count, "source chunks must be contiguous")
                samples += c.samples
                while base + samples.count - fed >= chunk {
                    let lo = fed - base
                    let r = try await vad.processStreamingChunk(
                        Array(samples[lo..<lo + chunk]), state: state, config: VadSegmentationConfig(minSilenceDuration: cfg.minSilence))
                    state = r.state
                    fed += chunk
                    if let e = r.event, e.isStart {
                        open = Open(start: e.sampleIndex)
                        cfg = await config.current
                    }
                    open?.probs.append((fed, r.probability))
                    if let e = r.event, e.isEnd, let o = open {
                        open = nil
                        // After a cut landing in the pause, the end event precedes the cut: nothing is left to commit.
                        if e.sampleIndex > o.start { try await commit(o.start, e.sampleIndex) }
                    } else if let o = open, fed - o.start >= Int(cfg.maxSegment * Double(sr)) {
                        let cut = o.probs.filter { $0.end >= fed - 2 * sr }.min { $0.p < $1.p }!.end  // quietest chunk of the last 2 s
                        open = Open(start: cut, probs: o.probs.filter { $0.end > cut })
                        try await commit(o.start, cut)
                        cfg = await config.current
                    }
                    // A start event reaches back at most one chunk plus speech padding, so idle keeps two chunks.
                    let drop = max(0, (open?.start ?? fed - 2 * chunk) - base)
                    samples.removeFirst(drop)
                    base += drop
                }
            }
        } catch {
            try? await flush()
            throw error
        }
        try await flush()
    }
}

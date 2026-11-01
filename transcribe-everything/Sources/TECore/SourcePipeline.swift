import FluidAudio
import Foundation

struct SourcePipeline: Sendable {
    let source: any AudioSource
    let chunks: AsyncThrowingStream<Chunk, Error>
    let vad: VadManager
    let transcriber: Transcriber
    let embedder: Embedder
    let store: TranscriptStore
    let config: ConfigStore
    let tracker: CentroidTracker

    private struct Open {
        var start: Int
        var next: Int  // start of the next unembedded window
        var probs: [(end: Int, p: Float)] = []
        var wins: [(mid: Int, spk: Int)] = []
    }

    /// Returns when the source finishes; rethrows its failure after committing the open segment.
    func run() async throws {
        let sr = Chunk.sampleRate, chunk = VadManager.chunkSize
        var base = 0, samples: [Float] = []  // samples[0] is source sample `base`
        var fed = 0  // next sample not yet sent to the VAD
        var state = VadStreamState.initial()
        var cfg = await config.current
        var open: Open?

        // One Line per run of same-speaker words.
        func commit(_ o: Open, _ e: Int) async throws {
            let t0 = Double(o.start) / Double(sr), end = Double(e) / Double(sr)
            let r = try await transcriber.transcribe(Array(samples[(o.start - base)..<(e - base)]))
            let words = buildWordTimings(from: r.tokenTimings!)
            guard !words.isEmpty else { return }  // a cut in silence or a VAD blip is never a blank caption
            let mine = o.wins.filter { $0.mid < e }
            let inherited = await tracker.previous
            let labels = words.map { w -> Int in
                let m = t0 + (w.startTime + w.endTime) / 2
                return mine.min { abs(Double($0.mid) / Double(sr) - m) < abs(Double($1.mid) / Double(sr) - m) }?.spk ?? inherited
            }
            let now = Date()
            var lo = 0
            while lo < words.count {
                var hi = lo + 1
                while hi < words.count, labels[hi] == labels[lo] { hi += 1 }
                try await store.append(Line(t: now, src: source.id, tag: source.tag, spk: labels[lo],
                                            text: words[lo..<hi].map(\.word).joined(separator: " "),
                                            start: lo == 0 ? t0 : t0 + words[lo].startTime,
                                            end: hi == words.count ? end : t0 + words[hi - 1].endTime))
                lo = hi
            }
        }
        func flush() async throws {
            guard let o = open else { return }
            open = nil
            try await commit(o, base + samples.count)
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
                        cfg = await config.current
                        open = Open(start: e.sampleIndex, next: e.sampleIndex)
                    }
                    open?.probs.append((fed, r.probability))
                    if let e = r.event, e.isEnd, let o = open {
                        open = nil
                        // After a cut landing in the pause, the end event precedes the cut: nothing is left to commit.
                        if e.sampleIndex > o.start { try await commit(o, e.sampleIndex) }
                    } else if var o = open {
                        let win = Int(cfg.speakerWindow * Double(sr)), hop = Int(cfg.speakerHop * Double(sr))
                        while o.next + win <= fed {
                            let w = Array(samples[(o.next - base)..<(o.next + win - base)])
                            let spk = await tracker.assign(window: try await embedder.embed(w), threshold: cfg.speakerThreshold,
                                                           confirmWindows: cfg.speakerConfirmWindows)
                            o.wins.append((o.next + win / 2, spk))
                            o.next += hop
                        }
                        open = o
                        if fed - o.start >= Int(cfg.maxSegment * Double(sr)) {
                            let cut = o.probs.filter { $0.end >= fed - 2 * sr }.min { $0.p < $1.p }!.end  // quietest chunk of the last 2 s
                            open = Open(start: cut, next: o.next, probs: o.probs.filter { $0.end > cut }, wins: o.wins.filter { $0.mid >= cut })
                            cfg = await config.current
                            try await commit(o, cut)
                        }
                    }
                    // A start event reaches back at most one chunk plus speech padding, so idle keeps two chunks.
                    // A window can straddle a cut, so an open segment keeps from whichever is earlier.
                    let drop = max(0, (open.map { min($0.start, $0.next) } ?? fed - 2 * chunk) - base)
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

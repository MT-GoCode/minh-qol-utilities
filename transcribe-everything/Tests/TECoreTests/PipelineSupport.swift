import AVFoundation
import FluidAudio
import TECore
import XCTest
import os

enum Models {
    static let transcriber = Task { try await Transcriber.load() }
    static let vad = Task { try await VadManager() }
    static let embedder = Task { try await Embedder.load() }
}

extension Fixtures {
    static var conversationWav: URL { dir.appending(path: "conversation.wav") }
    static var continuousWav: URL { dir.appending(path: "continuous.wav") }
    static func continuousText() throws -> String {
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "continuous.json"))) as! [String: Any]
        return o["text"] as! String
    }
    static func oracleWords(_ i: Int) throws -> [(start: Double, end: Double)] {
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: String(format: "oracle/%02d.json", i)))) as! [String: Any]
        return (o["wordTimings"] as! [[String: Any]]).map { ($0["startTime"] as! Double, $0["endTime"] as! Double) }
    }
}

struct Seg: Equatable {
    let start, end: Double
    let text: String
}

func segs(_ lines: [Line], src: String) -> [Seg] {
    lines.filter { $0.src.rawValue == src }.map { Seg(start: $0.start, end: $0.end, text: $0.text) }
}

func makeEngine(_ root: URL) async throws -> (Engine, TranscriptStore) {
    let store = try TranscriptStore(paths: Paths(root: root))
    return (Engine(transcriber: try await Models.transcriber.value, embedder: try await Models.embedder.value, vad: try await Models.vad.value, store: store, config: ConfigStore()), store)
}

func awaitEnds(_ engine: Engine, _ n: Int) async -> [SourceEnd] {
    var out: [SourceEnd] = []
    for await e in engine.ended {
        out.append(e)
        if out.count == n { break }
    }
    return out
}

func runToEnd(_ sources: [any TECore.AudioSource], _ root: URL) async throws -> (lines: [Line], ends: [SourceEnd], file: URL) {
    let (engine, store) = try await makeEngine(root)
    for s in sources { await engine.attach(s) }
    let ends = await awaitEnds(engine, sources.count)
    return (await store.snapshot().lines, ends, store.file)
}

func truncated(_ url: URL, frames: Int, in dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let input = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    try input.read(into: buffer, frameCount: AVAudioFrameCount(frames))
    let out = dir.appending(path: "trunc.wav")
    do {
        let output = try AVAudioFile(forWriting: out, settings: input.fileFormat.settings)
        try output.write(from: buffer)
    }
    return out
}

struct Boom: Error {}

/// Forwards `base` and throws when it reaches a chunk at or past `failAt`.
struct FailingSource: TECore.AudioSource {
    let base: FileSource, failAt: Int
    var id: SourceID { base.id }
    var tag: String { base.tag }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    for try await chunk in base.chunks() {
                        if chunk.index >= failAt { throw Boom() }
                        c.yield(chunk)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func stop() { base.stop() }
}

/// Re-chunks `base` to a size that is not the VAD's, as real capture buffers are.
struct RechunkedSource: TECore.AudioSource {
    let base: FileSource, size: Int
    var id: SourceID { base.id }
    var tag: String { base.tag }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    let all = try await collect(base).flatMap(\.samples)
                    for lo in stride(from: 0, to: all.count, by: size) {
                        c.yield(Chunk(samples: Array(all[lo..<min(lo + size, all.count)]), index: lo))
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func stop() { base.stop() }
}

/// Adjacent lines in one group with different speakers.
func splits(_ lines: [Line], by group: (Line) -> Int) -> Int {
    zip(lines, lines.dropFirst()).filter { group($0) == group($1) && $0.spk != $1.spk }.count
}

func turnOf(_ l: Line, _ turns: [Fixtures.Turn]) -> Int {
    let mid = (l.start + l.end) / 2
    return turns.firstIndex { $0.start <= mid && mid <= $0.end } ?? -1
}

/// Yields chunks up to sample `upTo`, then delivers nothing until `stop()`: a live source that has gone quiet.
final class HangingSource: TECore.AudioSource, @unchecked Sendable {
    let base: FileSource, upTo: Int
    var id: SourceID { base.id }
    var tag: String { base.tag }
    private let cont = OSAllocatedUnfairLock<AsyncThrowingStream<Chunk, Error>.Continuation?>(initialState: nil)
    init(base: FileSource, upTo: Int) {
        self.base = base
        self.upTo = upTo
    }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            cont.withLock { $0 = c }
            let t = Task { for try await ch in base.chunks() where ch.index + ch.samples.count <= upTo { c.yield(ch) } }
            c.onTermination = { _ in t.cancel() }
        }
    }
    func stop() { cont.withLock { $0?.finish() } }
}

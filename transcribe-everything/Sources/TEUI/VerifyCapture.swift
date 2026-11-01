import Foundation
import TECore
import os

/// {"op":"capture","sources":[{"id":"qt","kind":"app","tag":"QuickTime","pid":123}],"stallLimit":1.0}   (stallLimit optional, seconds)
struct CaptureSpec: Decodable {
    enum Src: Decodable {
        case app(id: String, tag: String, pid: pid_t)
        private enum Key: String, CodingKey { case id, kind, tag, pid }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "app": self = .app(id: try c.decode(String.self, forKey: .id), tag: try c.decode(String.self, forKey: .tag), pid: try c.decode(pid_t.self, forKey: .pid))
            case let k: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(k)")
            }
        }
    }
    let sources: [Src]
    let stallLimit: Double?

    /// The one place a source kind becomes an `AudioSource`; a new kind is a new case here.
    func build() -> [any AudioSource] {
        let limit = stallLimit.map { Duration.seconds($0) } ?? StallGuard.limit
        return sources.map { src in
            switch src { case .app(let id, let tag, let pid): AppSource(pid: pid, id: SourceID(rawValue: id), tag: tag, stallLimit: limit) }
        }
    }
}

private struct Arrival: Encodable, Sendable { let end: Int, wall: Date }   // wall = when the chunk ending at sample `end` arrived
private struct Shown: Encodable, Sendable { let t: Date, lines: [String: Int], tails: [String] }   // one per store change
private struct Ended: Encodable, Sendable { let id: String, error: String? }
private struct SourceReport: Encodable { let file: String, arrivals: [Arrival] }
private struct CaptureReport: Encodable {
    let ended: [Ended], sources: [String: SourceReport], decodes: [Decode], shown: [Shown], lines: [Line]
}

/// Forwards a source and appends every sample to a raw Float32 file: the test's ground truth for what capture delivered.
private final class Recorded: AudioSource, @unchecked Sendable {
    let base: any AudioSource
    var id: SourceID { base.id }
    var tag: String { base.tag }
    let started: AsyncStream<Void>   // finishes at the first chunk, or at the stream's end or failure if none came
    let arrivals = OSAllocatedUnfairLock<[Arrival]>(initialState: [])
    private let startedC: AsyncStream<Void>.Continuation
    private let handle: FileHandle
    init(_ base: any AudioSource, file: URL) throws {
        self.base = base
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
        (started, startedC) = AsyncStream.makeStream(of: Void.self)
    }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                defer { startedC.finish() }
                do {
                    for try await chunk in base.chunks() {
                        try handle.write(contentsOf: chunk.samples.withUnsafeBytes { Data($0) })
                        arrivals.withLock { $0.append(Arrival(end: chunk.index + chunk.samples.count, wall: Date())) }
                        startedC.finish()
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

extension AppController {
    /// `ready` and `stop` under the data root are the whole control channel; the test owns that root.
    func capture(_ spec: CaptureSpec) async throws -> [String: Any] {
        let root = paths.root
        let recs = try spec.build().map { try Recorded($0, file: root.appending(path: "\($0.id.rawValue).f32")) }
        let decodes = OSAllocatedUnfairLock<[Decode]>(initialState: [])
        let shown = OSAllocatedUnfairLock<[Shown]>(initialState: [])
        let early = OSAllocatedUnfairLock<[Ended]>(initialState: [])
        await transcriber.observe { d in decodes.withLock { $0.append(d) } }
        let watcher = Task {
            for await _ in store.changes {
                let s = await store.snapshot()
                let row = Shown(t: Date(), lines: Dictionary(grouping: s.lines, by: \.src.rawValue).mapValues(\.count), tails: s.tails.map(\.src.rawValue))
                shown.withLock { $0.append(row) }
            }
        }
        // Test pacing, far below the second-scale bounds; not product behaviour.
        let stopRequested: @Sendable () async -> Void = {
            while !FileManager.default.fileExists(atPath: root.appending(path: "stop").path), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        }
        for r in recs { await engine.attach(r) }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { for r in recs { for await _ in r.started {} } }  // every source delivered, or already failed
            g.addTask { await stopRequested() }  // a source that delivers nothing must not outlive its test
            await g.next()
            g.cancelAll()
        }
        FileManager.default.createFile(atPath: root.appending(path: "ready").path, contents: nil)
        await withTaskGroup(of: Void.self) { g in
            g.addTask {
                for await e in self.engine.ended {
                    let n = early.withLock { $0.append(Ended(id: e.id.rawValue, error: e.error.map { "\($0)" })); return $0.count }
                    if n == recs.count { return }
                }
            }
            g.addTask { await stopRequested() }
            await g.next()
            g.cancelAll()
        }
        for r in recs { await engine.detach(r.id) }  // no-op for ended sources; commits an open segment
        watcher.cancel()
        await transcriber.observe(nil)
        let report = CaptureReport(
            ended: early.withLock { $0 },
            sources: Dictionary(uniqueKeysWithValues: recs.map { ($0.id.rawValue, SourceReport(file: "\($0.id.rawValue).f32", arrivals: $0.arrivals.withLock { $0 })) }),
            decodes: decodes.withLock { $0 }, shown: shown.withLock { $0 }, lines: await store.snapshot().lines)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
    }
}

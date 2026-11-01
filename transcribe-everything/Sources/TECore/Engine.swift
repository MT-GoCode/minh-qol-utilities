import FluidAudio

public struct SourceEnd: Sendable {
    public let id: SourceID
    public let error: Error?  // nil = finished
}

public actor Engine {
    public nonisolated let ended: AsyncStream<SourceEnd>
    private let endedContinuation: AsyncStream<SourceEnd>.Continuation
    private let transcriber: Transcriber, vad: VadManager, store: TranscriptStore, config: ConfigStore
    private var running: [SourceID: (source: any AudioSource, task: Task<Void, Never>)] = [:]

    public init(transcriber: Transcriber, vad: VadManager, store: TranscriptStore, config: ConfigStore) {
        (ended, endedContinuation) = AsyncStream.makeStream(of: SourceEnd.self)
        self.transcriber = transcriber
        self.vad = vad
        self.store = store
        self.config = config
    }

    public func attach(_ source: any AudioSource) {
        precondition(running[source.id] == nil, "source already attached")
        // The stream exists before attach returns, so an immediate detach always stops it.
        let pipeline = SourcePipeline(source: source, chunks: source.chunks(), vad: vad, transcriber: transcriber, store: store, config: config)
        running[source.id] = (source, Task {
            let error: Error?
            do {
                try await pipeline.run()
                error = nil
            } catch let e { error = e }
            await self.finish(SourceEnd(id: source.id, error: error))
        })
    }

    /// Stops the source and waits for its open segment to commit.
    public func detach(_ id: SourceID) async {
        guard let r = running[id] else { return }
        r.source.stop()
        await r.task.value
    }

    private func finish(_ end: SourceEnd) {
        running[end.id] = nil
        endedContinuation.yield(end)
    }
}

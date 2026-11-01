import FluidAudio
import TECore

/// The one construction of the running core; a normal launch and `verify` both use it.
public final class AppController {
    public let transcriber: Transcriber
    public let engine: Engine
    public let store: TranscriptStore

    public static func start(paths: Paths = Paths()) async throws -> AppController {
        async let transcriber = Transcriber.load()
        async let embedder = Embedder.load()
        async let vad = VadManager()
        let store = try TranscriptStore(paths: paths)
        let t = try await transcriber
        return AppController(t, store, Engine(transcriber: t, embedder: try await embedder, vad: try await vad, store: store, config: ConfigStore()))
    }

    private init(_ transcriber: Transcriber, _ store: TranscriptStore, _ engine: Engine) {
        self.transcriber = transcriber
        self.store = store
        self.engine = engine
    }
}

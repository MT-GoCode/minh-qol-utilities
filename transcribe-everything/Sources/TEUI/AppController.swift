import AppKit
import FluidAudio
import TECore

public struct CoreModels: Sendable {
    public let transcriber: Transcriber, embedder: Embedder, vad: VadManager
    public init(transcriber: Transcriber, embedder: Embedder, vad: VadManager) {
        self.transcriber = transcriber
        self.embedder = embedder
        self.vad = vad
    }
    public static func load() async throws -> CoreModels {
        async let t = Transcriber.load()
        async let e = Embedder.load()
        async let v = VadManager()
        return CoreModels(transcriber: try await t, embedder: try await e, vad: try await v)
    }
}

/// One engine start: a new store and engine over already loaded models and the process's one `ConfigStore`.
public final class AppController {
    public let paths: Paths, transcriber: Transcriber, engine: Engine, store: TranscriptStore
    public init(paths: Paths, models: CoreModels, config: ConfigStore) throws {
        self.paths = paths
        transcriber = models.transcriber
        store = try TranscriptStore(paths: paths)
        engine = Engine(transcriber: models.transcriber, embedder: models.embedder, vad: models.vad, store: store, config: config)
    }
    /// For `verify`: no permissions, no menu, defaults from an in-memory config so a scenario never depends on a user's file.
    public static func start(paths: Paths = Paths()) async throws -> AppController {
        try AppController(paths: paths, models: try await CoreModels.load(), config: ConfigStore())
    }
}

public enum EngineState: Equatable, Sendable { case stopped, starting, running, failed(String) }

/// What the user can attach. The id is the single identity everything routes on.
public enum Target: Equatable, Sendable {
    case mic
    case app(bundleId: String, tag: String)
    public var id: SourceID {
        switch self {
        case .mic: SourceID(rawValue: "mic")
        case .app(let b, _): SourceID(rawValue: b)
        }
    }
    public var tag: String {
        switch self {
        case .mic: "Mic"
        case .app(_, let t): t
        }
    }

    struct AppGone: Error, CustomStringConvertible { var description: String { "not running" } }
    /// The one place a target becomes an `AudioSource`; the pid is looked up now, because SCK delivers silence for a dead pid.
    public static func source(_ t: Target) throws -> any TECore.AudioSource {
        switch t {
        case .mic: return MicSource(id: t.id)
        case .app(let bundleId, let tag):
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier else { throw AppGone() }
            return AppSource(pid: pid, id: t.id, tag: tag)
        }
    }
}

/// Single owner of state, the attach set, failure reasons and the engine's lifetime.
@MainActor public final class Session {
    public private(set) var state = EngineState.stopped { didSet { notify() } }
    public private(set) var attached: [Target] = [] { didSet { notify() } }  // checkmarks, in attach order
    public private(set) var failures: [SourceID: String] = [:] { didSet { notify() } }  // "<tag>: <reason>"
    public private(set) var core: AppController?
    public let permissions: any Permissions, config: ConfigStore
    private let paths: Paths
    private let loader: @MainActor () async throws -> CoreModels, makeSource: @MainActor (Target) throws -> any TECore.AudioSource
    private let onStart: @MainActor (TranscriptStore) -> Void, terminate: @MainActor () -> Void
    private var models: CoreModels?, booting: Task<Void, Never>?, watcher: Task<Void, Never>?
    private var chain = Task<Void, Never> {}
    private var applied: Set<SourceID> = []  // ids the engine owns right now
    private var observers: [@MainActor () -> Void] = []

    /// `onStart` runs at every running start with the new store; no default, so a missing wire is a compile error.
    public init(paths: Paths = Paths(), permissions: any Permissions = SystemPermissions(), config: ConfigStore,
                loader: @escaping @MainActor () async throws -> CoreModels = { try await CoreModels.load() },
                makeSource: @escaping @MainActor (Target) throws -> any TECore.AudioSource = { try Target.source($0) },
                onStart: @escaping @MainActor (TranscriptStore) -> Void,
                terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.paths = paths
        self.permissions = permissions
        self.config = config
        self.loader = loader
        self.makeSource = makeSource
        self.onStart = onStart
        self.terminate = terminate
    }

    /// Called synchronously after every change, in registration order.
    public func observe(_ f: @escaping @MainActor () -> Void) { observers.append(f) }
    private func notify() { for f in observers { f() } }

    /// Idempotent: a no-op while starting or running.
    public func start() {
        switch state {
        case .starting, .running: return
        case .stopped, .failed: break
        }
        state = .starting
        booting = Task { await boot() }
    }

    private struct Missing: Error, CustomStringConvertible {
        let names: [String]
        var description: String { "Missing permission: \(names.joined(separator: ", ")). Grant it in System Settings, then relaunch." }
    }

    private func boot() async {
        do {
            for p in Permission.allCases where !permissions.granted(p) { await permissions.request(p) }
            let missing = Permission.allCases.filter { !permissions.granted($0) }  // re-read: a grant may not be visible yet
            guard missing.isEmpty else { throw Missing(names: missing.map(\.rawValue)) }
            if models == nil { models = try await loader() }
            try Task.checkCancellation()  // Stop or Quit during starting wins here, before any store exists
            let core = try AppController(paths: paths, models: models!, config: config)
            self.core = core
            watcher = Task { for await e in core.engine.ended { sourceEnded(e) } }
            state = .running
            onStart(core.store)
            await serial { await self.reconcile() }  // restores the checkmarks; toggles made while starting are in `attached` already
        } catch is CancellationError {
        } catch { state = .failed("\(error)") }
    }

    /// Runs `op` after every earlier `serial` op: the only way the engine is touched, because an interleaved attach and detach of one id would leak a source.
    private func serial(_ op: @escaping @MainActor () async -> Void) async {
        let prev = chain
        let t = Task { await prev.value; await op() }
        chain = t
        await t.value
    }

    /// Makes the engine's sources equal `attached`: one step per loop turn, so `attached` is re-read after every await.
    private func reconcile() async {
        guard let core else { return }
        while true {
            if let t = attached.first(where: { !applied.contains($0.id) }) {
                applied.insert(t.id)
                do { await core.engine.attach(try makeSource(t)) } catch { fail(t, "\(error)") }  // the next turn drops the id from `applied`
            } else if let id = applied.first(where: { id in !attached.contains { $0.id == id } }) {
                applied.remove(id)
                await core.engine.detach(id)
            } else { return }
        }
    }

    private func fail(_ t: Target, _ reason: String) {
        attached.removeAll { $0.id == t.id }
        failures[t.id] = "\(t.tag): \(reason)"
    }

    /// A source that ended unchecks; one that failed unchecks with its reason. A user detach removed the id first, so it routes nowhere.
    private func sourceEnded(_ e: SourceEnd) {
        guard applied.remove(e.id) != nil, let t = attached.first(where: { $0.id == e.id }) else { return }
        if let error = e.error { fail(t, "\(error)") } else { attached.removeAll { $0.id == t.id } }
    }

    /// Records the choice always; the engine follows when it exists, else at the next running.
    public func toggle(_ t: Target) async {
        failures[t.id] = nil
        if attached.contains(where: { $0.id == t.id }) { attached.removeAll { $0.id == t.id } } else { attached.append(t) }
        await serial { await self.reconcile() }
    }

    /// Ends every source (each commits its open segment) and keeps the checkmarks.
    public func stop() async {
        booting?.cancel()
        await booting?.value
        booting = nil
        watcher?.cancel()
        watcher = nil
        await serial {
            guard let core = self.core else { return }
            for id in self.applied { await core.engine.detach(id) }
            self.applied = []
            self.core = nil
        }
        state = .stopped
    }

    public private(set) var deleteError: String? { didSet { notify() } }

    public func deleteOld() {
        deleteError = nil
        do { try TranscriptStore.deleteOld(in: paths, except: core?.store.file) } catch { deleteError = "Delete old transcriptions: \(error)" }
    }

    public func quit() async {
        await stop()
        terminate()
    }
}

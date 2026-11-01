import Foundation
import TECore

/// {"op":"session","bundleId":"com.apple.QuickTimePlayerX"}: what a click on an Attach row does, through the real catalog, Session and source lookup.
struct SessionSpec: Decodable { let bundleId: String }
struct WindowNotListed: Error, CustomStringConvertible {
    let bundleId: String
    var description: String { "no window of \(bundleId) in the catalog" }
}
struct SessionNeverRan: Error, CustomStringConvertible {
    let state: EngineState
    var description: String { "session state \(state)" }
}

extension AppController {
    @MainActor func session(_ spec: SessionSpec) async throws -> [String: Any] {
        guard let w = try await WindowCatalog.system().first(where: { $0.bundleId == spec.bundleId }) else { throw WindowNotListed(bundleId: spec.bundleId) }
        let session = Session(paths: Paths(root: paths.root.appending(path: "session")), config: ConfigStore(), onStart: { _ in })
        session.start()
        while session.state == .starting { try await Task.sleep(for: .milliseconds(50)) }
        guard session.state == .running, let core = session.core else { throw SessionNeverRan(state: session.state) }
        await session.toggle(.app(bundleId: w.bundleId, tag: String(w.title.prefix(5))))  // MenuBar's row action
        let root = paths.root
        FileManager.default.createFile(atPath: root.appending(path: "ready").path, contents: nil)
        while !FileManager.default.fileExists(atPath: root.appending(path: "stop").path) { try await Task.sleep(for: .milliseconds(100)) }
        await session.stop()
        let lines = await core.store.snapshot().lines
        return ["op": "session", "title": w.title, "attached": session.attached.map(\.tag), "failures": session.failures.values.sorted(),
                "tags": lines.map(\.tag), "text": lines.map(\.text).joined(separator: " ")]
    }
}

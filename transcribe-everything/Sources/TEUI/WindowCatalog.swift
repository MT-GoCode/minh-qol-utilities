import Foundation
import ScreenCaptureKit

@MainActor public final class WindowCatalog {
    public struct Window: Codable, Hashable, Sendable {
        public let bundleId: String, app: String, title: String
        public init(bundleId: String, app: String, title: String) {
            self.bundleId = bundleId
            self.app = app
            self.title = title
        }
    }
    public private(set) var windows: [Window] = []
    public private(set) var error: String?
    var onChange: (() -> Void)?
    private let permissions: any Permissions, fetch: () async throws -> [Window]
    private var timer: Timer?

    /// Refreshes now, then every `every` seconds (DECISIONS: launch and every 5 s).
    public init(permissions: any Permissions, every: TimeInterval = 5, fetch: @escaping () async throws -> [Window] = { try await WindowCatalog.system() }) {
        self.permissions = permissions
        self.fetch = fetch
        Task { await refresh() }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)  // an open menu runs the loop in .eventTracking, which .default timers never see
        timer = t
    }
    deinit { timer?.invalidate() }

    /// No SCK call without Screen Recording. A failed call keeps the last list and shows why. Publishes only a change, so an open menu is not torn down every 5 s.
    public func refresh() async {
        let next: ([Window], String?)
        if !permissions.granted(.screenRecording) {
            next = ([], "Screen Recording not granted")
        } else {
            do { next = (try await fetch(), nil) } catch { next = (windows, "Window list: \(error)") }
        }
        guard next != (windows, error) else { return }
        (windows, error) = next
        onChange?()
    }

    public nonisolated static func system() async throws -> [Window] {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).windows.compactMap { w in
            guard w.windowLayer == 0, let title = w.title, !title.isEmpty, let app = w.owningApplication, !app.bundleIdentifier.isEmpty else { return nil }
            return Window(bundleId: app.bundleIdentifier, app: app.applicationName, title: title)
        }
    }

    /// Distinct windows, one group per app, in menu order.
    public nonisolated static func groups(_ ws: [Window]) -> [[Window]] {
        Dictionary(grouping: Set(ws), by: \.bundleId).values
            .map { $0.sorted { $0.title < $1.title } }
            .sorted { ($0[0].app, $0[0].bundleId) < ($1[0].app, $1[0].bundleId) }
    }
}

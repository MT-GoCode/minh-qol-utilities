import AppKit
import ImageIO
import ScreenCaptureKit
import TECore
import UniformTypeIdentifiers

/// {"op":"overlay","lines":[…],"png":"<path>"}
struct OverlaySpec: Decodable {
    let lines: [String]
    let png: String
}
struct OverlayTextMismatch: Error { let seen: String }
struct OverlayWindowNeverListed: Error {}

extension AppController {
    /// Runs under the bundle that holds Screen Recording, so it captures its own panel in-process.
    @MainActor func overlay(_ s: OverlaySpec) async throws -> [String: Any] {
        NSApplication.shared.setActivationPolicy(.accessory)
        let id = SourceID(rawValue: "verify"), o = Overlay(config: ConfigStore(), attached: { [] })
        o.bind(store)
        for t in s.lines { try await store.commit([Line(t: Date(), src: id, tag: "v", spk: 1, text: t, start: 0, end: 0)], of: id) }
        await o.refresh().value
        guard o.text.string == s.lines.joined(separator: "\n") else { throw OverlayTextMismatch(seen: o.text.string) }
        CATransaction.flush()
        var window: SCWindow?
        let deadline = Date().addingTimeInterval(15)  // chrome_capture.sh waits this long for a window
        while window == nil {
            guard Date() < deadline else { throw OverlayWindowNeverListed() }
            window = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows.first { $0.windowID == CGWindowID(o.panel.windowNumber) }
            if window == nil { try await Task.sleep(for: .seconds(1.0 / 60)) }
        }
        let frame = o.panel.frame, scale = o.panel.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.width = Int(frame.width * scale)
        cfg.height = Int(frame.height * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window!), configuration: cfg)
        let url = URL(fileURLWithPath: s.png) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest), "writing \(s.png)")
        return ["op": "overlay", "png": s.png, "pointsWidth": frame.width, "pointsHeight": frame.height]
    }
}

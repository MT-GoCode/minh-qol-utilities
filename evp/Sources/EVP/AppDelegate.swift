import AppKit
import EVPCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var players: [PlayerWindowController] = []
    private var cascadePoint = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    /// Finder opens, `open file`, and `evp://` URLs from the `evp` command all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let controller = try PlayerWindowController(OpenRequest(url: url))
                controller.onClose = { [weak self] closed in self?.players.removeAll { $0 === closed } }
                players.append(controller)
                cascadePoint = controller.show(cascadingFrom: cascadePoint)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

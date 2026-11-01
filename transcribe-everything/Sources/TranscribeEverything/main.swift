import AppKit
import FluidAudio
import Foundation
import TECore
import TEUI

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "prefetch" where args.count == 1:
    _ = try await Transcriber.load()
    _ = try await VadManager()
    _ = try await DiarizerModels.download()
    print("models ready")
case "verify" where args.count == 2:
    do {
        try await Verify.run(scenario: URL(fileURLWithPath: args[1]))
    } catch {
        FileHandle.standardError.write(Data("verify: \(error)\n".utf8))
        exit(1)
    }
case nil:
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let config = ConfigStore()
    var session: Session!  // the overlay reads the session through closures and the session starts the overlay: neither can be built first
    let overlay = Overlay(config: config, attached: { Set(session.attached.map(\.id)) }, failures: { session.failures.values.sorted() })
    session = Session(config: config, onStart: { overlay.bind($0) })
    session.observe { overlay.refresh() }
    let catalog = WindowCatalog(permissions: session.permissions)
    let bar = MenuBar(session: session, catalog: catalog, settings: [overlay.hideShowItem])
    session.start()
    withExtendedLifetime((session, catalog, bar, overlay)) { app.run() }
default:
    FileHandle.standardError.write(Data("usage: TranscribeEverything [prefetch | verify <scenario.json>]\n".utf8))
    exit(2)
}

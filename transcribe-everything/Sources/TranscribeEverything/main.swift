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
    // The run loop must start from here, before any await: resumed after one, this code is itself a main-queue job, and app.run() inside it would keep every other main-actor task from ever starting.
    var parts: [Any] = []
    Task { @MainActor in
        do {
            let paths = Paths()
            let config = try await ConfigStore.open(file: paths.config)
            var session: Session!  // the overlay reads the session through closures and the session starts the overlay: neither can be built first
            let overlay = Overlay(config: config, attached: { Set(session.attached.map(\.id)) }, failures: { session.failures.values.sorted() })
            session = Session(paths: paths, config: config, onStart: { overlay.bind($0) })
            session.observe { overlay.refresh() }
            let catalog = WindowCatalog(permissions: session.permissions)
            let fontSize = await FontSizeItem(config: config)
            let bar = MenuBar(session: session, catalog: catalog, settings: [overlay.hideShowItem, fontSize.item])
            session.start()
            parts = [session!, overlay, catalog, fontSize, bar]
        } catch { fatalError("\(error)") }
    }
    app.run()
    _ = parts
default:
    FileHandle.standardError.write(Data("usage: TranscribeEverything [prefetch | verify <scenario.json>]\n".utf8))
    exit(2)
}

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
    let session = Session(config: ConfigStore(), onStart: { _ in })
    let bar = MenuBar(session: session)
    session.start()
    withExtendedLifetime((session, bar)) { app.run() }
default:
    FileHandle.standardError.write(Data("usage: TranscribeEverything [prefetch | verify <scenario.json>]\n".utf8))
    exit(2)
}

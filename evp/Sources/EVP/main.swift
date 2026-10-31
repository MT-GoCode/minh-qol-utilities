import AppKit
import EVPCore

// `--version` proves the binary starts and libmpv loads; the installer runs it on the installed copy.
if CommandLine.arguments.contains("--version") {
    print("EVP, libmpv \(MpvPlayer.libraryVersion)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

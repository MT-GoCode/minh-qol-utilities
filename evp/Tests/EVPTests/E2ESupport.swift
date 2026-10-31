import AppKit
import ImageIO
import XCTest

enum Paths {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let app = root.appendingPathComponent("build/EVP.app")
    static let cli = root.appendingPathComponent("bin/evp")
    static let driver = root.appendingPathComponent(".build/evpdrive")
    /// The `rac` command (runs the driver as the Remote Agent Connector app, which holds the GUI permissions);
    /// EVP_RAC points at another copy of the script.
    static let rac = ProcessInfo.processInfo.environment["EVP_RAC"] ?? "/usr/local/bin/rac"
    /// The run's results folder (set by ./test): E2E tests save their screenshots under it.
    static let results = ProcessInfo.processInfo.environment["EVP_RESULTS"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
}

struct WindowInfo {
    let id: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// A decoded screenshot: counts what is on screen, never how it was drawn.
struct Pixels {
    let width: Int
    let height: Int
    /// The PNG these pixels were decoded from.
    let file: URL
    private let rgba: [UInt8]

    init(png url: URL) throws {
        file = url
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "cannot read \(url.path)")
        }
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        (width, height, rgba) = (w, h, bytes)
    }

    /// Black is luma below 2 of 255, as the mpv clear colour renders.
    func nonBlackBounds(belowRow top: Int) -> (width: Int, height: Int)? { nonBlackBounds(rows: top..<height) }

    func nonBlackBounds(rows: Range<Int>) -> (width: Int, height: Int)? {
        var (minX, maxX, minY, maxY) = (width, -1, height, -1)
        for y in rows {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if 0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2]) >= 2 {
                    (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
                }
            }
        }
        return maxX < 0 ? nil : (maxX - minX + 1, maxY - minY + 1)
    }

    /// Share of pixels below `top` whose colour channels differ by more than 64: video, not black bars or grey chrome.
    func colourfulShare(belowRow top: Int) -> Double { colourfulShare(rows: top..<height) }

    func colourfulShare(rows: Range<Int>) -> Double {
        var colourful = 0
        for y in rows {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let channels = [rgba[i], rgba[i + 1], rgba[i + 2]]
                if Int(channels.max()!) - Int(channels.min()!) > 64 { colourful += 1 }
            }
        }
        return Double(colourful) / Double(rows.count * width)
    }
}

/// Base class of the E2E tests: one app at a time, always quit afterwards.
class E2ETestCase: XCTestCase {
    var app: RunningApp?

    override func setUpWithError() throws {
        // A leftover instance from an aborted run would answer for the new launch.
        try RunningApp.stopLeftovers(of: Paths.app)
    }

    private var stateFolders: [URL] = []

    /// A state folder for a test that quits or kills the app and starts it again. It is removed after the app has
    /// quit: teardown blocks run before `tearDownWithError`, and an app whose folder vanished cannot save.
    func stateFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evp-home-\(UUID().uuidString)")
        stateFolders.append(folder)
        return folder
    }

    override func tearDownWithError() throws {
        defer { stateFolders.forEach { try? FileManager.default.removeItem(at: $0) } }
        try app?.terminate()
    }

    /// Keeps the screenshot a test just analysed, so the results folder shows exactly what was judged.
    func saveToResults(_ name: String, _ pixels: Pixels) throws {
        let folder = Paths.results.appendingPathComponent("gallery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        try FileManager.default.copyItem(at: pixels.file, to: folder.appendingPathComponent(name))
    }
}

/// A launched EVP.app, driven only from outside: the `evp` command, window lists, resizes and screenshots.
final class RunningApp {
    let application: NSRunningApplication
    private let scratch: URL
    /// The app's state folder for this run (`EVP_HOME`): a test never touches the real saved state.
    let home: URL

    private init(_ application: NSRunningApplication, scratch: URL, home: URL) {
        (self.application, self.scratch, self.home) = (application, scratch, home)
    }

    static func running(at appURL: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }
    }

    /// The list of running applications only refreshes while the run loop spins, so every wait on it must spin too.
    static func spin(for seconds: TimeInterval = 0.05) { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(seconds)) }

    /// Makes sure no instance of `appURL` is running, asking it to quit first would be too polite for a leftover.
    static func stopLeftovers(of appURL: URL, timeout: TimeInterval = 10) throws {
        running(at: appURL)?.forceTerminate()
        let deadline = Date().addingTimeInterval(timeout)
        while running(at: appURL) != nil {
            guard Date() < deadline else { throw Failure(description: "a leftover \(appURL.lastPathComponent) will not die") }
            spin()
        }
    }

    /// LaunchServices hands a URL to a running app of the same bundle id even when `open -a` names another copy, so a
    /// launch needs every other EVP gone first.
    private static func waitForNoOtherEVP(timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: "com.minh.evp").isEmpty {
            guard Date() < deadline else { throw Failure(description: "another EVP is still running: quit it and run the test again") }
            spin()
        }
    }

    /// Runs `bin/evp` for `arguments` against `appURL` and waits for that app to be running. With no arguments the app
    /// is started on its own, as when it is opened from the Dock, to see what it restores. `home` is the state folder;
    /// a test that quits or kills the app and starts it again passes the same one (the caller removes it).
    static func launch(_ arguments: [String], home: URL? = nil, appURL: URL = Paths.app, cli: URL = Paths.cli) throws -> RunningApp {
        try waitForNoOtherEVP()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("evp-e2e-\(UUID().uuidString)")
        let home = home ?? scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        // -g: the test runs in the background and must not take focus from whoever is using the machine.
        if arguments.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-a", appURL.path, "--env", "EVP_HOME=\(home.path)"]
        } else {
            process.executableURL = cli
            process.arguments = ["-g"] + arguments
        }
        process.environment = ["EVP_APP": appURL.path, "EVP_HOME": home.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(description: "evp exited \(process.terminationStatus)") }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let application = running(at: appURL) { return RunningApp(application, scratch: scratch, home: home) }
            spin()
        }
        throw Failure(description: "\(appURL.lastPathComponent) never started")
    }

    func terminate() throws {
        let asked = Date()
        application.terminate()
        let deadline = asked.addingTimeInterval(5)
        while !application.isTerminated, Date() < deadline { Self.spin() }
        guard application.isTerminated else {
            // Evidence for the failure: what was on screen, which windows the app had, and whether it quit late.
            let shot = Paths.results.appendingPathComponent("did-not-quit-\(UUID().uuidString.prefix(8)).png")
            let windows = (try? driver(["windows", String(application.processIdentifier)])) ?? "no windows listed"
            _ = try? driver(["snapshot-screen", shot.path], asApp: true)
            for line in windows.split(separator: "\n") where !line.contains(#""w":0.0"#) {
                guard let id = line.split(separator: ",").first?.split(separator: ":").last else { continue }
                _ = try? driver(["snapshot", String(id), Paths.results.appendingPathComponent("did-not-quit-window-\(id).png").path], asApp: true)
            }
            let late = Date().addingTimeInterval(15)
            while !application.isTerminated, Date() < late { Self.spin() }
            try? FileManager.default.removeItem(at: scratch)
            throw Failure(description: "EVP did not quit within 5 s of being asked (\(application.isTerminated ? "it quit after \(Int(Date().timeIntervalSince(asked))) s" : "still running after 20 s")); windows:\n\(windows)screen: \(shot.path)")
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Kills the app the way a crash or a power cut would: no quit handlers run.
    func crash() throws {
        kill(application.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        while !application.isTerminated, Date() < deadline { Self.spin() }
        guard application.isTerminated else { throw Failure(description: "EVP survived kill -9") }
    }

    private func driver(_ arguments: [String], asApp: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = asApp ? URL(fileURLWithPath: "/bin/bash") : Paths.driver
        // `rac exec` drops the driver's stderr, so merge it into stdout there.
        process.arguments = asApp ? [Paths.rac, "exec", "/bin/sh", "-c", "\"$0\" \"$@\" 2>&1", Paths.driver.path] + arguments : arguments
        let (out, err) = (Pipe(), Pipe())
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(description: "evpdrive \(arguments.joined(separator: " ")): \(errors)\(output)") }
        return output
    }

    /// Every player window, largest first (the menu bar adds thin, wide windows, which are left out).
    func playerWindows() throws -> [WindowInfo] {
        try driver(["windows", String(application.processIdentifier)]).split(separator: "\n").compactMap { line -> WindowInfo? in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Double] else { return nil }
            return WindowInfo(id: Int(json["id"]!), x: json["x"]!, y: json["y"]!, width: json["w"]!, height: json["h"]!)
        }
        .filter { $0.height > 100 }
        .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    func playerWindow() throws -> WindowInfo {
        guard let window = try playerWindows().first else { throw Failure(description: "no player window yet") }
        return window
    }

    func windowCount() throws -> Int { try driver(["windows", String(application.processIdentifier)]).split(separator: "\n").count }

    /// Presses `id`, waiting for it to appear: the accessibility tree is briefly empty after a window changes Space.
    func press(_ id: String, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do { return try { _ = try driver(["press", String(application.processIdentifier), id], asApp: true) }() } catch {
                guard Date() < deadline else {
                    let seen = (try? driver(["tree", String(application.processIdentifier)], asApp: true)) ?? "no tree"
                    throw Failure(description: "\(error)\naccessibility tree then:\n\(seen.split(separator: "\n").filter { !$0.contains("AXMenu") }.joined(separator: "\n"))")
                }
                usleep(200_000)
            }
        }
    }

    /// Runs the accessibility action of `id` whose name contains `action`.
    func perform(_ id: String, action: String) throws { _ = try driver(["perform", String(application.processIdentifier), id, action], asApp: true) }

    func setValue(_ id: String, to value: Double) throws {
        _ = try driver(["setvalue", String(application.processIdentifier), id, String(value)], asApp: true)
    }

    func type(_ text: String) throws { _ = try driver(["type", String(application.processIdentifier), text], asApp: true) }

    func focus(_ id: String) throws { _ = try driver(["focus", String(application.processIdentifier), id], asApp: true) }

    func read(_ id: String, attribute: String? = nil) throws -> String {
        try driver(["read", String(application.processIdentifier), id] + (attribute.map { [$0] } ?? []), asApp: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads `id` until `done` accepts its text.
    func wait(for id: String, attribute: String? = nil, timeout: TimeInterval = 10, until done: (String) -> Bool) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "nothing read"
        while Date() < deadline {
            if let text = try? read(id, attribute: attribute) {
                if done(text) { return text }
                last = text
            }
            usleep(150_000)
        }
        throw Failure(description: "timed out waiting on \(id); last read: \(last)")
    }

    /// Types `chord` (see `evpdrive key`) into the app; `count` above 1 sends key repeats.
    func key(_ chord: String, count: Int = 1) throws {
        _ = try driver(["key", String(application.processIdentifier), chord, String(count)], asApp: true)
    }

    /// Media keys through the system (16 play/pause, 17 next, 18 previous): they reach whichever app the system picks.
    func media(_ codes: Int...) throws { _ = try driver(["media"] + codes.map(String.init), asApp: true) }

    func resize(width: Int, height: Int) throws {
        _ = try driver(["resize", String(application.processIdentifier), String(width), String(height)], asApp: true)
    }

    func snapshot(_ window: WindowInfo) throws -> Pixels {
        let png = scratch.appendingPathComponent("\(UUID().uuidString).png")
        _ = try driver(["snapshot", String(window.id), png.path], asApp: true)
        return try Pixels(png: png)
    }

    /// Takes snapshots until `done` accepts one; the last measurement is part of the failure message.
    func waitForSnapshot(timeout: TimeInterval = 10, _ what: String, until done: (WindowInfo, Pixels) -> Bool) throws -> (WindowInfo, Pixels) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "nothing yet"
        while Date() < deadline {
            do {
                let window = try playerWindow()
                let pixels = try snapshot(window)
                if done(window, pixels) { return (window, pixels) }
                last = "window \(window.width)x\(window.height), image \(pixels.width)x\(pixels.height)"
            } catch {
                last = "\(error)"
            }
            usleep(200_000)
        }
        throw Failure(description: "timed out waiting for \(what); last seen: \(last)")
    }
}

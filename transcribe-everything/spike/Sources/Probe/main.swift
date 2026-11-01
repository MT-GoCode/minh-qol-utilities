// Feasibility probe. Runs under the real app's bundle identity so TCC grants made here carry over.
// Launch via LaunchServices (`open`) so this app, not the terminal, is the TCC-responsible process.
// Every command writes JSON to ~/.transcribe-everything/probe/<command>.json.
import AVFoundation
import AppKit
import CoreAudio
import FluidAudio
import ScreenCaptureKit

let probeDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".transcribe-everything/probe")

func report(_ name: String, _ obj: [String: Any]) {
    try! FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: probeDir.appendingPathComponent("\(name).json"))
    print(String(data: data, encoding: .utf8)!)
}

// Peak-tracking writer shared by all three capture paths.
final class WavSink {
    let file: AVAudioFile
    var peak: Float = 0
    var frames: AVAudioFramePosition = 0
    init(_ path: String, _ format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    func write(_ buf: AVAudioPCMBuffer) {
        if let ch = buf.floatChannelData {
            for c in 0..<Int(buf.format.channelCount) {
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[c][i])) }
            }
        }
        frames += AVAudioFramePosition(buf.frameLength)
        try! file.write(from: buf)
    }
    var summary: [String: Any] {
        ["path": file.url.path, "frames": frames, "sample_rate": file.processingFormat.sampleRate, "peak": peak]
    }
}

// MARK: ScreenCaptureKit per-app audio

final class SCKAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    var stopError: String?
    func stream(_ s: SCStream, didStopWithError e: Error) { stopError = "\(e)" }
    var sink: WavSink?
    let path: String
    init(path: String) { self.path = path }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fd = sb.formatDescription else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        if sink == nil { sink = try! WavSink(path, fmt) }
        try! sb.withAudioBufferList { abl, _ in
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer)!
            sink!.write(buf)
        }
    }
}

func sckCapture(bundleID: String, seconds: Double, path: String, rate: Int) async throws -> [String: Any] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    // bundleID may also be a pid, to pick one instance when several share a bundle id
    guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID || "\($0.processID)" == bundleID }) else {
        return ["error": "no running app \(bundleID)"]
    }
    let cfg = SCStreamConfiguration()
    cfg.capturesAudio = true
    cfg.sampleRate = rate
    cfg.channelCount = 1
    cfg.excludesCurrentProcessAudio = true
    cfg.width = 2
    cfg.height = 2
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    let filter = SCContentFilter(display: content.displays[0], including: [app], exceptingWindows: [])
    let out = SCKAudio(path: path)
    let stream = SCStream(filter: filter, configuration: cfg, delegate: out)
    try stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck"))
    try await stream.startCapture()
    try await Task.sleep(for: .seconds(seconds))
    if out.stopError == nil { try await stream.stopCapture() }
    var r = out.sink?.summary ?? ["error": "no audio buffers delivered"]
    r["stop_error"] = out.stopError ?? "none"
    r["app"] = "\(app.bundleIdentifier) pid \(app.processID)"
    r["same_bundle_apps"] = content.applications.filter { $0.bundleIdentifier.hasPrefix(app.bundleIdentifier) }
        .map { "\($0.bundleIdentifier) \($0.processID)" }
    return r
}

// MARK: Core Audio process tap

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
             qualifier: UInt32? = nil) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    var q = qualifier ?? 0
    let st = qualifier == nil
        ? AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        : AudioObjectGetPropertyData(obj, &addr, 4, &q, &size, &value)
    precondition(st == noErr, "AudioObjectGetPropertyData \(sel) failed: \(st)")
    return value
}

// pid == nil taps every process's output.
func tapCapture(pid: pid_t?, seconds: Double, path: String) async throws -> [String: Any] {
    let desc: CATapDescription
    if let pid {
        let proc: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject),
                                       kAudioHardwarePropertyTranslatePIDToProcessObject,
                                       AudioObjectID(kAudioObjectUnknown), qualifier: UInt32(bitPattern: pid))
        guard proc != kAudioObjectUnknown else { return ["error": "pid \(pid) has no audio process object"] }
        desc = CATapDescription(monoMixdownOfProcesses: [proc])
    } else {
        desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    }
    desc.uuid = UUID()
    desc.isPrivate = true
    desc.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    var st = AudioHardwareCreateProcessTap(desc, &tap)
    guard st == noErr else { return ["error": "AudioHardwareCreateProcessTap \(st)"] }
    defer { AudioHardwareDestroyProcessTap(tap) }

    let outDev: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
    let outUID: CFString = prop(outDev, kAudioDevicePropertyDeviceUID, "" as CFString)
    let agg: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TranscribeEverythingProbeTap",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outUID as String,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID as String]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                           kAudioSubTapUIDKey: desc.uuid.uuidString]],
    ]
    var aggID = AudioObjectID(kAudioObjectUnknown)
    st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
    guard st == noErr else { return ["error": "AudioHardwareCreateAggregateDevice \(st)"] }
    defer { AudioHardwareDestroyAggregateDevice(aggID) }

    var asbd: AudioStreamBasicDescription = prop(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    let fmt = AVAudioFormat(streamDescription: &asbd)!
    let sink = try WavSink(path, fmt)
    var procID: AudioDeviceIOProcID?
    st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, DispatchQueue(label: "tap")) { _, inData, _, _, _ in
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData)!
        sink.write(buf)
    }
    guard st == noErr, let procID else { return ["error": "AudioDeviceCreateIOProcIDWithBlock \(st)"] }
    st = AudioDeviceStart(aggID, procID)
    guard st == noErr else { return ["error": "AudioDeviceStart \(st)"] }
    try await Task.sleep(for: .seconds(seconds))
    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)
    return sink.summary
}

// MARK: Microphone

// The built-in mic, so a Bluetooth headset that is the default input never flips into hands-free mode.
func builtInMic() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    precondition(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    precondition(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr)
    let found = ids.first { id in
        var t = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var n = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &t, 0, nil, &n, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var st = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                            mElement: kAudioObjectPropertyElementMain)
        var streams: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &st, 0, nil, &streams) == noErr && streams > 0
    }
    return found!
}

func micCapture(seconds: Double, path: String, voiceProcessing: Bool, advancedDucking: Bool = false) async throws -> [String: Any] {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    // Voice processing rebinds the unit (selection then lands on the output device), so only the plain path selects.
    if !voiceProcessing {
        var mic = builtInMic()
        let st = AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &mic, UInt32(MemoryLayout<AudioDeviceID>.size))
        precondition(st == noErr, "selecting built-in mic failed: \(st)")
    }
    if voiceProcessing {
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: ObjCBool(advancedDucking), duckingLevel: .min)
    }
    let fmt = input.outputFormat(forBus: 0)
    let sink = try WavSink(path, fmt)
    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in sink.write(buf) }
    try engine.start()
    try await Task.sleep(for: .seconds(seconds))
    engine.stop()
    var s = sink.summary
    s["voice_processing"] = voiceProcessing
    var cur = AudioDeviceID(0)
    var n = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &n)
    let name: CFString = prop(cur, kAudioObjectPropertyName, "" as CFString)
    s["device"] = name as String
    s["default_input"] = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
    return s
}

// MARK: Windows

func windows() async throws -> [String: Any] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let ws = content.windows.filter { $0.windowLayer == 0 && !($0.title ?? "").isEmpty }.map {
        ["title": $0.title!, "app": $0.owningApplication?.applicationName ?? "",
         "bundle": $0.owningApplication?.bundleIdentifier ?? "", "pid": $0.owningApplication?.processID ?? -1,
         "on_screen": $0.isOnScreen] as [String: Any]
    }
    return ["count": ws.count, "windows": ws]
}

// MARK: Overlay panel

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var seen: [String] = []
    override func sendEvent(_ e: NSEvent) {
        if [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown].contains(e.type) { seen.append("\(e.type.rawValue)") }
        super.sendEvent(e)
    }
}
// The panel is not key until clicked, so without this the first click only makes it key and a drag selects nothing.
final class GripView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { window!.performDrag(with: e) }
    override func draw(_ r: NSRect) { ("\u{283F}" as NSString).draw(at: .zero, withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18)]) }
}
final class FirstMouseTextView: NSTextView { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }

// Shows a clear, non-activating panel with a selectable text view for `seconds`; reports activation and
// selection/copy behavior. The caller screenshots the window number while it is up.
@MainActor func panel(seconds: Double) async throws -> [String: Any] {
    let text = "[Zoom] You'll never dig it out of the Astor library.\n[Chrome] But the more forgetfulness had then prevailed."
    let p = KeyPanel(contentRect: NSRect(x: 200, y: 200, width: 760, height: 90),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let tv = NSTextView(frame: p.contentView!.bounds)
    tv.isEditable = false
    tv.isSelectable = true
    tv.drawsBackground = false
    let shadow = NSShadow()
    shadow.shadowColor = .black
    shadow.shadowBlurRadius = 3
    tv.textStorage!.setAttributedString(NSAttributedString(string: text, attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .shadow: shadow]))
    p.contentView!.addSubview(tv)
    p.orderFrontRegardless()
    p.makeKey()
    p.makeFirstResponder(tv)
    tv.selectAll(nil)
    NSPasteboard.general.clearContents()
    tv.copy(nil)
    let copied = NSPasteboard.general.string(forType: .string) ?? ""
    let r: [String: Any] = ["window_number": p.windowNumber, "app_active": NSApp.isActive, "panel_key": p.isKeyWindow,
                            "copy_matches": copied == text]
    report("panel-up", r)
    try await Task.sleep(for: .seconds(seconds))
    return r
}

// MARK: UI interaction probe (driven externally by synthetic events / System Events)

final class MenuTarget: NSObject {
    var clicked: [String] = []
    @objc func hit(_ sender: NSMenuItem) { clicked.append(sender.title) }
}

// Shows a status item (menu: Alpha, Beta) and the overlay panel, with a hidden main menu holding
// Edit > Copy (cmd-C) and Select All, since an LSUIElement app has no visible menu bar. Writes ui-up.json
// with the panel's text frame in screen coordinates, waits, then reports clicked items, the selection,
// the pasteboard and the frontmost app.
@MainActor func ui(seconds: Double) async throws -> [String: Any] {
    let main = NSMenu()
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main

    let target = MenuTarget()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button!.title = "TEprobe"
    let menu = NSMenu()
    for t in ["Alpha", "Beta"] {
        let mi = NSMenuItem(title: t, action: #selector(MenuTarget.hit(_:)), keyEquivalent: "")
        mi.target = target
        menu.addItem(mi)
    }
    item.menu = menu

    let text = "[Zoom] You'll never dig it out of the Astor library."
    let p = KeyPanel(contentRect: NSRect(x: 200, y: 200, width: 760, height: 74),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let tv = FirstMouseTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 50))
    tv.isEditable = false
    tv.isSelectable = true
    tv.drawsBackground = false
    tv.textStorage!.setAttributedString(NSAttributedString(string: text, attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .semibold)]))
    p.contentView!.addSubview(tv)
    let grip = GripView(frame: NSRect(x: 4, y: 50, width: 28, height: 24))
    p.contentView!.addSubview(grip)
    // Click-through except over the grip and the text; frozen while a button is down so a drag never flips it.
    var toggles = 0
    let poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard NSEvent.pressedMouseButtons == 0 else { return }
            let m = NSEvent.mouseLocation
            let f = p.frame
            let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
            let overGrip = NSRect(x: f.minX + 4, y: f.minY + 50, width: 28, height: 24).contains(m)
            let overText = NSRect(x: f.minX, y: f.minY + 50 - used.height, width: used.width, height: used.height).contains(m)
            let ignore = !(overGrip || overText)
            if p.ignoresMouseEvents != ignore { p.ignoresMouseEvents = ignore; toggles += 1 }
        }
    }
    p.orderFrontRegardless()
    NSPasteboard.general.clearContents()
    var globalDowns: [String] = []
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { e in
        globalDowns.append("\(Int(e.locationInWindow.x)),\(Int(e.locationInWindow.y))")
    }
    let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let screenH = NSScreen.screens[0].frame.height
    // text line 1 spans roughly x 205...700 at y (top-left origin) screenH - 200 - 25
    // Panel top is y = 250 (bottom-left origin); the 22 pt line's middle is about 13 pt below it.
    report("ui-up", ["drag_from": [205, Int(screenH) - 237], "drag_to": [560, Int(screenH) - 237],
                     "front_before": frontBefore])
    try await Task.sleep(for: .seconds(seconds))
    NSEvent.removeMonitor(monitor as Any)
    poll.invalidate()
    let sel = tv.selectedRange()
    return ["ignore_toggles": toggles, "panel_seen": p.seen.count, "global_mouse_downs": globalDowns.count, "panel_frame": "\(p.frame)",
            "screen": "\(NSScreen.screens[0].frame)", "panel_key": p.isKeyWindow, "app_active": NSApp.isActive, "clicked": target.clicked, "selected": (text as NSString).substring(with: sel),
            "pasteboard": NSPasteboard.general.string(forType: .string) ?? "",
            "front_before": frontBefore,
            "front_after": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
}

// MARK: Ultra inside the signed bundle

func decode(path: String) async throws -> [String: Any] {
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    let t0 = Date()
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
    let load = Date().timeIntervalSince(t0)
    let layers = await asr.decoderLayerCount
    var rows: [[String: Any]] = []
    for secs in [2.0, 12.0] {
        var ms: [Double] = []
        var text = ""
        for i in 0..<9 {
            var ds = TdtDecoderState.make(decoderLayers: layers)
            let t = Date()
            text = try await asr.transcribe(Array(audio[0..<Int(secs * 16000)]), decoderState: &ds).text
            if i > 0 { ms.append(Date().timeIntervalSince(t) * 1000) }
        }
        ms.sort()
        rows.append(["seconds": secs, "median_ms": ms[ms.count / 2], "max_ms": ms.last!, "text": text])
    }
    return ["load_seconds": load, "rows": rows, "ppid": getppid()]
}

// MARK: Permissions

func status() -> [String: Any] {
    ["microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,  // 3 == authorized
     "screen_recording": CGPreflightScreenCaptureAccess()]
}

func grant() async throws -> [String: Any] {
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    // System Audio Recording has no request API; starting a tap triggers its prompt.
    let tmp = probeDir.appendingPathComponent("grant-tap.wav").path
    var s = status()
    s["audio_capture_tap"] = try await tapCapture(pid: nil, seconds: 3, path: tmp)
    return s
}

// MARK: Dispatch

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"
func arg(_ i: Int) -> String { args.count > i ? args[i] : "" }
func out(_ i: Int) -> String { args.count > i ? args[i] : probeDir.appendingPathComponent("\(cmd).wav").path }

NSApplication.shared.setActivationPolicy(.accessory)
Task {
    do {
        let r: [String: Any]
        switch cmd {
        case "status": r = status()
        case "panel": r = try await panel(seconds: Double(arg(1))!)
        case "decode": r = try await decode(path: arg(1))
        case "ui": r = try await ui(seconds: Double(arg(1))!)
        case "grant": r = try await grant()
        case "windows": r = try await windows()
        case "sck": r = try await sckCapture(bundleID: arg(1), seconds: Double(arg(2))!,
                                             path: probeDir.appendingPathComponent("sck.wav").path,
                                             rate: Int(arg(3)) ?? 48000)
        case "tap": r = try await tapCapture(pid: arg(1) == "all" ? nil : pid_t(arg(1))!,
                                             seconds: Double(arg(2))!, path: out(3))
        case "mic": r = try await micCapture(seconds: Double(arg(1))!, path: out(2), voiceProcessing: false)
        case "mic-vp": r = try await micCapture(seconds: Double(arg(1))!, path: out(2), voiceProcessing: true)
        case "mic-vpa": r = try await micCapture(seconds: Double(arg(1))!, path: out(2), voiceProcessing: true,
                                                 advancedDucking: true)
        default: r = ["error": "unknown command \(cmd)"]
        }
        report(cmd, r)
        exit(0)
    } catch {
        report(cmd, ["error": "\(error)"])
        exit(1)
    }
}
NSApp.run()

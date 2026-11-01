import AVFoundation
import AppKit
import CoreAudio
import CoreMedia
import ScreenCaptureKit
import os

public final class AppSource: AudioSource {
    public enum Failure: Error { case noApp(pid_t), noDisplay, format(String) }
    public let id: SourceID, tag: String
    private let pid: pid_t, stallLimit: Duration
    private let continuation = OSAllocatedUnfairLock<AsyncThrowingStream<Chunk, Error>.Continuation?>(initialState: nil)

    public init(pid: pid_t, id: SourceID, tag: String, stallLimit: Duration = StallGuard.limit) {
        self.pid = pid
        self.id = id
        self.tag = tag
        self.stallLimit = stallLimit
    }

    public func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { out in
            continuation.withLock { $0 = out }
            let stall = StallGuard(limit: stallLimit), tap = Tap(out, stall), pid = pid
            // SCK keeps delivering silence after the app quits, so this is the only end signal. Registered before the lookup: an exit during start-up still counts.
            let exit = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { n in
                if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid { out.finish() }
            }
            let task = Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try Task.checkCancellation()  // stopped during the lookup: build nothing
                    guard let app = content.applications.first(where: { $0.processID == pid }) else { throw Failure.noApp(pid) }
                    guard let display = content.displays.first else { throw Failure.noDisplay }
                    let cfg = SCStreamConfiguration()
                    cfg.capturesAudio = true
                    cfg.sampleRate = Chunk.sampleRate
                    cfg.channelCount = 1
                    cfg.width = 2; cfg.height = 2  // video is not consumed; smallest frame
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                    let start = {
                        let s = SCStream(filter: filter, configuration: cfg, delegate: tap)
                        try s.addStreamOutput(tap, type: .audio, sampleHandlerQueue: tap.queue)
                        try await s.startCapture()
                        return s
                    }
                    let helpers = AudioHelpers(of: pid)  // before the first start, so a helper appearing during it still restarts
                    let first = try await start()
                    tap.adopt(first)
                    try await withThrowingTaskGroup(of: Void.self) { g in
                        g.addTask { try await stall.watch() }  // starts counting only now: start-up is never a stall
                        g.addTask {
                            var s = first
                            defer { Task { [s] in try? await s.stopCapture() } }  // on every way out; an already-stopped stream throws and changes nothing
                            for await _ in helpers.appeared {
                                // The old stream delivers until the new one is up: no audio gap, and the stall guard keeps beating.
                                let next = try await start()
                                tap.adopt(next)
                                try? await s.stopCapture()
                                s = next
                            }
                        }
                        try await g.next()
                        g.cancelAll()
                    }
                } catch { out.finish(throwing: error) }
            }
            out.onTermination = { _ in
                NSWorkspace.shared.notificationCenter.removeObserver(exit)
                task.cancel()
            }
        }
    }
    public func stop() { continuation.withLock { $0?.finish() } }
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePid(_ pid: pid_t) -> pid_t

/// Yields when a process the app is responsible for becomes a Core Audio client. Chrome and Safari play through a helper started at first playback, and a running SCK stream, even with its filter updated, never hears a process that appeared after it started.
private final class AudioHelpers {
    let appeared: AsyncStream<Void>
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let queue = DispatchQueue(label: "AppSource.helpers")  // serial: `seen` lives on it
    private let block: AudioObjectPropertyListenerBlock

    init(of pid: pid_t) {
        let (stream, out) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        appeared = stream
        var seen = Self.clients(of: pid)
        block = { _, _ in
            let now = Self.clients(of: pid)
            if !now.isSubset(of: seen) { out.yield() }
            seen = now
        }
        precondition(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr)
    }
    deinit { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) }

    private static func clients(of pid: pid_t) -> Set<pid_t> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        address.mSelector = kAudioProcessPropertyPID
        return Set(objects.compactMap { object -> pid_t? in
            var client: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &client) == noErr, client != pid, responsiblePid(client) == pid else { return nil }
            return client
        })
    }
}

/// Every outcome goes through `out.finish`; the first call wins.
private final class Tap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let out: AsyncThrowingStream<Chunk, Error>.Continuation
    let queue = DispatchQueue(label: "AppSource.samples")  // serial: `next` and `format` live on it
    private let stall: StallGuard
    private var next = 0, format: AVAudioFormat?, current: SCStream?
    init(_ out: AsyncThrowingStream<Chunk, Error>.Continuation, _ stall: StallGuard) {
        self.out = out
        self.stall = stall
    }

    /// From now on only this stream's buffers count, so an overlap during a restart never doubles audio.
    func adopt(_ s: SCStream) { queue.sync { current = s } }

    func stream(_ s: SCStream, didStopWithError error: Error) { out.finish(throwing: error) }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard s === current else { return }
        do {
            if format == nil {
                guard let desc = sb.formatDescription else { throw AppSource.Failure.format("buffer without format") }
                let f = AVAudioFormat(cmAudioFormatDescription: desc)
                guard f.sampleRate == Double(Chunk.sampleRate), f.channelCount == 1, f.commonFormat == .pcmFormatFloat32 else { throw AppSource.Failure.format("\(f)") }
                format = f
            }
            stall.beat()
            let samples: [Float] = try sb.withAudioBufferList { abl, _ in
                let buf = AVAudioPCMBuffer(pcmFormat: format!, bufferListNoCopy: abl.unsafePointer)!
                return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            }
            out.yield(Chunk(samples: samples, index: next))
            next += samples.count
        } catch { out.finish(throwing: error) }
    }
}

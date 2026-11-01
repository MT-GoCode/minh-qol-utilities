@preconcurrency import AVFoundation
import CoreAudio
import os

public enum MicError: Error, CustomStringConvertible {
    case noBuiltInMic, select(OSStatus), notBuiltIn(String), unsupportedFormat(String)
    public var description: String {
        switch self {
        case .noBuiltInMic: "no built-in microphone (lid closed?)"
        case .select(let s): "selecting the built-in microphone failed: \(s)"
        case .notBuiltIn(let n): "the input is bound to \(n), not the built-in microphone"
        case .unsupportedFormat(let f): "cannot convert microphone format \(f)"
        }
    }
}

public struct BoundDevice: Codable, Sendable, Equatable {
    public let id: UInt32, name: String
    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

public final class MicSource: AudioSource {
    public struct Capture: Sendable {
        public let device: BoundDevice
        public let stop: @Sendable () -> Void
        public init(device: BoundDevice, stop: @escaping @Sendable () -> Void) {
            self.device = device
            self.stop = stop
        }
    }
    /// Starts capture on the built-in mic; calls `onBuffer` from the audio thread for every buffer. The seam in-process tests replace.
    public typealias Start = @Sendable (@escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> Capture

    public let id: SourceID, tag = "Mic"
    public var device: BoundDevice? { state.withLock { $0.capture?.device } }
    public var restarts: Int { state.withLock { $0.restarts } }

    private struct State {
        var continuation: AsyncThrowingStream<Chunk, Error>.Continuation?
        var capture: Capture?
        var converter: AVAudioConverter?  // one per capture: the tap format cannot change within a running engine
        var emitted = 0, restarts = 0, delivering = false
        var observer: NSObjectProtocol?
        var watcher: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let control = DispatchQueue(label: "mic.control")  // serial: every start and stop of capture runs here, never under `state`, because engine.stop waits for a tap callback that takes it
    private let stall = StallGuard()
    private let start: Start

    public init(id: SourceID, start: @escaping Start = MicSource.engineStart) {
        self.id = id
        self.start = start
    }

    /// Called once per source: a second call is a programmer error.
    public func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            state.withLock {
                precondition($0.continuation == nil, "chunks() called twice")
                $0.continuation = c
            }
            c.onTermination = { [self] _ in control.async { self.end(nil) } }
            control.async { [self] in
                do { try begin() } catch { end(error) }
            }
        }
    }
    public func stop() { control.async { [self] in end(nil) } }

    private func begin() throws {
        let capture = try start { [self] in deliver($0) }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [self] _ in
            control.async { self.restart() }
        }
        let watcher = watchForStall()
        state.withLock {
            $0.capture = capture
            $0.observer = observer
            $0.watcher = watcher
        }
    }

    private func watchForStall() -> Task<Void, Never> {
        Task { [self] in
            do { try await stall.watch() } catch { control.async { self.end(error) } }
        }
    }

    /// The device is looked up fresh by `start` every time: an AirPods connect or a closed lid changes the answer.
    private func restart() {
        // Selecting the device also notifies, before audio flows, and restarting on that would loop forever.
        guard let old = state.withLock({ $0.continuation == nil || !$0.delivering ? nil : $0.capture }) else { return }
        state.withLock { $0.watcher }?.cancel()  // a slow restart is not a stall: the guard counts again from the new capture
        old.stop()
        do {
            let capture = try start { [self] in deliver($0) }
            let watcher = watchForStall()
            state.withLock {
                $0.capture = capture
                $0.watcher = watcher
                $0.delivering = false
                $0.converter = nil  // the input format can change, and resampler history across the gap is stale
                $0.restarts += 1
            }
        } catch { end(error) }
    }

    /// Idempotent: the first call nils the continuation.
    private func end(_ error: Error?) {
        let s = state.withLock { s -> State in
            defer {
                s.continuation = nil
                s.capture = nil
                s.observer = nil
                s.watcher = nil
            }
            return s
        }
        guard let c = s.continuation else { return }
        s.watcher?.cancel()
        s.observer.map(NotificationCenter.default.removeObserver)
        s.capture?.stop()
        c.finish(throwing: error)
    }

    /// Audio thread. Converts and yields under the lock; never calls `end` directly.
    private func deliver(_ buf: AVAudioPCMBuffer) {
        stall.beat()
        let failure: Error? = state.withLock { s in
            guard let c = s.continuation else { return nil }
            s.delivering = true
            if s.converter == nil {
                guard let conv = AVAudioConverter(from: buf.format, to: Self.target) else { return MicError.unsupportedFormat("\(buf.format)") }
                s.converter = conv
            }
            let cap = AVAudioFrameCount((Double(buf.frameLength) * Double(Chunk.sampleRate) / buf.format.sampleRate).rounded(.up)) + 1  // measured: ceil + 1 fits every call at 24, 44.1 and 48 kHz
            let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: cap)!
            var fed = false, error: NSError?
            let status = s.converter!.convert(to: out, error: &error) { _, flag in
                if fed {
                    flag.pointee = .noDataNow
                    return nil
                }
                fed = true
                flag.pointee = .haveData
                return buf
            }
            if status == .error { return error! }
            c.yield(Chunk(samples: Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))), index: s.emitted))
            s.emitted += Int(out.frameLength)
            return nil
        }
        if let failure { control.async { [self] in end(failure) } }
    }
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Chunk.sampleRate), channels: 1, interleaved: false)!

    /// No voice processing: it ducked other apps by about 8 dB (DECISIONS).
    public static let engineStart: Start = { onBuffer in
        guard let device = builtInInput() else { throw MicError.noBuiltInMic }
        let engine = AVAudioEngine(), input = engine.inputNode
        var d = device
        let status = AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MicError.select(status) }
        var bound = AudioDeviceID(0), n = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &n)
        let name = deviceName(bound)
        guard transport(bound) == kAudioDeviceTransportTypeBuiltIn else { throw MicError.notBuiltIn(name) }
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buf, _ in onBuffer(buf) }
        try engine.start()
        return Capture(device: BoundDevice(id: bound, name: name), stop: {
            engine.stop()
            input.removeTap(onBus: 0)
        })
    }

    /// nil on a closed lid.
    static func builtInInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            guard transport(id) == kAudioDeviceTransportTypeBuiltIn else { return false }
            var st = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streams: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &st, 0, nil, &streams) == noErr && streams > 0
        }
    }

    private static func transport(_ id: AudioObjectID) -> UInt32? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, n = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &value) == noErr ? value : nil
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}

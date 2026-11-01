import Foundation

/// Thumbnails for the progress strip: a second, silent player of the same file decodes the keyframe near the time under
/// the pointer. A request that arrives while another is decoding replaces any earlier waiting one, so a fast-moving
/// pointer costs one decode at a time and the latest position always wins.
public final class FramePreview {
    private let player: MpvPlayer
    private let file: URL
    private var loaded = false
    private var decoding: Double?
    private var wanted: Double?

    /// A thumbnail is ready: the time it was asked for, and a JPEG of the keyframe near it.
    public var onFrame: ((Double, Data) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(file: URL) throws {
        self.file = FileManager.default.temporaryDirectory.appendingPathComponent("evp-preview-\(UUID().uuidString).jpg")
        player = try MpvPlayer(output: .preview)
        player.onEvent = { [weak self] in self?.handle($0) }
        try player.setPaused(true)
        try player.load(file, start: nil)
    }

    deinit { try? FileManager.default.removeItem(at: file) }

    public func show(_ seconds: Double) {
        wanted = seconds
        next()
    }

    private func next() {
        guard loaded, decoding == nil, let seconds = wanted else { return }
        wanted = nil
        decoding = seconds
        do { try player.seek(keyframeNear: seconds) } catch { finish(.failure(error)) }
    }

    private func handle(_ event: MpvPlayer.Event) {
        switch event {
        // Ready on the load's own restart, not on file-loaded: a seek sent before that restart would take it as its
        // answer, and every later thumbnail would show the frame of the request before.
        case .playbackRestart where !loaded:
            loaded = true
            next()
        case .playbackRestart where decoding != nil:
            finish(Result { try player.screenshot(to: file); return try Data(contentsOf: file) })
        case .loadFailed(let error):
            onError?(error)
        default:
            break
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let seconds = decoding ?? 0
        decoding = nil
        switch result {
        case .success(let data): onFrame?(seconds, data)
        case .failure(let error): onError?(error)
        }
        next()
    }
}

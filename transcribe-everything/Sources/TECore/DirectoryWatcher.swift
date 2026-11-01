import CoreServices
import Foundation

/// Calls `onChange` after any change in `directory` or below, including in-place writes that leave the directory's entries unchanged
/// (a dispatch source on the directory misses those; one on the file misses atomic renames).
final class DirectoryWatcher: @unchecked Sendable {
    private final class Box {
        let fire: @Sendable () -> Void
        init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
    }
    private let stream: FSEventStreamRef
    private let box: Unmanaged<Box>

    init(_ directory: URL, onChange: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(onChange))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil, { _, info, _, _, _, _ in Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().fire() }, &context,
            [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))!
        self.box = box
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "DirectoryWatcher"))
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        box.release()
    }
}

import Foundation

/// One per engine start. Sole owner of displayed text.
public actor TranscriptStore {
    public nonisolated let file: URL
    private let handle: FileHandle
    private var lines: [Line] = []
    private static let isoMs = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(d.formatted(isoMs))
        }
        return e
    }()

    public init(paths: Paths, start: Date = Date()) throws {
        try FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        file = paths.transcripts.appending(path: start.formatted(Self.isoMs) + ".jsonl")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileWriteFileExists) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
    }

    public func append(_ line: Line) throws {
        try handle.write(contentsOf: Self.encoder.encode(line) + [0x0A])
        lines.append(line)
    }

    public func snapshot() -> [Line] { lines }
}

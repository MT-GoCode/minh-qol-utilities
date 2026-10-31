import EVPCore
import Foundation

// Rewrites the state file in a tight loop until killed: the writer for the kill -9 durability test.
// 2000 entries make each write take long enough that a kill lands mid-write.
let store = try StateStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]), flushInterval: 0, onFlushError: { fatalError("\($0)") })
var round = 0.0
while true {
    round += 1
    store.update { state in
        state.files = Dictionary(uniqueKeysWithValues: (0..<2000).map { ("/media/file\($0).mkv", FileState(position: round, speed: 1, volume: 100)) })
    }
    try store.flushNow()
}

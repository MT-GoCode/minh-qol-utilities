import EVPCore
import XCTest

/// A real writer process (EVPStateStress) is killed with SIGKILL while rewriting a large state file.
final class IntegrationStateKillTests: XCTestCase {
    func testKillDuringWritesNeverLeavesUnparseableState() throws {
        let writer = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("EVPStateStress")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: writer.path), "EVPStateStress not built: run ./test")
        let failures = NSLock()
        var problems: [String] = []
        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("evp-kill-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("state.json")
            let process = Process()
            process.executableURL = writer
            process.arguments = [directory.path]
            do { try process.run() } catch { failures.lock(); problems.append("\(iteration): \(error)"); failures.unlock(); return }
            // Kill only once the first complete file exists, so the kill always lands among later rewrites.
            // 10 s is far above the first write (about 50 ms) and only guards against a writer that never starts.
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { usleep(1000) }
            usleep(UInt32.random(in: 0...20_000))  // spread kills across the length of a rewrite (about 10 ms)
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            do {
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                if state.files.count != 2000 { failures.lock(); problems.append("\(iteration): \(state.files.count) entries"); failures.unlock() }
            } catch {
                failures.lock(); problems.append("\(iteration): \(error)"); failures.unlock()
            }
        }
        XCTAssertEqual(problems, [])
    }
}

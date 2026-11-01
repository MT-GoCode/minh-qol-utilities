import Foundation
import TECore

/// scenario.json: {"root": "<data root>", "steps": [{"op": "transcribe", "path": "<wav>"}, ...]}
struct Scenario: Decodable {
    let root: String
    let steps: [Step]
}

/// Tagged by "op" at decode and routed once, in `run`: a new op is a new case, and the compiler flags `run`.
enum Step: Decodable {
    case transcribe(path: String)

    private enum Key: String, CodingKey { case op, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .op) {
        case "transcribe": self = .transcribe(path: try c.decode(String.self, forKey: .path))
        case let op: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }

    func run(_ app: AppController) async throws -> [String: Any] {
        switch self {
        case .transcribe(let path):
            var samples: [Float] = []
            for try await chunk in try FileSource(url: URL(fileURLWithPath: path), id: SourceID(rawValue: "verify"), tag: "v").chunks() { samples += chunk.samples }
            let t0 = ContinuousClock.now
            let text = try await app.transcriber.transcribe(samples).text
            let d = t0.duration(to: .now).components
            return ["op": "transcribe", "path": path, "text": text, "seconds": Double(d.seconds) + Double(d.attoseconds) * 1e-18]
        }
    }
}

/// Runs a scenario under the installed app's identity, which holds the permissions, and writes <scenario>.report.json.
public enum Verify {
    public static func run(scenario url: URL) async throws {
        let report = url.deletingPathExtension().appendingPathExtension("report.json")
        do {
            let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
            let app = try await AppController.start(paths: Paths(root: URL(fileURLWithPath: scenario.root)))
            var results: [[String: Any]] = []
            for step in scenario.steps { results.append(try await step.run(app)) }
            try write(["bundleId": Bundle.main.bundleIdentifier ?? "none", "results": results], to: report)
        } catch {
            try write(["error": "\(error)"], to: report)
            throw error
        }
    }

    private static func write(_ obj: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

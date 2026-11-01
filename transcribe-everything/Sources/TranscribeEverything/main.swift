import FluidAudio
import Foundation
import TECore

guard CommandLine.arguments.dropFirst().elementsEqual(["prefetch"]) else {
    FileHandle.standardError.write(Data("usage: TranscribeEverything prefetch\n".utf8))
    exit(2)
}
_ = try await Transcriber.load()
_ = try await VadManager()
_ = try await DiarizerModels.download()
print("models ready")

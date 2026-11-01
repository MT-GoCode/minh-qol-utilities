// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscribeEverything",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0")],
    targets: [
        .target(name: "TECore", dependencies: ["FluidAudio"]),
        .executableTarget(name: "TranscribeEverything", dependencies: ["TECore", "FluidAudio"]),
        .testTarget(name: "TECoreTests", dependencies: ["TECore", "FluidAudio"]),
    ],
    swiftLanguageModes: [.v5]
)

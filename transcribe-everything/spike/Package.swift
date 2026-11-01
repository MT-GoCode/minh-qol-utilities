// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0"),
    ],
    targets: [
        .executableTarget(name: "Probe", dependencies: ["FluidAudio"], path: "Sources/Probe",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Bench", dependencies: ["FluidAudio"], path: "Sources/Bench",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

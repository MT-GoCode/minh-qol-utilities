// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EVP",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CMpv", path: "Sources/CMpv", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .target(name: "EVPCore", dependencies: ["CMpv"]),
        .testTarget(name: "EVPTests", dependencies: ["EVPCore"]),
    ],
    swiftLanguageModes: [.v5]
)

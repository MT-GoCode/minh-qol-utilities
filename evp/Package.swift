// swift-tools-version:6.0
import PackageDescription

// libmpv comes from Homebrew (`brew install mpv`); the rpath makes the built binary find it.
let mpvLink: [LinkerSetting] = [
    .unsafeFlags(["-L/opt/homebrew/lib", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"]),
]

let package = Package(
    name: "EVP",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CMpv", path: "Sources/CMpv"),
        .target(name: "EVPCore", dependencies: ["CMpv"], linkerSettings: mpvLink),
        .testTarget(name: "EVPTests", dependencies: ["EVPCore"]),
    ],
    swiftLanguageModes: [.v5]
)

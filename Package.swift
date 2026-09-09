// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicboxCore",
    // No platform pin: this package is Foundation-only and must keep building
    // and testing on Linux CI as well as macOS/iOS toolchains.
    products: [
        .library(
            name: "MusicboxCore",
            targets: ["MusicboxCore"]
        )
    ],
    targets: [
        .target(
            name: "MusicboxCore",
            path: "Sources/MusicboxCore"
        ),
        .testTarget(
            name: "MusicboxCoreTests",
            dependencies: ["MusicboxCore"],
            path: "Tests/MusicboxCoreTests"
        )
    ]
)

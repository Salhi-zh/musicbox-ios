// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicboxCore",
    // Deployment targets for Apple platforms so async/await (iOS 13+) is
    // available when the iOS app links this package. Ignored on Linux, so
    // `swift test` on Linux CI is unaffected.
    platforms: [.iOS(.v16), .macOS(.v13)],
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

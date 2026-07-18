// swift-tools-version:6.0
// (tools 6.0 so `swift test` finds the Swift Testing framework the Command
// Line Tools ship; swiftLanguageModes keeps every target in Swift 5 mode.)
import PackageDescription

let package = Package(
    name: "WindowSnap",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "CAXBridge", path: "Sources/CAXBridge"),
        .executableTarget(
            name: "WindowSnap",
            dependencies: [
                "CAXBridge",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/WindowSnap"
        ),
        // Run via ./test.sh — a bare Command Line Tools install needs framework
        // search flags on the CLI (see the script) for Swift Testing to load.
        .testTarget(
            name: "WindowSnapTests",
            dependencies: ["WindowSnap"],
            path: "Tests/WindowSnapTests"
        )
    ],
    swiftLanguageModes: [.v5]
)

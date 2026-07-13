// swift-tools-version:5.9
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
        )
    ]
)

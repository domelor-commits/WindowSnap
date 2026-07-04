// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "WindowSnap",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "CAXBridge",
            path: "Sources/CAXBridge"
        ),
        .executableTarget(
            name: "WindowSnap",
            dependencies: ["CAXBridge"],
            path: "Sources/WindowSnap"
        )
    ]
)

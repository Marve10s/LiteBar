// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiteBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageData"),
        .executableTarget(name: "LiteBarCapture", dependencies: ["ClaudeUsageData"]),
        .executableTarget(
            name: "LiteBar",
            dependencies: ["ClaudeUsageData"],
            path: "Sources/LiteBar",
            resources: [
                .copy("Resources/icons")
            ]
        ),
        .testTarget(name: "LiteBarTests", dependencies: ["LiteBar", "ClaudeUsageData"])
    ]
)

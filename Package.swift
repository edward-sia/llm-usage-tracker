// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"]),
        .library(name: "ClaudeUsageBarCore", targets: ["ClaudeUsageBarCore"]),
    ],
    targets: [
        .target(name: "ClaudeUsageBarCore"),
        .executableTarget(name: "ClaudeUsageBar", dependencies: ["ClaudeUsageBarCore"]),
        .testTarget(
            name: "ClaudeUsageBarTests",
            dependencies: ["ClaudeUsageBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LLMUsageBar", targets: ["LLMUsageBar"]),
        .library(name: "LLMUsageBarCore", targets: ["LLMUsageBarCore"]),
    ],
    targets: [
        .target(name: "LLMUsageBarCore"),
        .executableTarget(name: "LLMUsageBar", dependencies: ["LLMUsageBarCore"]),
        .testTarget(
            name: "LLMUsageBarTests",
            dependencies: ["LLMUsageBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

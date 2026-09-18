// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentLimits",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentLimits",
            path: "Sources/AgentLimits"
        )
    ]
)

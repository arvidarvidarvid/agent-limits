// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentLimits",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentLimits", targets: ["AgentLimits"]),
        .executable(name: "agent-limits", targets: ["AgentLimitsCLI"]),
    ],
    targets: [
        // Auth, credentials, config, fetching and decoding, shared by both front ends.
        .target(
            name: "AgentLimitsCore",
            path: "Sources/AgentLimitsCore"
        ),
        // The menu bar app.
        .executableTarget(
            name: "AgentLimits",
            dependencies: ["AgentLimitsCore"],
            path: "Sources/AgentLimits"
        ),
        // The `agent-limits` command-line tool.
        .executableTarget(
            name: "AgentLimitsCLI",
            dependencies: ["AgentLimitsCore"],
            path: "Sources/AgentLimitsCLI"
        ),
    ]
)

// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CodexAgentDesktopMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexAgentMonitor", targets: ["CodexAgentMonitor"]),
        .executable(name: "CodexAgentDesktopMonitor", targets: ["CodexAgentDesktopMonitor"]),
        .executable(name: "FixtureChecks", targets: ["FixtureChecks"]),
    ],
    targets: [
        .target(name: "CodexAgentMonitor", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CodexAgentDesktopMonitor", dependencies: ["CodexAgentMonitor"]),
        .executableTarget(name: "FixtureChecks", dependencies: ["CodexAgentMonitor"]),
    ]
)

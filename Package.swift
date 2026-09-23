// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CodexSessionAtlas",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SessionAtlasCore", targets: ["SessionAtlasCore"]),
        .executable(name: "CodexSessionAtlas", targets: ["CodexSessionAtlas"]),
        .executable(name: "FixtureChecks", targets: ["FixtureChecks"]),
        .executable(name: "ObservationChecks", targets: ["ObservationChecks"]),
        .executable(name: "MonitorProbe", targets: ["MonitorProbe"]),
    ],
    targets: [
        .target(name: "SessionAtlasCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CodexSessionAtlas", dependencies: ["SessionAtlasCore"]),
        .executableTarget(name: "FixtureChecks", dependencies: ["SessionAtlasCore"]),
        .executableTarget(name: "MonitorProbe", dependencies: ["SessionAtlasCore"]),
        .executableTarget(name: "ObservationChecks", dependencies: ["SessionAtlasCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    ]
)

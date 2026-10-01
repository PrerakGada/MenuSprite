// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuSprite",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MenuSprite", targets: ["MenuSprite"]),
        // The `menusprite` command (CLI and MCP server). Built under this name because the bin folder is
        // case-insensitive; scripts/build-native.sh copies it into the bundle as Contents/Helpers/menusprite.
        .executable(name: "MenuSpriteCLI", targets: ["MenuSpriteCLI"]),
        // Loaded into /usr/bin/perl at run time, never linked into the app (see scripts/build-native.sh).
        .library(name: "NowPlayingBridge", type: .dynamic, targets: ["NowPlayingBridge"]),
    ],
    targets: [
        .target(name: "PermissionModel"),
        .target(name: "SystemMonitoring"),
        .target(name: "PowerControl", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "PowerUIBridge", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "AIAccounts"),
        .target(name: "WorkTracking", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "IslandKit"),
        .target(name: "AgentProtocol"),
        .target(name: "SpriteSpec", dependencies: ["SystemMonitoring", "AgentProtocol"]),
        .executableTarget(name: "MenuSpriteCLI", dependencies: ["AgentProtocol"]),
        .target(name: "NowPlayingBridge", linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(name: "MenuSpritePowerHelper", dependencies: ["PowerControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MenuSprite", dependencies: ["PermissionModel", "SystemMonitoring", "PowerControl", "PowerUIBridge", "AIAccounts", "WorkTracking", "IslandKit", "AgentProtocol", "SpriteSpec"]),
        .testTarget(name: "WorkTrackingTests", dependencies: ["WorkTracking"]),
        .testTarget(name: "PowerControlTests", dependencies: ["PowerControl"]),
        .testTarget(name: "PermissionModelTests", dependencies: ["PermissionModel"]),
        .testTarget(name: "SystemMonitoringTests", dependencies: ["SystemMonitoring"]),
        .testTarget(name: "AIAccountsTests", dependencies: ["AIAccounts"]),
        .testTarget(name: "IslandKitTests", dependencies: ["IslandKit"]),
        .testTarget(name: "AgentProtocolTests", dependencies: ["AgentProtocol"]),
        .testTarget(name: "SpriteSpecTests", dependencies: ["SpriteSpec", "SystemMonitoring", "AgentProtocol"]),
        .testTarget(name: "MenuSpriteCLITests", dependencies: ["MenuSpriteCLI", "AgentProtocol"])
    ]
)

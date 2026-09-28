// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuSprite",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MenuSprite", targets: ["MenuSprite"]),
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
        .target(name: "NowPlayingBridge", linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(name: "MenuSpritePowerHelper", dependencies: ["PowerControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MenuSprite", dependencies: ["PermissionModel", "SystemMonitoring", "PowerControl", "PowerUIBridge", "AIAccounts", "WorkTracking", "IslandKit"]),
        .testTarget(name: "WorkTrackingTests", dependencies: ["WorkTracking"]),
        .testTarget(name: "PowerControlTests", dependencies: ["PowerControl"]),
        .testTarget(name: "PermissionModelTests", dependencies: ["PermissionModel"]),
        .testTarget(name: "SystemMonitoringTests", dependencies: ["SystemMonitoring"]),
        .testTarget(name: "AIAccountsTests", dependencies: ["AIAccounts"]),
        .testTarget(name: "IslandKitTests", dependencies: ["IslandKit"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuSprite",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MenuSprite", targets: ["MenuSprite"])],
    targets: [
        .target(name: "PermissionModel"),
        .target(name: "SystemMonitoring"),
        .target(name: "PowerControl", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "AIAccounts"),
        .target(name: "WorkTracking", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MenuSpritePowerHelper", dependencies: ["PowerControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MenuSprite", dependencies: ["PermissionModel", "SystemMonitoring", "PowerControl", "AIAccounts", "WorkTracking"]),
        .testTarget(name: "WorkTrackingTests", dependencies: ["WorkTracking"]),
        .testTarget(name: "PowerControlTests", dependencies: ["PowerControl"]),
        .testTarget(name: "PermissionModelTests", dependencies: ["PermissionModel"]),
        .testTarget(name: "SystemMonitoringTests", dependencies: ["SystemMonitoring"]),
        .testTarget(name: "AIAccountsTests", dependencies: ["AIAccounts"])
    ]
)

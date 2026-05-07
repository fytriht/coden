// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexStatusMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexStatusMonitor", targets: ["CodexStatusMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "CodexStatusMonitor",
            path: "Sources/CodexStatusMonitor",
            exclude: ["Resources/Info.plist"],
            resources: [.copy("Resources/patch-config.json")]
        ),
        .testTarget(
            name: "CodexStatusMonitorTests",
            dependencies: ["CodexStatusMonitor"],
            path: "Tests/CodexStatusMonitorTests"
        )
    ]
)

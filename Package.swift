// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    // Swift Testing (used by the test target) requires macOS 14 under Command Line Tools.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeMonitor", targets: ["ClaudeMonitor"]),
    ],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "ClaudeMonitor", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ]
)

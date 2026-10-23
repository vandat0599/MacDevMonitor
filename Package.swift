// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDevMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDevMonitor", targets: ["MacDevMonitor"])
    ],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "MacDevMonitor", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ]
)

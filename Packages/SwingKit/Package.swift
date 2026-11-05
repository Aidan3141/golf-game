// swift-tools-version: 6.4
import PackageDescription

// shared stuff for all 3 apps. pure swift, no device deps so tests run on mac
let package = Package(
    name: "SwingKit",
    platforms: [
        .visionOS(.v27),
        .iOS(.v27),
        .watchOS(.v27),
        .macOS(.v27),
    ],
    products: [
        .library(name: "SwingKit", targets: ["SwingKit"]),
    ],
    targets: [
        .target(name: "SwingKit"),
        .testTarget(name: "SwingKitTests", dependencies: ["SwingKit"]),
    ]
)

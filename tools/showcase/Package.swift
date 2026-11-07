// swift-tools-version: 6.0
import PackageDescription

// mac tool: redraws a recorded shot from the outside + data overlays, pipes frames to ffmpeg
let package = Package(
    name: "ShowcaseRender",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ShowcaseRender", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

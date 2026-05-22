// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AwakeBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "AwakeBar", path: "Sources/AwakeBar")
    ]
)

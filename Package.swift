// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "eventkit-cli",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "eventkit", path: "Sources")
    ]
)

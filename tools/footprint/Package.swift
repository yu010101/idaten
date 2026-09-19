// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "footprint-cli",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "footprint-cli", path: "Sources/footprint-cli"),
    ]
)

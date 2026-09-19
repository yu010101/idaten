// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Karu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Karu",
            path: "Sources/Karu",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)

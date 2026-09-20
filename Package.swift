// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Idaten",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Idaten",
            path: "Sources/Idaten",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)

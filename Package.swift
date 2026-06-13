// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PRBar",
            path: "Sources/PRBar"
        )
    ]
)

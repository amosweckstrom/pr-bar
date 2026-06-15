// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LGTM",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "LGTM",
            path: "Sources/LGTM"
        ),
        .testTarget(
            name: "LGTMTests",
            dependencies: ["LGTM"],
            path: "Tests/LGTMTests"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/Luminare", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "PRBar",
            dependencies: [
                .product(name: "Luminare", package: "Luminare")
            ],
            path: "Sources/PRBar"
        )
    ]
)

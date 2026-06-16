// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LGTM",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Native terminal emulator (real PTY) for the editor window's terminal pane.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "LGTM",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/LGTM",
            // Vendored, fully-offline web bundles + HTML/CSS for the tree & diff
            // panes. .copy preserves the directory tree byte-for-byte so the
            // app:// scheme's relative paths stay intact.
            resources: [
                .copy("WebAssets")
            ]
        ),
        .testTarget(
            name: "LGTMTests",
            dependencies: ["LGTM"],
            path: "Tests/LGTMTests"
        )
    ]
)

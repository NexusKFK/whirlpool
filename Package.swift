// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "whirlpool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "whirlpool",
            path: "Sources"
        )
    ]
)

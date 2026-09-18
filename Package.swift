// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "pinwheel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "pinwheel",
            path: "Sources"
        )
    ]
)

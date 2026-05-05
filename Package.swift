// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StashMac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "StashMac",
            path: "Sources/StashMac",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "StashMacTests",
            dependencies: ["StashMac"],
            path: "Tests/StashMacTests"
        ),
    ]
)

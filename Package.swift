// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StashMac",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Portable mini-vim state machine. Wired into stash-mac's
        // shared multi-line editor (VimHostEditor) so /vim activates
        // vim keybindings on any text editor in the app.
        .package(url: "https://github.com/msjurset/swift-vim-engine.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "StashMac",
            dependencies: [
                .product(name: "VimEngine", package: "swift-vim-engine"),
            ],
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

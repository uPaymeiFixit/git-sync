// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitSyncMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GitSyncMenuBar",
            path: "Sources/GitSyncMenuBar"
        ),
        .testTarget(
            name: "GitSyncMenuBarTests",
            dependencies: ["GitSyncMenuBar"],
            path: "Tests/GitSyncMenuBarTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitSync",
    platforms: [.macOS(.v15)],   // Synchronization.Atomic (AbortBox) needs 15+
    dependencies: [
        // Auto-update framework. Pinned to a known-good minor; Sparkle ships a
        // binary xcframework via SPM. build.sh copies Sparkle.framework into the
        // bundle's Contents/Frameworks and re-signs it (SPM only links it).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "GitSync",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/GitSync",
            exclude: ["Resources"]   // test fixtures (all-events.txt), not bundled
        ),
        // No test target: this builds with the Command Line Tools toolchain
        // (no Xcode.app), which ships neither XCTest nor swift-testing. The
        // suite runs instead as CLI flags on the executable (--verify-parser,
        // --smoke-test, …); see the README's "CLI test harnesses".
    ]
)

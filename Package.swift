// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitSync",
    platforms: [.macOS(.v15)],   // Synchronization.Atomic (AbortBox) needs 15+
    targets: [
        .executableTarget(
            name: "GitSync",
            path: "Sources/GitSync",
            exclude: ["Resources"]   // test fixtures (all-events.txt), not bundled
        ),
        // No test target: this builds with the Command Line Tools toolchain
        // (no Xcode.app), which ships neither XCTest nor swift-testing. The
        // suite runs instead as CLI flags on the executable (--verify-parser,
        // --smoke-test, …); see the README's "CLI test harnesses".
    ]
)

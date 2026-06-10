// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GitSync",
            path: "Sources/GitSync",
            exclude: ["Resources"]
        ),
        // Tests are intentionally omitted: this project builds with the
        // Command Line Tools toolchain (no Xcode.app), which ships neither
        // XCTest nor swift-testing. The parser is exercised at runtime via
        // the --verify-parser flag on the main executable. The fixture and
        // synthesizer (menubar/synthesize_fixture.py) stay so that a real
        // test target can be added later under Xcode without redoing work.
    ]
)

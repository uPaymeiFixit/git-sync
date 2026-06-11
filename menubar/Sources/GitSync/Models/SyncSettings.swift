import Foundation

// All settings the SyncRunner needs to spawn child sync scripts. The
// scripts directory and Python interpreter are app-bundle-relative and
// not user-controllable; the environment dict carries the GIT_SYNC_*
// variables that come from the user-facing Settings window.
struct SyncSettings: Sendable {
    var pythonPath: String
    var scriptsDirectory: URL
    var environment: [String: String]

    // /usr/bin/python3 is required by the deployment target (macOS 14+
    // ships Python 3.9 there). Bundling Python in the app is over-engineering
    // for v1 — if a user has a broken /usr/bin/python3, they have bigger
    // problems and the app's spawn error will tell them what failed.
    static let bundledPythonPath = "/usr/bin/python3"

    // Resolved from Bundle.main at app launch. In normal use this is
    // GitSync.app/Contents/Resources/scripts, populated by build.sh. The
    // fallback (the live dev checkout) is only relevant when launching
    // the SPM binary directly from .build/.../ for development — the
    // bundled copy doesn't exist there.
    static let bundledScriptsDirectory: URL = {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Dev fallback: binary is being run out of menubar/.build/<config>/
        // GitSync (not inside a .app bundle).
        let exec = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        // .../menubar/.build/<config>/GitSync -> repo root /scripts
        return exec
            .deletingLastPathComponent()    // .build/<config>/
            .deletingLastPathComponent()    // .build/
            .deletingLastPathComponent()    // menubar/
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("scripts", isDirectory: true)
    }()

    // Bundled-binaries directory. Contains glab (and could host gh, hub,
    // etc. later). SyncRunner prepends this to the child PATH so the
    // Python scripts' `glab` lookups find the bundled copy. Dev fallback:
    // when running from .build/ outside a .app, use menubar/Vendor.
    static let bundledBinDirectory: URL? = {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let exec = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let dev = exec
            .deletingLastPathComponent()    // .build/<config>/
            .deletingLastPathComponent()    // .build/
            .appendingPathComponent("..")
            .appendingPathComponent("Vendor", isDirectory: true)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }()
}

enum Platform: String, CaseIterable, Sendable {
    case gitlab, bitbucket, github

    var scriptName: String {
        switch self {
        case .gitlab:    return "sync-gitlab.py"
        case .bitbucket: return "sync-bitbucket.py"
        case .github:    return "sync-github.py"
        }
    }

    var displayName: String { rawValue }
}

import Foundation

// All settings the app passes through to the child sync scripts.
// In v1 these are hardcoded defaults; the Settings UI commit replaces
// the static `current` with a UserDefaults-backed binding.
struct SyncSettings: Sendable {
    var pythonPath: String
    var scriptsDirectory: URL
    var environment: [String: String]

    static let `default`: SyncSettings = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scripts = home
            .appendingPathComponent("git/uPaymeiFixit/git-sync/scripts", isDirectory: true)
        return SyncSettings(
            pythonPath: "/usr/bin/python3",
            scriptsDirectory: scripts,
            environment: [:]
        )
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

import Foundation
import AppKit

// Compares the running app's CFBundleShortVersionString to the latest
// release on GitHub. If newer, prompts the user to open the release page
// in a browser. No background polling in v1 — only triggered by the
// "Check for updates…" menu item. A daily poll on app launch is a small
// follow-up if the manual check feels tedious.
//
// The repo path is configurable so this works once the user publishes
// to GitHub; for now it points at a placeholder.
enum UpdateChecker {
    // owner/repo on GitHub. Override via the GIT_SYNC_RELEASE_REPO env var
    // if you want to point the menu-bar build at a fork or staging repo
    // without rebuilding.
    static var releaseRepo: String {
        ProcessInfo.processInfo.environment["GIT_SYNC_RELEASE_REPO"]
            ?? "uPaymeiFixit/git-sync"
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func check() async {
        do {
            let release = try await fetchLatestRelease()
            await MainActor.run {
                present(release: release)
            }
        } catch {
            await MainActor.run {
                presentError(error)
            }
        }
    }

    private static func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(releaseRepo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            throw UpdateError.network("HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        return try decoder.decode(Release.self, from: data)
    }

    @MainActor
    private static func present(release: Release) {
        let current = currentVersion
        let latest = release.tagName.replacingOccurrences(of: "v", with: "")
        let alert = NSAlert()
        if SemVer.compare(current, latest) < 0 {
            alert.messageText = "Update available"
            alert.informativeText = """
            A newer release is available.

            Current: \(current)
            Latest:  \(latest)

            Open the release page on GitHub?
            """
            alert.addButton(withTitle: "Open release page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: release.htmlURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            alert.messageText = "You're on the latest version"
            alert.informativeText = "Current: \(current)\nLatest:  \(latest)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @MainActor
    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "\(error)\n\nRelease repo: \(releaseRepo)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct Release: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private enum UpdateError: Error, CustomStringConvertible {
    case network(String)
    var description: String {
        switch self {
        case .network(let msg): return "Network: \(msg)"
        }
    }
}

// Loose semver comparison: split on '.', compare each component as an
// integer, treating missing/non-numeric components as 0. Returns -1 / 0 /
// +1 like strcmp.
enum SemVer {
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let l = parts(lhs)
        let r = parts(rhs)
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0) ?? 0 }
    }
}

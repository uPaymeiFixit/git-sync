import Foundation

// CLI mode: GitSync --diff-engine <dir>
//
// Runs the Swift RepoSyncer.cloneOrUpdate against the same fixture manifest
// that scripts/diff-fixtures.py builds, and writes swift.json in the same
// shape as the Python oracle.json. A wrapper (diff-engine.sh) builds the
// fixtures, runs the Python oracle, runs this, and diffs the two — the
// proof that the port is faithful.
//
// The fixtures use local bare repos as file:// remotes, so this needs no
// network, creds, or platform. GIT_SYNC_ROOT/GIT_SYNC_DEPTH come from the
// manifest dir layout (root/) and a fixed depth=0 to match the oracle.
enum DiffEngineMode {
    struct Fixture: Decodable {
        let name: String
        let ssh_url: String
        let dest: String
        let branch: String
    }
    struct Result: Encodable {
        let name: String
        let status: String
        let detail: String
        let old_sha: String
        let new_sha: String
        let commits_ahead: Int
        let count: Int
    }

    static func run(dir: String) -> Int32 {
        let base = URL(fileURLWithPath: dir)
        let manifestURL = base.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let fixtures = try? JSONDecoder().decode([Fixture].self, from: data) else {
            FileHandle.standardError.write(Data("diff-engine: cannot read manifest.json in \(dir)\n".utf8))
            return 2
        }
        let syncRoot = base.appendingPathComponent("root")
        // Match the oracle's env exactly: full history, C locale, no prompts.
        // No GIT_SSH_COMMAND needed — fixtures are local file paths.
        let env: @Sendable () -> [String: String] = {
            var e = ProcessInfo.processInfo.environment
            e["LC_ALL"] = "C"
            e["GIT_TERMINAL_PROMPT"] = "0"
            return e
        }
        let ctx = GitContext(
            syncRoot: syncRoot,
            depth: 0,
            timeout: 120,
            makeEnv: env
        )

        var results: [Result] = []
        for f in fixtures {
            FileHandle.standardError.write(Data("  [diff] \(f.name)…\n".utf8))
            let outcome = RepoSyncer.cloneOrUpdate(
                platform: "diff",
                rel: relativeTo(syncRoot, f.dest),
                sshURL: f.ssh_url,
                dest: URL(fileURLWithPath: f.dest),
                branch: f.branch,
                ctx: ctx
            )
            results.append(Result(
                name: f.name,
                status: outcome.status.rawValue,
                detail: outcome.detail,
                old_sha: outcome.oldSha,
                new_sha: outcome.newSha,
                commits_ahead: outcome.commitsAhead,
                count: 1
            ))
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let outData = try? enc.encode(results) else { return 1 }
        try? outData.write(to: base.appendingPathComponent("swift.json"))
        FileHandle.standardOutput.write(outData)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    private static func relativeTo(_ root: URL, _ dest: String) -> String {
        let rootPath = root.standardizedFileURL.path
        let destPath = URL(fileURLWithPath: dest).standardizedFileURL.path
        if destPath.hasPrefix(rootPath + "/") {
            return String(destPath.dropFirst(rootPath.count + 1))
        }
        return destPath
    }
}

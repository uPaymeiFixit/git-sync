import Foundation

// End-to-end test for RepoTrasher's safety checks — this is a destructive
// feature, so it gets a real harness like the other risky paths. Builds a
// synthetic sync root under /tmp with four cases and asserts each is
// handled correctly:
//   1. clean repo            → trashed
//   2. dirty repo            → skipped ("uncommitted changes")
//   3. repo with unpushed    → skipped ("unpushed commits")
//   4. non-git directory     → trashed (no git state to protect)
//
// Invoked via:
//   .build/<config>/GitSync.app/Contents/MacOS/GitSync --trash-test
enum TrashTest {
    static func run() -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            box.value = await runAsync()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? 1
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Int32?
    }

    private static func runAsync() async -> Int32 {
        let root = URL(fileURLWithPath: "/tmp/gitsync-trash-test", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: root)

        do {
            try buildFixtures(root: root)
        } catch {
            print("FAIL: couldn't build fixtures: \(error)")
            return 2
        }

        let ids = [
            RepoID(platform: "gitlab", rel: "Gitlab/clean-repo"),
            RepoID(platform: "gitlab", rel: "Gitlab/dirty-repo"),
            RepoID(platform: "gitlab", rel: "Gitlab/unpushed-repo"),
            RepoID(platform: "gitlab", rel: "Gitlab/non-git-dir"),
            RepoID(platform: "gitlab", rel: "Gitlab/not-on-disk"),
        ]
        // Fixtures live at root/<rel>; resolve straight off root and allow that
        // root (mirrors the legacy-fallback path in AppState.diskPathResolver).
        let report = await RepoTrasher.trash(
            ids: ids,
            resolve: { root.appendingPathComponent($0.rel) },
            allowedRoots: [root])

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("  ok   \(label)") }
            else  { print("  FAIL \(label) — \(detail())"); failures += 1 }
        }

        print("RepoTrasher safety checks")
        let trashedRels = Set(report.trashed.map(\.rel))
        let skippedByRel = Dictionary(uniqueKeysWithValues: report.skipped.map { ($0.id.rel, $0.reason) })

        check("clean repo was trashed",
              trashedRels.contains("Gitlab/clean-repo"),
              "report: \(report)")
        check("non-git dir was trashed",
              trashedRels.contains("Gitlab/non-git-dir"))
        check("dirty repo was skipped for uncommitted changes",
              skippedByRel["Gitlab/dirty-repo"] == "uncommitted changes",
              "got \(skippedByRel["Gitlab/dirty-repo"] ?? "—")")
        check("unpushed repo was skipped for unpushed commits",
              skippedByRel["Gitlab/unpushed-repo"] == "unpushed commits",
              "got \(skippedByRel["Gitlab/unpushed-repo"] ?? "—")")
        check("missing repo was skipped as not on disk",
              skippedByRel["Gitlab/not-on-disk"] == "not on disk",
              "got \(skippedByRel["Gitlab/not-on-disk"] ?? "—")")
        check("dirty repo still exists on disk",
              fm.fileExists(atPath: root.appendingPathComponent("Gitlab/dirty-repo").path))
        check("unpushed repo still exists on disk",
              fm.fileExists(atPath: root.appendingPathComponent("Gitlab/unpushed-repo").path))
        check("clean repo is gone from disk",
              !fm.fileExists(atPath: root.appendingPathComponent("Gitlab/clean-repo").path))

        try? fm.removeItem(at: root)

        print()
        if failures == 0 {
            print("Trash test passed.")
            return 0
        } else {
            print("\(failures) check(s) failed.")
            return 1
        }
    }

    private static func buildFixtures(root: URL) throws {
        let fm = FileManager.default
        let platformRoot = root.appendingPathComponent("Gitlab", isDirectory: true)
        try fm.createDirectory(at: platformRoot, withIntermediateDirectories: true)

        // Bare "origin" the unpushed repo can be ahead of.
        let origin = root.appendingPathComponent("origin.git")
        try sh("git", "init", "--bare", "-q", origin.path)

        // 1. clean repo: one committed file, pushed nowhere (no upstream,
        //    no [ahead] marker) and a clean tree.
        let clean = platformRoot.appendingPathComponent("clean-repo")
        try makeRepo(at: clean)

        // 2. dirty repo: committed file + uncommitted modification.
        let dirty = platformRoot.appendingPathComponent("dirty-repo")
        try makeRepo(at: dirty)
        try "modified".write(to: dirty.appendingPathComponent("file.txt"),
                             atomically: true, encoding: .utf8)

        // 3. unpushed repo: tracks origin, then commits past it.
        let unpushed = platformRoot.appendingPathComponent("unpushed-repo")
        try makeRepo(at: unpushed)
        try sh("git", "-C", unpushed.path, "remote", "add", "origin", origin.path)
        try sh("git", "-C", unpushed.path, "push", "-q", "-u", "origin", "HEAD")
        try "more".write(to: unpushed.appendingPathComponent("extra.txt"),
                         atomically: true, encoding: .utf8)
        try sh("git", "-C", unpushed.path, "add", ".")
        try sh("git", "-C", unpushed.path, "commit", "-qm", "local only")

        // 4. plain directory with no .git.
        let nonGit = platformRoot.appendingPathComponent("non-git-dir")
        try fm.createDirectory(at: nonGit, withIntermediateDirectories: true)
        try "leftover".write(to: nonGit.appendingPathComponent("notes.txt"),
                             atomically: true, encoding: .utf8)
    }

    private static func makeRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try sh("git", "init", "-q", url.path)
        try "content".write(to: url.appendingPathComponent("file.txt"),
                            atomically: true, encoding: .utf8)
        try sh("git", "-C", url.path, "add", ".")
        try sh("git", "-C", url.path,
               "-c", "user.email=test@test", "-c", "user.name=Trash Test",
               "commit", "-qm", "init")
    }

    @discardableResult
    private static func sh(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        // Disable commit signing + pin identity so fixture commits don't
        // depend on the user's global commit.gpgsign + SSH/1Password signer
        // (which fails with exit 128 when the agent is locked).
        var env = ProcessInfo.processInfo.environment
        let overrides = [("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
                         ("user.email", "fixture@example.invalid"), ("user.name", "GitSync Fixture")]
        for (i, kv) in overrides.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = kv.0
            env["GIT_CONFIG_VALUE_\(i)"] = kv.1
        }
        env["GIT_CONFIG_COUNT"] = String(overrides.count)
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TrashTest", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(args.joined(separator: " ")): \(out)"])
        }
        return out
    }
}

#!/usr/bin/env python3
"""Differential-test fixtures for the clone_or_update port to Swift.

Builds a battery of self-contained scenarios — each a local bare "remote"
plus (optionally) a local clone in a specific state — that exercise every
branch of clone_or_update's decision tree. Two modes:

  build   <dir>          Create the fixtures under <dir>. Prints a JSON
                         manifest of [{name, ssh_url, dest, branch, setup}].
  oracle  <dir>          Run the REAL Python clone_or_update against each
                         fixture and print JSON [{name, status, detail,
                         old_sha, new_sha, commits_ahead}]. This is the
                         correctness oracle the Swift engine is diffed against.

The Swift side has a matching `--diff-engine <dir>` mode that consumes the
same manifest and emits the same JSON shape; a wrapper diffs oracle vs Swift.

Every fixture uses local paths (bare repos as file:// remotes) so the test
needs no network, no creds, and no real platform.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def sh(*args: str, cwd: str | None = None) -> None:
    subprocess.run(args, check=True, capture_output=True, cwd=cwd)


def git(repo: Path, *args: str) -> None:
    sh("git", "-C", str(repo), *args)


def commit_file(repo: Path, name: str, content: str, msg: str) -> None:
    (repo / name).write_text(content)
    git(repo, "add", ".")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=T", "commit", "-qm", msg)


# Each fixture is a function that, given the base dir, creates a bare remote
# and (maybe) a clone, and returns the (ssh_url, dest, branch) to sync. The
# scenarios are chosen to hit every clone_or_update branch.

def _bare(base: Path, name: str, *, empty: bool, branch: str = "master") -> Path:
    """Create a bare 'remote'. If not empty, seed it with one commit on
    `branch` via a scratch working clone."""
    bare = base / f"{name}.git"
    sh("git", "init", "--bare", "-q", f"--initial-branch={branch}", str(bare))
    if not empty:
        work = base / f"{name}-seed"
        sh("git", "clone", "-q", str(bare), str(work))
        commit_file(work, "README.md", "hello\n", "initial")
        git(work, "push", "-q", "origin", f"HEAD:{branch}")
        shutil.rmtree(work)
    return bare


def build(base: Path) -> list[dict]:
    shutil.rmtree(base, ignore_errors=True)
    root = base / "root" / "Gitlab"
    root.mkdir(parents=True)
    os.environ["GIT_SYNC_ROOT"] = str(base / "root")

    manifest: list[dict] = []

    def add(name: str, bare: Path, dest: Path, branch: str = "master") -> None:
        manifest.append({
            "name": name,
            "ssh_url": str(bare),
            "dest": str(dest),
            "branch": branch,
        })

    # 1. clone a non-empty remote → CLONED
    b = _bare(base, "clone-normal", empty=False)
    add("clone_normal", b, root / "clone-normal")

    # 2. clone an EMPTY remote (branch pinned, will fail then unpinned retry)
    #    → CLONED "empty repository (no commits yet)"
    b = _bare(base, "clone-empty", empty=True)
    add("clone_empty", b, root / "clone-empty")

    # 3. clone where remote's real default branch != API-claimed branch
    #    → CLONED "default branch differs from API"
    b = _bare(base, "clone-branch-mismatch", empty=False, branch="main")
    add("clone_branch_mismatch", b, root / "clone-branch-mismatch", branch="master")

    # 4. update: already up to date → UP_TO_DATE
    b = _bare(base, "up-to-date", empty=False)
    dest = root / "up-to-date"
    sh("git", "clone", "-q", str(b), str(dest))
    add("up_to_date", b, dest)

    # 5. update: remote advanced → UPDATED
    b = _bare(base, "updated", empty=False)
    dest = root / "updated"
    sh("git", "clone", "-q", str(b), str(dest))
    # advance the remote via a scratch clone
    work = base / "updated-adv"
    sh("git", "clone", "-q", str(b), str(work))
    commit_file(work, "f2.txt", "more\n", "second")
    git(work, "push", "-q", "origin", "HEAD:master")
    shutil.rmtree(work)
    add("updated", b, dest)

    # 6. update with non-colliding dirty file, remote advanced → UPDATED_DIRTY
    b = _bare(base, "updated-dirty", empty=False)
    dest = root / "updated-dirty"
    sh("git", "clone", "-q", str(b), str(dest))
    work = base / "ud-adv"
    sh("git", "clone", "-q", str(b), str(work))
    commit_file(work, "server.txt", "srv\n", "server change")
    git(work, "push", "-q", "origin", "HEAD:master")
    shutil.rmtree(work)
    (dest / "local-only.txt").write_text("uncommitted local\n")  # non-colliding
    add("updated_dirty", b, dest)

    # 7. update, up to date, with dirty working tree → DIRTY "up-to-date with uncommitted changes"
    b = _bare(base, "dirty-uptodate", empty=False)
    dest = root / "dirty-uptodate"
    sh("git", "clone", "-q", str(b), str(dest))
    (dest / "README.md").write_text("locally edited\n")  # modifies tracked file
    add("dirty_uptodate", b, dest)

    # 8. update where ff is blocked by colliding dirty change, remote advanced → DIRTY
    b = _bare(base, "dirty-blocks-ff", empty=False)
    dest = root / "dirty-blocks-ff"
    sh("git", "clone", "-q", str(b), str(dest))
    work = base / "dbf-adv"
    sh("git", "clone", "-q", str(b), str(work))
    commit_file(work, "README.md", "server version\n", "server edits README")
    git(work, "push", "-q", "origin", "HEAD:master")
    shutil.rmtree(work)
    (dest / "README.md").write_text("local conflicting edit\n")  # collides
    add("dirty_blocks_ff", b, dest)

    # 9. update where local is purely AHEAD of remote (remote didn't advance).
    #    ff-only to an ancestor is a successful no-op → UP_TO_DATE. (This is
    #    real Python behavior, not divergence — the oracle confirms it.)
    b = _bare(base, "ahead-only", empty=False)
    dest = root / "ahead-only"
    sh("git", "clone", "-q", str(b), str(dest))
    commit_file(dest, "local.txt", "local commit\n", "local only commit")
    add("ahead_only", b, dest)

    # 9b. TRULY diverged: local has a commit AND remote advanced separately.
    #     ff-only fails on diverging branches → DIVERGED (clean, not dirty).
    b = _bare(base, "diverged", empty=False)
    dest = root / "diverged"
    sh("git", "clone", "-q", str(b), str(dest))
    work = base / "div-adv"
    sh("git", "clone", "-q", str(b), str(work))
    commit_file(work, "server-side.txt", "srv\n", "remote-side commit")
    git(work, "push", "-q", "origin", "HEAD:master")
    shutil.rmtree(work)
    commit_file(dest, "local-side.txt", "loc\n", "local-side commit")
    add("diverged", b, dest)

    # 10. update where local is on a different branch → DIVERGED "local on '<x>'"
    b = _bare(base, "wrong-branch", empty=False)
    dest = root / "wrong-branch"
    sh("git", "clone", "-q", str(b), str(dest))
    git(dest, "checkout", "-q", "-b", "feature")
    add("wrong_branch", b, dest, branch="master")

    # 11. update where remote dropped the branch (remote non-empty, no such branch)
    #     → BRANCH_MISSING
    b = _bare(base, "branch-missing", empty=False)  # has 'master'
    dest = root / "branch-missing"
    sh("git", "clone", "-q", str(b), str(dest))
    add("branch_missing", b, dest, branch="nonexistent")

    # 12. update an empty local clone of a still-empty remote → UP_TO_DATE empty
    b = _bare(base, "empty-stays-empty", empty=True)
    dest = root / "empty-stays-empty"
    sh("git", "clone", "-q", str(b), str(dest))  # empty clone, zero refs
    add("empty_stays_empty", b, dest)

    # 13. update an empty local clone whose remote GAINED commits → UPDATED/CLONED-ish
    #     (was_empty path: fetch succeeds, branch now present)
    b = _bare(base, "empty-gains", empty=True)
    dest = root / "empty-gains"
    sh("git", "clone", "-q", str(b), str(dest))
    work = base / "eg-adv"
    sh("git", "clone", "-q", str(b), str(work))
    commit_file(work, "new.txt", "now has commits\n", "first real commit")
    git(work, "push", "-q", "origin", "HEAD:master")
    shutil.rmtree(work)
    add("empty_gains_commits", b, dest)

    # 14. update: local has commits, remote is (still) empty → DIVERGED "local has commits; remote is empty"
    b = _bare(base, "local-vs-empty", empty=True)
    dest = root / "local-vs-empty"
    sh("git", "clone", "-q", str(b), str(dest))  # empty clone
    commit_file(dest, "work.txt", "precious\n", "local work on empty remote")
    add("local_vs_empty", b, dest)

    return manifest


def run_oracle(base: Path, manifest: list[dict]) -> list[dict]:
    os.environ["GIT_SYNC_ROOT"] = str(base / "root")
    # Full history so shallow depth doesn't interfere with the small fixtures.
    os.environ["GIT_SYNC_DEPTH"] = "0"
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import _sync  # noqa: E402

    results: list[dict] = []
    for m in manifest:
        oc = _sync.OutcomeCollector(platform="diff")
        _sync.clone_or_update(
            ssh_url=m["ssh_url"],
            dest=Path(m["dest"]),
            branch=m["branch"],
            outcomes=oc,
            registry=None,
        )
        items = oc.items
        o = items[0] if items else None
        results.append({
            "name": m["name"],
            "status": o.status.value if o else "NONE",
            "detail": o.detail if o else "",
            "old_sha": o.old_sha if o else "",
            "new_sha": o.new_sha if o else "",
            "commits_ahead": o.commits_ahead if o else 0,
            "count": len(items),
        })
    return results


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: diff-fixtures.py [build|oracle] <dir>", file=sys.stderr)
        return 2
    mode, base = sys.argv[1], Path(sys.argv[2])
    if mode == "build":
        manifest = build(base)
        (base / "manifest.json").write_text(json.dumps(manifest, indent=2))
        print(json.dumps(manifest, indent=2))
        return 0
    if mode == "oracle":
        manifest = json.loads((base / "manifest.json").read_text())
        results = run_oracle(base, manifest)
        (base / "oracle.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(results, indent=2))
        return 0
    print(f"unknown mode {mode!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

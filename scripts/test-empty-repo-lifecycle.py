#!/usr/bin/env python3
"""Lifecycle test for the empty-remote retirement in clone_or_update.

Simulates an empty GitLab project with a local bare repo and walks the
states a real one goes through:
  run 1: first sync           -> CLONED  "empty repository (no commits yet)"
  run 2: re-sync, still empty -> UP_TO_DATE "empty repository (no commits yet)"
  run 3: local commit added   -> visible warning (BRANCH_MISSING/DIVERGED), never deleted
  run 4: remote gains commits -> local clone catches up (UPDATED) or reports visibly
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

BASE = Path("/tmp/gitsync-empty-test")
shutil.rmtree(BASE, ignore_errors=True)
(BASE / "root" / "Gitlab").mkdir(parents=True)

os.environ["GIT_SYNC_ROOT"] = str(BASE / "root")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _sync  # noqa: E402

failures = 0


def check(label, ok, detail=""):
    global failures
    if ok:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label} — {detail}")
        failures += 1


def sh(*args):
    subprocess.run(args, check=True, capture_output=True)


def run_sync(dest, branch="master"):
    oc = _sync.OutcomeCollector(platform="test")
    _sync.clone_or_update(
        ssh_url=str(BASE / "empty.git"),
        dest=dest,
        branch=branch,
        outcomes=oc,
        registry=None,
    )
    assert len(oc.items) == 1, f"expected 1 outcome, got {oc.items}"
    return oc.items[0]


print("Empty-repo lifecycle")

# Bare empty "remote" with a deterministic default branch name.
sh("git", "init", "--bare", "-q", "--initial-branch=master", str(BASE / "empty.git"))
dest = BASE / "root" / "Gitlab" / "empty-repo"

# Run 1: first sync clones the empty repo as an empty working copy.
o = run_sync(dest)
check("run 1: status is cloned", o.status == _sync.Status.CLONED, f"got {o.status}")
check("run 1: detail says empty repository", "empty repository" in o.detail, f"got {o.detail!r}")
check("run 1: .git exists on disk", (dest / ".git").is_dir())
check("run 1: zero refs in clone", not _sync._has_any_ref(dest))

# Run 2: second sync sees empty local + empty remote = in sync.
o = run_sync(dest)
check("run 2: status is up-to-date", o.status == _sync.Status.UP_TO_DATE, f"got {o.status}")
check("run 2: detail says empty repository", "empty repository" in o.detail, f"got {o.detail!r}")

# Run 3: user commits locally; sync must surface it and must not delete it.
(dest / "work.txt").write_text("precious local work")
sh("git", "-C", str(dest), "add", ".")
sh("git", "-C", str(dest), "-c", "user.email=t@t", "-c", "user.name=T",
   "commit", "-qm", "local work")
o = run_sync(dest)
check("run 3: local work surfaces as a warning",
      o.status in (_sync.Status.BRANCH_MISSING, _sync.Status.DIVERGED), f"got {o.status}")
check("run 3: local work untouched", (dest / "work.txt").exists())

# Run 4: remote gains commits (pushed from the local clone, as a teammate
# would); next sync brings the previously-empty clone up to date.
sh("git", "-C", str(dest), "push", "-q", "origin", "HEAD:master")
o = run_sync(dest)
check("run 4: clone catches up cleanly",
      o.status in (_sync.Status.UPDATED, _sync.Status.UP_TO_DATE), f"got {o.status} detail={o.detail!r}")

shutil.rmtree(BASE, ignore_errors=True)
print()
if failures:
    print(f"{failures} check(s) failed.")
    sys.exit(1)
print("Lifecycle test passed.")

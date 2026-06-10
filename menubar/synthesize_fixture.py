#!/usr/bin/env python3
"""Emit one of every event kind to stdout, so the parser has a deterministic
fixture to decode against. Bypasses real network / filesystem work by driving
_emit_event directly.

Run from menubar/ to refresh the fixture:
    python3 synthesize_fixture.py \\
        > Sources/GitSyncMenuBar/Resources/all-events.txt
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# This file lives at menubar/synthesize_fixture.py. Repo root is two levels up.
HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

os.environ["GIT_SYNC_EVENTS"] = "1"
os.environ.setdefault("GIT_SYNC_ROOT", "/tmp/gitsync-fixture-stub")

import _sync  # noqa: E402

# Force-enable events even though we set the env after import.
_sync._EVENTS_ENABLED = True

_sync._emit_event("session_start", description="GitLab sync", total=3)
_sync._emit_event("worker_start", rel="group/project-a", op="clone")
_sync._emit_event("worker_phase", rel="group/project-a", phase="receiving", pct=42)
_sync._emit_event("worker_phase", rel="group/project-a", phase="resolving", pct=100)
_sync._emit_event("worker_finish", rel="group/project-a")
_sync._emit_event(
    "outcome",
    rel="group/project-a", status="cloned", url="git@gitlab.example.com:group/project-a.git",
    detail="", old_sha="", new_sha="abc1234", commits_ahead=0,
)
_sync._emit_event(
    "outcome",
    rel="group/project-b", status="dirty", url="git@gitlab.example.com:group/project-b.git",
    detail="uncommitted changes blocked fast-forward",
    old_sha="def5678", new_sha="def5678", commits_ahead=0,
)
_sync._emit_event(
    "outcome",
    rel="group/project-c", status="diverged", url="git@gitlab.example.com:group/project-c.git",
    detail="local has 2 commits not on remote",
    old_sha="aaa1111", new_sha="bbb2222", commits_ahead=2,
)
_sync._emit_event("session_end", description="GitLab sync")

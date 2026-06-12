#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _sync import (  # noqa: E402
    EXIT_SKIPPED, PARALLEL, SYNC_ROOT,
    Job, Outcome, OutcomeCollector, Status,
    _rel, finish_run,
    log_error, log_info, log_ok, log_warn,
    matches_skip, print_outcome_summary, run_jobs, stop_requested,
)

GITLAB_HOST = os.environ.get("GITLAB_HOST")
PLATFORM_ROOT = SYNC_ROOT / "Gitlab"
INCLUDE_ARCHIVED = bool(os.environ.get("GIT_SYNC_INCLUDE_ARCHIVED"))


class CredsNotConfigured(RuntimeError):
    """glab not installed or not authed for this host — skip the platform gracefully."""


# Errors we'll retry on. Transient network/VPN blips look like "no route to
# host", "connection refused", or a 5xx from GitLab itself. Auth errors (401)
# and "not found" (404) are not transient — fail fast on those.
_RETRYABLE_PATTERNS = (
    "no route to host",
    "connection refused",
    "connection reset",
    "i/o timeout",
    "tls handshake timeout",
    "EOF",
    "temporary failure in name resolution",
    "502",
    "503",
    "504",
)


def _is_retryable_glab_error(stderr: str) -> bool:
    lower = stderr.lower()
    return any(pat.lower() in lower for pat in _RETRYABLE_PATTERNS)


def _glab_api_single(path: str, *, attempts: int = 4, backoff: float = 2.0):
    """One glab api call, with retry on transient network failures.

    glab itself doesn't retry, so a single dropped TCP connection mid-listing
    nukes the whole discovery (which then forces a full re-run). We retry on
    network-shaped error strings with jittered exponential backoff, and fail
    fast on auth/permission/not-found errors.
    """
    delay = backoff
    last_err = ""
    for attempt in range(1, attempts + 1):
        if stop_requested():
            raise RuntimeError("aborted")
        result = subprocess.run(
            ["glab", "api", "--hostname", GITLAB_HOST, path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        last_err = (result.stderr or "").strip()
        if attempt >= attempts or not _is_retryable_glab_error(last_err):
            raise RuntimeError(f"glab api {path} failed: {last_err}")
        # Jitter ±50% to spread out retries if anything ever calls this
        # concurrently for the same transient failure.
        sleep_for = delay * random.uniform(0.5, 1.5)
        log_warn(
            f"glab api {path}: attempt {attempt} failed (transient); "
            f"retrying in {sleep_for:.0f}s"
        )
        time.sleep(sleep_for)
        delay *= 2
    raise RuntimeError(f"glab api {path} failed: {last_err}")


_PER_PAGE_RE = re.compile(r"[?&]per_page=(\d+)")


def glab_api(path: str, *, paginate: bool = True):
    """Call the GitLab API. When paginate=True and the endpoint returns a list,
    walk pages by appending &page=N until an empty page is returned.

    We do pagination manually instead of via `glab --paginate` because that flag
    concatenates per-page JSON arrays into a single non-parseable stream
    (`[...][...][...]` rather than one merged array).
    """
    if not paginate:
        return _glab_api_single(path)

    m = _PER_PAGE_RE.search(path)
    per_page = int(m.group(1)) if m else 20  # GitLab default
    sep = "&" if "?" in path else "?"
    page = 1
    merged: list = []
    while True:
        chunk = _glab_api_single(f"{path}{sep}page={page}")
        if not isinstance(chunk, list):
            # Endpoint doesn't return a list — return as-is (no pagination possible).
            return chunk
        if not chunk:
            break
        merged.extend(chunk)
        if len(chunk) < per_page:
            break
        page += 1
    return merged


def _check_glab_available() -> None:
    """Raise CredsNotConfigured if glab isn't installed or isn't authed for GITLAB_HOST."""
    try:
        which = subprocess.run(
            ["glab", "--version"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        raise CredsNotConfigured(
            "glab not installed — install it (https://gitlab.com/gitlab-org/cli) "
            f"and run: glab auth login --hostname {GITLAB_HOST}"
        ) from None
    if which.returncode != 0:
        raise CredsNotConfigured("glab is installed but `glab --version` failed")

    status = subprocess.run(
        ["glab", "auth", "status", "--hostname", GITLAB_HOST],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if status.returncode != 0:
        raise CredsNotConfigured(
            f"glab not authenticated for {GITLAB_HOST} — "
            f"run: glab auth login --hostname {GITLAB_HOST}"
        )


def main() -> int:
    if os.environ.get("GIT_SYNC_SKIP_GITLAB"):
        log_info("Skipping GitLab — GIT_SYNC_SKIP_GITLAB is set.")
        return EXIT_SKIPPED

    if not GITLAB_HOST:
        log_info(
            "Skipping GitLab — GITLAB_HOST is not set. "
            "To enable: set GITLAB_HOST to your GitLab instance hostname "
            "(e.g. gitlab.example.com) and ensure `glab auth login --hostname <host>` "
            "has been run."
        )
        return EXIT_SKIPPED

    log_info(f"Pre-flight: glab API at {GITLAB_HOST}")
    try:
        _check_glab_available()
    except CredsNotConfigured as e:
        log_info(f"Skipping GitLab — {e}")
        return EXIT_SKIPPED

    try:
        glab_api("version", paginate=False)
    except (RuntimeError, json.JSONDecodeError) as e:
        log_error(f"Cannot reach {GITLAB_HOST}/api/v4 — is VPN up?")
        log_error(str(e))
        return 1

    archived_qs = "" if INCLUDE_ARCHIVED else "&archived=false"
    archived_msg = " (including archived)" if INCLUDE_ARCHIVED else ""
    log_info(f"Listing projects visible to your token on {GITLAB_HOST}{archived_msg}...")
    discovery_errors = 0
    try:
        projects = glab_api(
            f"projects?min_access_level=10{archived_qs}&simple=true&per_page=100"
        )
    except (RuntimeError, json.JSONDecodeError) as e:
        log_error(str(e))
        return 1

    if not projects:
        log_error("No projects visible. Are you a member of any?")
        return 1

    seen: set[str] = set()
    jobs: list[Job] = []
    skipped: list[Outcome] = []
    for p in projects:
        branch = p.get("default_branch")
        if not branch:
            continue
        url = p.get("ssh_url_to_repo")
        path_ns = p.get("path_with_namespace")
        if not url or not path_ns:
            continue
        if url in seen:
            continue
        seen.add(url)
        dest = PLATFORM_ROOT / path_ns
        if matches_skip(path_ns):
            skipped.append(Outcome(rel=_rel(dest), status=Status.SKIPPED, url=url))
            continue
        jobs.append(Job(ssh_url=url, dest=dest, branch=branch))

    if not jobs and not skipped:
        log_warn("No projects found. Nothing to do.")
        return 0

    if skipped:
        log_info(f"Skipping {len(skipped)} project(s) matching GIT_SYNC_SKIP.")

    log_info(f"Found {len(jobs)} projects to sync. Using {PARALLEL} parallel workers...")
    outcomes = OutcomeCollector(platform="gitlab")
    run_jobs(jobs, outcomes, description="GitLab sync")

    log_info(f"Scanning {PLATFORM_ROOT} for stale and non-git directories...")
    all_outcomes = finish_run(
        PLATFORM_ROOT, jobs, skipped, outcomes,
        discovery_complete=(discovery_errors == 0),
    )
    had_errors = print_outcome_summary(all_outcomes)
    if had_errors or discovery_errors:
        log_warn("GitLab sync finished with errors. Re-run to retry.")
        return 1
    log_ok("GitLab sync complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

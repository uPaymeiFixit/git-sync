#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _sync import (  # noqa: E402
    EXIT_SKIPPED, PARALLEL, SYNC_ROOT,
    Job, Outcome, OutcomeCollector, Status,
    _rel, finish_run,
    log_error, log_info, log_ok, log_warn,
    matches_skip, print_outcome_summary, run_jobs,
)

GITLAB_HOST = os.environ.get("GITLAB_HOST")
PLATFORM_ROOT = SYNC_ROOT / "Gitlab"


class CredsNotConfigured(RuntimeError):
    """glab not installed or not authed for this host — skip the platform gracefully."""


def _glab_api_single(path: str):
    """One glab api call. Caller handles pagination."""
    result = subprocess.run(
        ["glab", "api", "--hostname", GITLAB_HOST, path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"glab api {path} failed: {(result.stderr or '').strip()}")
    return json.loads(result.stdout)


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

    log_info(f"Listing top-level groups on {GITLAB_HOST}...")
    try:
        groups = glab_api("groups?top_level_only=true&per_page=100")
    except (RuntimeError, json.JSONDecodeError) as e:
        log_error(str(e))
        return 1

    if not groups:
        log_error("No top-level groups visible. Are you a member of any?")
        return 1

    log_info(f"Walking {len(groups)} top-level group(s) for non-archived projects...")

    seen: set[str] = set()
    jobs: list[Job] = []
    skipped: list[Outcome] = []
    discovery_errors = 0
    for group in groups:
        gid = group["id"]
        try:
            projects = glab_api(
                f"groups/{gid}/projects?include_subgroups=true&archived=false&per_page=100"
            )
        except (RuntimeError, json.JSONDecodeError) as e:
            log_error(f"list projects in group {gid}: {e}")
            discovery_errors += 1
            continue
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
    outcomes = OutcomeCollector()
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

#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from netrc import NetrcParseError, netrc
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _sync import (  # noqa: E402
    EXIT_SKIPPED, PARALLEL, SYNC_ROOT,
    Job, Outcome, OutcomeCollector, Status,
    _rel, emit_remote_project, finish_run,
    log_error, log_info, log_ok, log_warn,
    matches_skip, print_outcome_summary, run_jobs,
)

WORKSPACE = os.environ.get("GIT_SYNC_BITBUCKET_WORKSPACE")
DEST_ROOT = SYNC_ROOT / "Bitbucket"
API = "https://api.bitbucket.org/2.0"
NETRC_HOST = "api.bitbucket.org"


class CredsNotConfigured(RuntimeError):
    """No Bitbucket credentials configured — skip the platform gracefully."""


def _netrc_creds() -> tuple[str, str] | None:
    try:
        creds = netrc().authenticators(NETRC_HOST)
    except (FileNotFoundError, NetrcParseError):
        return None
    if not creds:
        return None
    user, _account, password = creds
    if not user or not password:
        return None
    return user, password


def _have_creds() -> bool:
    if _netrc_creds():
        return True
    return bool(
        os.environ.get("GIT_SYNC_BITBUCKET_USER")
        and os.environ.get("GIT_SYNC_BITBUCKET_APP_PASSWORD")
    )


def basic_auth_header() -> str:
    env_user = os.environ.get("GIT_SYNC_BITBUCKET_USER")
    env_pass = os.environ.get("GIT_SYNC_BITBUCKET_APP_PASSWORD")
    netrc_creds = _netrc_creds()

    if netrc_creds:
        user, password = netrc_creds
    elif env_user and env_pass:
        user, password = env_user, env_pass
    else:
        raise CredsNotConfigured(
            f"no Bitbucket credentials — add a ~/.netrc entry for {NETRC_HOST} "
            "or set GIT_SYNC_BITBUCKET_USER and GIT_SYNC_BITBUCKET_APP_PASSWORD"
        )

    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return f"Basic {token}"


class HTTPCode(RuntimeError):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(f"HTTP {code}: {message}")
        self.code = code


def http_get_json(url: str, auth_header: str, *, attempts: int = 5, backoff: float = 2.0) -> dict:
    delay = backoff
    last_err = ""
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(
            url,
            headers={"Authorization": auth_header, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 404):
                raise HTTPCode(e.code, e.reason) from e
            last_err = f"HTTP {e.code}: {e.reason}"
        except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
            last_err = str(e)
        if attempt < attempts:
            log_warn(f"GET {url}: attempt {attempt} failed ({last_err}); retrying in {delay:.0f}s")
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"GET {url} failed after {attempts} attempts: {last_err}")


def main() -> int:
    if os.environ.get("GIT_SYNC_SKIP_BITBUCKET"):
        log_info("Skipping Bitbucket — GIT_SYNC_SKIP_BITBUCKET is set.")
        return EXIT_SKIPPED

    creds_present = _have_creds()
    workspace_set = bool(WORKSPACE)

    # Only acquire the lock once we know we're actually going to run.
    # The early-return skip/error paths below don't need a lock.

    if not creds_present and not workspace_set:
        log_info(
            "Skipping Bitbucket — no credentials and GIT_SYNC_BITBUCKET_WORKSPACE not set. "
            "To enable: configure ~/.netrc (or GIT_SYNC_BITBUCKET_USER/"
            "GIT_SYNC_BITBUCKET_APP_PASSWORD) and set GIT_SYNC_BITBUCKET_WORKSPACE."
        )
        return EXIT_SKIPPED

    if creds_present and not workspace_set:
        log_error(
            "Bitbucket credentials are configured but GIT_SYNC_BITBUCKET_WORKSPACE is "
            "not set. Set it to the workspace slug (the part after bitbucket.org/ in "
            "repo URLs)."
        )
        return 1

    if workspace_set and not creds_present:
        log_info(
            f"Skipping Bitbucket — GIT_SYNC_BITBUCKET_WORKSPACE='{WORKSPACE}' is set "
            f"but no credentials configured. Add a ~/.netrc entry for {NETRC_HOST} or "
            "set GIT_SYNC_BITBUCKET_USER and GIT_SYNC_BITBUCKET_APP_PASSWORD."
        )
        return EXIT_SKIPPED

    platform_root = DEST_ROOT

    log_info(f"Pre-flight: Bitbucket API auth (repo read on '{WORKSPACE}')")
    try:
        auth = basic_auth_header()
    except CredsNotConfigured as e:
        log_info(f"Skipping Bitbucket — {e}")
        return EXIT_SKIPPED
    except (FileNotFoundError, NetrcParseError, RuntimeError) as e:
        log_error(f"Bitbucket auth setup: {e}")
        return 1

    try:
        http_get_json(
            f"{API}/repositories/{WORKSPACE}?pagelen=1&fields=values.slug",
            auth,
            attempts=3,
        )
    except HTTPCode as e:
        if e.code == 401:
            log_error("401 from Bitbucket — bad/missing creds. Check ~/.netrc entry for api.bitbucket.org.")
        elif e.code == 403:
            log_error(f"403 from Bitbucket — token lacks 'read:repository:bitbucket' scope (or no access to workspace '{WORKSPACE}').")
        elif e.code == 404:
            log_error(f"404 — workspace '{WORKSPACE}' not found or invisible to this token.")
        else:
            log_error(f"Bitbucket pre-flight: {e}")
        return 1
    except RuntimeError as e:
        log_error(f"Bitbucket pre-flight: {e}")
        return 1

    log_info(f"Listing repos in workspace '{WORKSPACE}'...")
    jobs: list[Job] = []
    skipped: list[Outcome] = []
    seen: set[str] = set()
    next_url = (
        f"{API}/repositories/{WORKSPACE}"
        "?pagelen=100&fields=values.slug,values.mainbranch.name,values.links.clone,next"
    )
    page_num = 0
    while next_url:
        page_num += 1
        try:
            page = http_get_json(next_url, auth)
        except (HTTPCode, RuntimeError) as e:
            log_error(f"fetch page {page_num}: {e}")
            return 1
        for v in page.get("values", []):
            mb = (v.get("mainbranch") or {}).get("name")
            if not mb:
                continue
            ssh = next(
                (c.get("href") for c in (v.get("links", {}).get("clone") or [])
                 if c.get("name") == "ssh"),
                None,
            )
            if not ssh:
                continue
            slug = v.get("slug")
            if not slug or slug in seen:
                continue
            seen.add(slug)
            dest = platform_root / slug
            # Emit BEFORE skip-filtering so the menu-bar app inventory sees
            # every remote-known repo, not just the ones we end up syncing.
            emit_remote_project(
                platform="bitbucket",
                rel=_rel(dest),
                ssh_url=ssh,
                default_branch=mb,
            )
            if matches_skip(slug):
                skipped.append(Outcome(rel=_rel(dest), status=Status.SKIPPED, url=ssh))
                continue
            jobs.append(Job(ssh_url=ssh, dest=dest, branch=mb))
        next_url = page.get("next") or ""

    if not jobs and not skipped:
        log_warn(f"No repos found in workspace '{WORKSPACE}'. Nothing to do.")
        return 0

    if skipped:
        log_info(f"Skipping {len(skipped)} repo(s) matching GIT_SYNC_SKIP.")

    log_info(f"Found {len(jobs)} repos to sync. Using {PARALLEL} parallel workers...")
    outcomes = OutcomeCollector(platform="bitbucket")
    run_jobs(jobs, outcomes, description="Bitbucket sync")

    log_info(f"Scanning {platform_root} for stale and non-git directories...")
    all_outcomes = finish_run(platform_root, jobs, skipped, outcomes)
    had_errors = print_outcome_summary(all_outcomes)
    if had_errors:
        log_warn("Bitbucket sync finished with errors. Re-run to retry.")
        return 1
    log_ok("Bitbucket sync complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

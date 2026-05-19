#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import re
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
    _rel, finish_run,
    log_error, log_info, log_ok, log_warn,
    matches_skip, print_outcome_summary, run_jobs,
)

ORG = os.environ.get("GIT_SYNC_GITHUB_ORG")
DEST_ROOT = SYNC_ROOT / "Github"
API = "https://api.github.com"
NETRC_HOST = "api.github.com"


class CredsNotConfigured(RuntimeError):
    """No GitHub credentials configured — skip the platform gracefully."""


def _netrc_creds() -> tuple[str, str] | None:
    """Returns (user, token) or None."""
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
    return bool(os.environ.get("GIT_SYNC_GITHUB_TOKEN"))


def auth_header() -> str:
    """Returns the Authorization header value.

    Prefers ~/.netrc Basic auth; falls back to GIT_SYNC_GITHUB_TOKEN as a
    Bearer token. Raises CredsNotConfigured if neither is set.
    """
    netrc_creds = _netrc_creds()
    if netrc_creds:
        user, password = netrc_creds
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        return f"Basic {token}"

    env_token = os.environ.get("GIT_SYNC_GITHUB_TOKEN")
    if env_token:
        return f"Bearer {env_token}"

    raise CredsNotConfigured(
        f"no GitHub credentials — add a ~/.netrc entry for {NETRC_HOST} "
        "or set GIT_SYNC_GITHUB_TOKEN"
    )


class HTTPCode(RuntimeError):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(f"HTTP {code}: {message}")
        self.code = code


_LINK_NEXT_RE = re.compile(r'<([^>]+)>;\s*rel="next"')


def _parse_next_link(link_header: str) -> str:
    """Extract the rel=next URL from a GitHub Link header, or '' if none."""
    if not link_header:
        return ""
    m = _LINK_NEXT_RE.search(link_header)
    return m.group(1) if m else ""


def http_get_json(url: str, auth: str, *, attempts: int = 5, backoff: float = 2.0) -> tuple:
    """GET + JSON-decode with retries. Returns (data, next_url).

    next_url is the rel=next URL from the Link header (for pagination), or ''.
    """
    delay = backoff
    last_err = ""
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": auth,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "git-sync",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read())
                link = resp.headers.get("Link", "")
                return data, _parse_next_link(link)
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
    creds_present = _have_creds()
    org_set = bool(ORG)

    if not creds_present and not org_set:
        log_info(
            "Skipping GitHub — no credentials and GIT_SYNC_GITHUB_ORG not set. "
            "To enable: configure ~/.netrc (or GIT_SYNC_GITHUB_TOKEN) and set "
            "GIT_SYNC_GITHUB_ORG."
        )
        return EXIT_SKIPPED

    if creds_present and not org_set:
        log_error(
            "GitHub credentials are configured but GIT_SYNC_GITHUB_ORG is not "
            "set. Set it to the GitHub organization name (the part after "
            "github.com/ in org URLs)."
        )
        return 1

    if org_set and not creds_present:
        log_info(
            f"Skipping GitHub — GIT_SYNC_GITHUB_ORG='{ORG}' is set but no "
            f"credentials configured. Add a ~/.netrc entry for {NETRC_HOST} "
            "or set GIT_SYNC_GITHUB_TOKEN."
        )
        return EXIT_SKIPPED

    platform_root = DEST_ROOT

    log_info(f"Pre-flight: GitHub API auth (org read on '{ORG}')")
    try:
        auth = auth_header()
    except CredsNotConfigured as e:
        log_info(f"Skipping GitHub — {e}")
        return EXIT_SKIPPED
    except (FileNotFoundError, NetrcParseError, RuntimeError) as e:
        log_error(f"GitHub auth setup: {e}")
        return 1

    try:
        http_get_json(f"{API}/orgs/{ORG}?per_page=1", auth, attempts=3)
    except HTTPCode as e:
        if e.code == 401:
            log_error("401 from GitHub — bad/missing token. Check ~/.netrc entry for api.github.com or GIT_SYNC_GITHUB_TOKEN.")
        elif e.code == 403:
            log_error(f"403 from GitHub — token lacks scope to read org '{ORG}' (need 'repo' scope on classic PATs, or 'Contents: Read' + 'Metadata: Read' on fine-grained).")
        elif e.code == 404:
            log_error(f"404 — org '{ORG}' not found or invisible to this token.")
        else:
            log_error(f"GitHub pre-flight: {e}")
        return 1
    except RuntimeError as e:
        log_error(f"GitHub pre-flight: {e}")
        return 1

    log_info(f"Listing repos in org '{ORG}'...")
    jobs: list[Job] = []
    skipped: list[Outcome] = []
    seen: set[str] = set()
    next_url = f"{API}/orgs/{ORG}/repos?per_page=100&type=all"
    page_num = 0
    while next_url:
        page_num += 1
        try:
            page, next_url = http_get_json(next_url, auth)
        except (HTTPCode, RuntimeError) as e:
            log_error(f"fetch page {page_num}: {e}")
            return 1
        for v in page:
            # Skip archived repos to match GitLab behavior (we filter
            # ?archived=false there). GitHub doesn't have a server-side
            # filter for this on the org-repos endpoint.
            if v.get("archived"):
                continue
            branch = v.get("default_branch")
            if not branch:
                continue
            ssh = v.get("ssh_url")
            name = v.get("name")
            if not ssh or not name or name in seen:
                continue
            seen.add(name)
            dest = platform_root / name
            if matches_skip(name):
                skipped.append(Outcome(rel=_rel(dest), status=Status.SKIPPED, url=ssh))
                continue
            jobs.append(Job(ssh_url=ssh, dest=dest, branch=branch))

    if not jobs and not skipped:
        log_warn(f"No repos found in org '{ORG}'. Nothing to do.")
        return 0

    if skipped:
        log_info(f"Skipping {len(skipped)} repo(s) matching GIT_SYNC_SKIP.")

    log_info(f"Found {len(jobs)} repos to sync. Using {PARALLEL} parallel workers...")
    outcomes = OutcomeCollector()
    run_jobs(jobs, outcomes, description="GitHub sync")

    log_info(f"Scanning {platform_root} for stale and non-git directories...")
    all_outcomes = finish_run(platform_root, jobs, skipped, outcomes)
    had_errors = print_outcome_summary(all_outcomes)
    if had_errors:
        log_warn("GitHub sync finished with errors. Re-run to retry.")
        return 1
    log_ok("GitHub sync complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Shared sync helpers. Imported by the per-platform entry scripts."""
from __future__ import annotations

import atexit
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

_SYNC_ROOT_ENV = os.environ.get("GIT_SYNC_ROOT")
if not _SYNC_ROOT_ENV:
    print(
        "error: GIT_SYNC_ROOT is not set. Set it to the directory where synced "
        "repos should live, e.g. `export GIT_SYNC_ROOT=$HOME/git/synced`.",
        file=sys.stderr,
    )
    sys.exit(1)
SYNC_ROOT = Path(_SYNC_ROOT_ENV).expanduser()
PARALLEL = int(os.environ.get("GIT_SYNC_PARALLEL", "8"))

# Max seconds for any single git subprocess (clone or fetch). Large legacy
# repos can take many minutes on a first clone; the default needs enough
# headroom for those. Increase via env var if you have unusually large repos.
TIMEOUT = int(os.environ.get("GIT_SYNC_TIMEOUT", "1800"))
if TIMEOUT <= 0:
    print(
        f"error: GIT_SYNC_TIMEOUT must be > 0 (got {TIMEOUT}).",
        file=sys.stderr,
    )
    sys.exit(1)

# Clone/fetch depth. 0 means no --depth flag (full history).
DEPTH = int(os.environ.get("GIT_SYNC_DEPTH", "100"))
if DEPTH < 0:
    print(
        f"error: GIT_SYNC_DEPTH must be >= 0 (got {DEPTH}). Use 0 for full history.",
        file=sys.stderr,
    )
    sys.exit(1)


def _depth_args() -> list[str]:
    """Return ['--depth', str(N)] or [] when full history is requested."""
    return ["--depth", str(DEPTH)] if DEPTH > 0 else []


# Exit code meaning "platform skipped — not a failure, just nothing to do."
EXIT_SKIPPED = 2


def _parse_skip_list(raw: str) -> list[str]:
    """Parse GIT_SYNC_SKIP into a list of lowercased path prefixes."""
    if not raw:
        return []
    return [
        p.strip().strip("/").lower()
        for p in raw.split(",")
        if p.strip().strip("/")
    ]


SKIP_PATTERNS = _parse_skip_list(os.environ.get("GIT_SYNC_SKIP", ""))


def matches_skip(repo_path: str) -> bool:
    """True if repo_path matches any GIT_SYNC_SKIP pattern (case-insensitive prefix)."""
    if not SKIP_PATTERNS:
        return False
    p = repo_path.strip("/").lower()
    for pattern in SKIP_PATTERNS:
        if p == pattern or p.startswith(pattern + "/"):
            return True
    return False


# ---- Logging ----

_TTY = sys.stderr.isatty()
C_RED = "\033[31m" if _TTY else ""
C_YEL = "\033[33m" if _TTY else ""
C_GRN = "\033[32m" if _TTY else ""
C_CYA = "\033[36m" if _TTY else ""
C_MAG = "\033[35m" if _TTY else ""
C_DIM = "\033[2m" if _TTY else ""
C_BLD = "\033[1m" if _TTY else ""
C_OFF = "\033[0m" if _TTY else ""

_log_lock = threading.Lock()

# When a LiveDisplay is active it pins a status block at the bottom of the
# terminal. Log writes need to scroll *above* that block, so they erase it
# before writing and the next render redraws it. We track the line count
# here so log_* and the display agree on what to erase.
_display_lines = 0


def _ts() -> str:
    return time.strftime("%H:%M:%S")


def _erase_display_locked() -> None:
    """Erase the current live-display block. Caller must hold _log_lock."""
    global _display_lines
    if _display_lines > 0 and _TTY:
        sys.stderr.write(f"\033[{_display_lines}A\033[J")
        sys.stderr.flush()
        _display_lines = 0


def log_info(msg: str) -> None:
    with _log_lock:
        _erase_display_locked()
        print(f"{C_DIM}[{_ts()}]{C_OFF} {msg}", file=sys.stderr, flush=True)


def log_ok(msg: str) -> None:
    with _log_lock:
        _erase_display_locked()
        print(f"{C_GRN}[{_ts()}] ok {msg}{C_OFF}", file=sys.stderr, flush=True)


def log_warn(msg: str) -> None:
    with _log_lock:
        _erase_display_locked()
        print(f"{C_YEL}[{_ts()}] !  {msg}{C_OFF}", file=sys.stderr, flush=True)


def log_error(msg: str) -> None:
    with _log_lock:
        _erase_display_locked()
        print(f"{C_RED}[{_ts()}] x  {msg}{C_OFF}", file=sys.stderr, flush=True)


# ---- Live worker display ----
#
# When running in a TTY we pin a status block to the bottom of the terminal
# showing what every worker is currently doing. Non-TTY runs (cron, piped
# output) skip the display entirely and fall back to the periodic
# `progress: N/M` log line in run_jobs.

@dataclass
class _WorkerState:
    rel: str
    op: str  # "clone" or "fetch"
    started_at: float
    phase: str = "starting"
    pct: "int | None" = None  # populated in commit 2


class _WorkerRegistry:
    """Thread-safe map of worker key -> _WorkerState."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._states: dict[int, _WorkerState] = {}

    def start(self, key: int, rel: str, op: str) -> None:
        with self._lock:
            self._states[key] = _WorkerState(rel=rel, op=op, started_at=time.monotonic())

    def set_phase(self, key: int, phase: str, pct: "int | None" = None) -> None:
        with self._lock:
            st = self._states.get(key)
            if st is not None:
                st.phase = phase
                st.pct = pct

    def finish(self, key: int) -> None:
        with self._lock:
            self._states.pop(key, None)

    def snapshot(self) -> list[_WorkerState]:
        with self._lock:
            # Sort by start time so the list order is stable as workers come and go.
            return sorted(self._states.values(), key=lambda s: s.started_at)


def _hide_cursor() -> None:
    if _TTY:
        sys.stderr.write("\033[?25l")
        sys.stderr.flush()


def _show_cursor() -> None:
    if _TTY:
        sys.stderr.write("\033[?25h")
        sys.stderr.flush()


def _cleanup_terminal() -> None:
    """atexit hook: erase any leftover display block and restore the cursor."""
    with _log_lock:
        _erase_display_locked()
    _show_cursor()


atexit.register(_cleanup_terminal)


# Re-raise SIGINT after cleaning up. We install this lazily inside _LiveDisplay
# so non-TTY runs don't alter the default signal behavior.
_prev_sigint_handler: "object | None" = None


def _sigint_handler(signum, frame) -> None:  # noqa: ANN001 — signal handler signature
    _cleanup_terminal()
    # Restore prior handler and re-raise so the user's Ctrl-C still terminates.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGINT)


def _format_elapsed(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}"


class _LiveDisplay:
    """Background thread that renders a pinned status block to stderr."""

    RENDER_INTERVAL = 0.25

    def __init__(
        self,
        registry: _WorkerRegistry,
        outcomes: "OutcomeCollector",
        total: int,
        description: str,
    ) -> None:
        self._registry = registry
        self._outcomes = outcomes
        self._total = total
        self._description = description
        self._stop = threading.Event()
        self._thread: "threading.Thread | None" = None
        self._started_at = time.monotonic()

    def start(self) -> None:
        if not _TTY:
            return
        global _prev_sigint_handler
        _prev_sigint_handler = signal.getsignal(signal.SIGINT)
        try:
            signal.signal(signal.SIGINT, _sigint_handler)
        except ValueError:
            # signal.signal only works in the main thread; tolerate that.
            pass
        _hide_cursor()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._thread is None:
            return
        self._stop.set()
        self._thread.join(timeout=2)
        with _log_lock:
            _erase_display_locked()
        _show_cursor()
        if _prev_sigint_handler is not None:
            try:
                signal.signal(signal.SIGINT, _prev_sigint_handler)
            except (ValueError, TypeError):
                pass

    def _loop(self) -> None:
        while not self._stop.is_set():
            self._render()
            self._stop.wait(self.RENDER_INTERVAL)

    def _render(self) -> None:
        lines = self._format_lines()
        with _log_lock:
            global _display_lines
            _erase_display_locked()
            if not lines:
                return
            sys.stderr.write("\n".join(lines))
            sys.stderr.write("\n")
            sys.stderr.flush()
            _display_lines = len(lines)

    def _format_lines(self) -> list[str]:
        width = shutil.get_terminal_size((100, 24)).columns
        states = self._registry.snapshot()
        done = len(self._outcomes)
        elapsed = _format_elapsed(time.monotonic() - self._started_at)

        # Tally outcomes by category for the header counters.
        counts = {"cloned": 0, "updated": 0, "errors": 0, "skipped": 0}
        for o in self._outcomes.items:
            if o.status == Status.CLONED:
                counts["cloned"] += 1
            elif o.status == Status.UPDATED:
                counts["updated"] += 1
            elif o.status == Status.ERROR:
                counts["errors"] += 1
            elif o.status == Status.SKIPPED:
                counts["skipped"] += 1

        header = (
            f"{C_DIM}[{elapsed}]{C_OFF} {C_BLD}{self._description}{C_OFF} "
            f"— {done} / {self._total}"
        )
        summary = (
            f"  {C_GRN}cloned: {counts['cloned']}{C_OFF}  "
            f"{C_GRN}updated: {counts['updated']}{C_OFF}  "
            f"{C_RED}errors: {counts['errors']}{C_OFF}  "
            f"{C_DIM}skipped: {counts['skipped']}{C_OFF}"
        )
        workers_header = f"  workers ({len(states)}):"

        out = [header, summary, workers_header]
        for st in states:
            out.append(self._format_worker_line(st, width))
        return out

    def _format_worker_line(self, st: _WorkerState, width: int) -> str:
        elapsed = _format_elapsed(time.monotonic() - st.started_at)
        if st.pct is not None:
            phase_str = f"{st.phase} {st.pct}%"
        else:
            phase_str = st.phase
        prefix = f"    • [{elapsed}] "
        suffix = f"  {phase_str}"
        # Reserve room for prefix + suffix; truncate the repo path to fit.
        budget = max(20, width - len(prefix) - len(suffix) - 1)
        rel = st.rel
        if len(rel) > budget:
            rel = rel[: budget - 1] + "…"
        return f"{prefix}{rel}{C_DIM}{suffix}{C_OFF}"


# ---- Outcome model ----

class Status(str, Enum):
    CLONED = "cloned"
    UPDATED = "updated"
    UP_TO_DATE = "up-to-date"
    EMPTY_REMOTE = "empty-remote"
    DIRTY = "dirty"
    DIVERGED = "diverged"
    BRANCH_MISSING = "branch-missing"
    STALE_ON_DISK = "stale-on-disk"
    NON_GIT_DIR = "non-git-dir"
    SKIPPED = "skipped"
    ERROR = "error"


@dataclass
class Outcome:
    rel: str
    status: Status
    url: str = ""
    detail: str = ""
    old_sha: str = ""
    new_sha: str = ""
    commits_ahead: int = 0


class OutcomeCollector:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._items: list[Outcome] = []

    def add(self, o: Outcome) -> None:
        with self._lock:
            self._items.append(o)

    @property
    def items(self) -> list[Outcome]:
        with self._lock:
            return list(self._items)

    def __len__(self) -> int:
        with self._lock:
            return len(self._items)


@dataclass
class Job:
    ssh_url: str
    dest: Path
    branch: str


# ---- Subprocess plumbing ----

_BRANCH_MISSING_RE = re.compile(r"Remote branch .* not found in upstream origin")
# Emitted by `git clone` when the remote responds but has no usable HEAD —
# almost always a truly empty repo whose API metadata still reports a default
# branch. Not a real failure, classify as empty-remote.
_NO_MATCHING_HEAD_RE = re.compile(r"no matching remote head", re.IGNORECASE)

# Git lock files left behind by killed processes. We remove these before fetch,
# but only when they're older than _STALE_LOCK_AGE_SECS — a real `git commit`
# running concurrently in the user's editor produces an index.lock that
# completes in well under that, so the age check protects active work.
_STALE_GIT_LOCKS = ("shallow.lock", "index.lock", "packed-refs.lock")
_STALE_LOCK_AGE_SECS = 30


def _clean_stale_locks(repo: Path) -> list[str]:
    """Remove .git/*.lock files older than _STALE_LOCK_AGE_SECS. Returns the
    names of files removed. Skips locks that are too young because they might
    belong to a live git process (e.g. a commit the user is in the middle of)."""
    git_dir = repo / ".git"
    if not git_dir.is_dir():
        return []
    removed: list[str] = []
    now = time.time()
    for name in _STALE_GIT_LOCKS:
        lock = git_dir / name
        try:
            mtime = lock.stat().st_mtime
        except FileNotFoundError:
            continue
        if now - mtime < _STALE_LOCK_AGE_SECS:
            continue
        try:
            lock.unlink()
            removed.append(name)
        except OSError:
            pass
    return removed


# Bound SSH connection hangs. ConnectTimeout caps the initial TCP/SSH
# handshake; ServerAliveInterval + ServerAliveCountMax detect a connection
# that goes silent mid-transfer. ~45s ceiling on a hung remote, vs. the
# previous behavior of hanging up to the full run_with_retry timeout (600s).
_GIT_SSH_COMMAND = (
    "ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
)


def _git_env() -> dict:
    """Env for git subprocesses. Forces C locale so error-message parsing is
    stable, disables interactive credential prompts, and bounds SSH hang time."""
    return {
        **os.environ,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": _GIT_SSH_COMMAND,
    }


def run_with_retry(
    cmd: list[str],
    *,
    description: str,
    attempts: int = 3,
    backoff: float = 2.0,
    timeout: "int | None" = None,
    on_retry: "Callable[[], None] | None" = None,
) -> tuple[bool, str]:
    """Run cmd with retry/backoff. Returns (ok, combined_output).

    If on_retry is provided, it is called before every attempt after the first.
    Useful for cleaning up partial state (e.g. a half-created clone destination)
    so subsequent attempts don't fail on artifacts of the prior failure.
    """
    if timeout is None:
        timeout = TIMEOUT
    delay = backoff
    output = ""
    for attempt in range(1, attempts + 1):
        if attempt > 1 and on_retry is not None:
            try:
                on_retry()
            except Exception as e:  # noqa: BLE001 — cleanup is best-effort
                log_warn(f"{description}: on_retry cleanup failed: {e!r}")
        try:
            result = subprocess.run(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                env=_git_env(),
            )
            output = result.stdout or ""
            rc = result.returncode
        except subprocess.TimeoutExpired as e:
            # e.stdout can come back as bytes even when text=True (Python subprocess
            # quirk when the timeout fires before the text decoder runs).
            captured = e.stdout or ""
            if isinstance(captured, bytes):
                captured = captured.decode("utf-8", errors="replace")
            output = captured + f"\n[timed out after {timeout}s]"
            # A timeout means "operation just takes longer than `timeout` seconds";
            # retrying won't help, only burns time. Surface the timeout error
            # immediately instead of wasting two more attempts.
            return False, output
        except FileNotFoundError as e:
            return False, f"command not found: {e}"
        if rc == 0:
            return True, output
        if attempt < attempts:
            log_warn(f"{description}: attempt {attempt} failed; retrying in {delay:.0f}s")
            time.sleep(delay)
            delay *= 2
    return False, output


def _git(repo: Path, *args: str) -> tuple[int, str]:
    r = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=_git_env(),
    )
    return r.returncode, (r.stdout or "")


def _has_remote_ref(repo: Path, branch: str) -> bool:
    rc, _ = _git(repo, "rev-parse", "--verify", f"refs/remotes/origin/{branch}")
    return rc == 0


def _has_any_ref(repo: Path) -> bool:
    rc, _ = _git(repo, "show-ref")
    return rc == 0


def _is_dirty(repo: Path) -> bool:
    rc, out = _git(repo, "status", "--porcelain")
    return rc == 0 and bool(out.strip())


def _head_sha(repo: Path) -> str:
    rc, out = _git(repo, "rev-parse", "HEAD")
    return out.strip() if rc == 0 else ""


def _current_branch(repo: Path) -> str:
    rc, out = _git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
    return out.strip() if rc == 0 else ""


def _count_commits_between(repo: Path, base: str, tip: str) -> int:
    rc, out = _git(repo, "rev-list", "--count", f"{base}..{tip}")
    if rc != 0:
        return 0
    try:
        return int(out.strip())
    except ValueError:
        return 0


def _tail(s: str, n: int = 20) -> str:
    lines = s.splitlines()
    return "\n".join(lines[-n:])


def _safe_under_root(dest: Path) -> bool:
    try:
        dest.resolve().relative_to(SYNC_ROOT.resolve())
        return True
    except ValueError:
        return False


def _rel(dest: Path) -> str:
    """Path relative to SYNC_ROOT, or the absolute path if outside."""
    try:
        return str(dest.relative_to(SYNC_ROOT))
    except ValueError:
        return str(dest)


# ---- Per-repo clone/update ----

def clone_or_update(
    *,
    ssh_url: str,
    dest: Path,
    branch: str,
    outcomes: OutcomeCollector,
    registry: "_WorkerRegistry | None" = None,
) -> None:
    rel = _rel(dest)
    key = threading.get_ident()
    op = "fetch" if (dest / ".git").is_dir() else "clone"
    if registry is not None:
        registry.start(key, rel, op)

    try:
        _clone_or_update_inner(
            ssh_url=ssh_url, dest=dest, branch=branch,
            outcomes=outcomes, registry=registry, rel=rel,
        )
    finally:
        if registry is not None:
            registry.finish(key)


def _clone_or_update_inner(
    *,
    ssh_url: str,
    dest: Path,
    branch: str,
    outcomes: OutcomeCollector,
    registry: "_WorkerRegistry | None",
    rel: str,
) -> None:
    key = threading.get_ident()

    def _set_phase(phase: str) -> None:
        if registry is not None:
            registry.set_phase(key, phase)

    if (dest / ".git").is_dir():
        _set_phase("fetching")
        # Remove old lock files left behind by killed git processes. Age-gated
        # so we don't clobber an active commit/fetch happening in another window.
        removed = _clean_stale_locks(dest)
        if removed:
            log_warn(f"{rel}: removed stale lock file(s): {', '.join(removed)}")

        old_sha = _head_sha(dest)

        # If the local clone has no refs yet, the remote was empty last time.
        # Re-fetching will fail again with empty output; don't spam retry warnings.
        was_empty = not _has_any_ref(dest)
        ok, out = run_with_retry(
            ["git", "-C", str(dest), "fetch", *_depth_args(), "--prune", "origin"],
            description=f"{rel} fetch",
            attempts=1 if was_empty else 3,
        )
        if not ok:
            # `git fetch` returns nonzero with empty output when the remote has no refs
            # at all (a freshly-created, never-pushed-to repo). Treat as in-sync.
            if not out.strip() and not _has_any_ref(dest):
                outcomes.add(Outcome(rel, Status.EMPTY_REMOTE, url=ssh_url))
                return
            # Remote has no usable HEAD — typically an empty repo whose API
            # metadata still claims a default branch. Same classification as
            # the clone path.
            if _NO_MATCHING_HEAD_RE.search(out):
                outcomes.add(Outcome(rel, Status.EMPTY_REMOTE, url=ssh_url))
                return
            outcomes.add(Outcome(rel, Status.ERROR, url=ssh_url, detail=_tail(out)))
            return

        # Fetch succeeded. Distinguish "remote totally empty" from
        # "remote has refs but not the one we expected."
        if not _has_remote_ref(dest, branch):
            if _has_any_ref(dest):
                outcomes.add(Outcome(
                    rel, Status.BRANCH_MISSING, url=ssh_url,
                    detail=f"remote has no '{branch}'",
                ))
            else:
                outcomes.add(Outcome(rel, Status.EMPTY_REMOTE, url=ssh_url))
            return

        if _is_dirty(dest):
            outcomes.add(Outcome(rel, Status.DIRTY, url=ssh_url))
            return

        cur_branch = _current_branch(dest)
        if cur_branch != branch:
            # User has checked out a different branch locally — fetch updated origin/*
            # but don't switch their HEAD. Treat as diverged for reporting purposes.
            ahead = _count_commits_between(dest, f"origin/{branch}", "HEAD") if cur_branch else 0
            outcomes.add(Outcome(
                rel, Status.DIVERGED, url=ssh_url,
                detail=f"local on '{cur_branch or 'detached HEAD'}', not '{branch}'",
                commits_ahead=ahead,
            ))
            return

        _set_phase("merging")
        ff_ok, _ff_out = run_with_retry(
            ["git", "-C", str(dest), "merge", "--ff-only", f"origin/{branch}"],
            description=f"{rel} ff",
            attempts=1,
        )
        if not ff_ok:
            ahead = _count_commits_between(dest, f"origin/{branch}", "HEAD")
            outcomes.add(Outcome(
                rel, Status.DIVERGED, url=ssh_url,
                detail=f"local '{branch}' has commits not on origin/{branch}",
                commits_ahead=ahead,
            ))
            return

        new_sha = _head_sha(dest)
        if new_sha == old_sha:
            outcomes.add(Outcome(rel, Status.UP_TO_DATE, url=ssh_url))
        else:
            n = _count_commits_between(dest, old_sha, new_sha)
            outcomes.add(Outcome(
                rel, Status.UPDATED, url=ssh_url,
                old_sha=old_sha[:7], new_sha=new_sha[:7], commits_ahead=n,
            ))
        return

    _set_phase("cloning")
    dest.parent.mkdir(parents=True, exist_ok=True)

    # If the clone fails partway through, it leaves dest half-populated. The
    # next attempt would then fail immediately with "destination already exists
    # and is not an empty directory", masking the real error. We clean up
    # between attempts — but only when dest didn't exist before our first
    # attempt (otherwise the leftover content might be user work).
    dest_existed_before_clone = dest.exists()

    def _cleanup_partial_clone() -> None:
        if dest_existed_before_clone:
            return  # don't touch anything that was already there
        if not _safe_under_root(dest):
            return
        if dest.exists():
            shutil.rmtree(dest)

    ok, out = run_with_retry(
        # --no-single-branch overrides --depth's implicit --single-branch so
        # every remote branch ref ends up in refs/remotes/origin/*. GUIs and
        # `git checkout` can then discover and switch to any branch a teammate
        # publishes, instead of being locked to the default branch forever.
        ["git", "clone", *_depth_args(), "--no-single-branch",
         "--branch", branch, ssh_url, str(dest)],
        description=f"{rel} clone",
        on_retry=_cleanup_partial_clone,
    )
    if ok:
        outcomes.add(Outcome(rel, Status.CLONED, url=ssh_url))
        return

    # Remote responded but has no usable HEAD — typically an empty repo whose
    # API metadata still claims a default branch. Not a real failure.
    if _NO_MATCHING_HEAD_RE.search(out):
        outcomes.add(Outcome(rel, Status.EMPTY_REMOTE, url=ssh_url))
        return

    if _BRANCH_MISSING_RE.search(out):
        if not _safe_under_root(dest):
            outcomes.add(Outcome(rel, Status.ERROR, url=ssh_url, detail="dest outside SYNC_ROOT"))
            return
        if dest.exists():
            shutil.rmtree(dest)
        ok2, out2 = run_with_retry(
            ["git", "clone", *_depth_args(), "--no-single-branch", ssh_url, str(dest)],
            description=f"{rel} clone (no branch)",
            on_retry=_cleanup_partial_clone,
        )
        if ok2:
            # Either the repo has a different default branch or it's empty.
            if _has_any_ref(dest):
                outcomes.add(Outcome(rel, Status.CLONED, url=ssh_url, detail="default branch differs from API"))
            else:
                outcomes.add(Outcome(rel, Status.EMPTY_REMOTE, url=ssh_url))
        elif _NO_MATCHING_HEAD_RE.search(out2):
            outcomes.add(Outcome(rel, Status.EMPTY_REMOTE, url=ssh_url))
        else:
            outcomes.add(Outcome(rel, Status.ERROR, url=ssh_url, detail=_tail(out2)))
        return

    outcomes.add(Outcome(rel, Status.ERROR, url=ssh_url, detail=_tail(out)))


def run_jobs(
    jobs: list[Job],
    outcomes: OutcomeCollector,
    *,
    description: str = "Sync",
) -> None:
    total = len(jobs)
    registry = _WorkerRegistry()
    display: "_LiveDisplay | None" = None
    if _TTY:
        display = _LiveDisplay(registry, outcomes, total, description)
        display.start()
    try:
        with ThreadPoolExecutor(max_workers=PARALLEL) as pool:
            future_to_job = {
                pool.submit(
                    clone_or_update,
                    ssh_url=j.ssh_url, dest=j.dest, branch=j.branch,
                    outcomes=outcomes, registry=registry,
                ): j
                for j in jobs
            }
            done = 0
            for fut in as_completed(future_to_job):
                j = future_to_job[fut]
                try:
                    fut.result()
                except Exception as e:  # noqa: BLE001 — capture for reporting, don't kill the pool
                    rel = _rel(j.dest)
                    log_error(f"{rel}: worker crashed: {e!r}")
                    outcomes.add(Outcome(
                        rel=rel, status=Status.ERROR, url=j.ssh_url,
                        detail=f"worker crashed: {e!r}",
                    ))
                done += 1
                # Non-TTY runs (cron, redirected output) get the periodic log
                # line so there's still visible progress; the live display
                # covers TTY runs.
                if not _TTY and (done % 25 == 0 or done == total):
                    log_info(f"progress: {done}/{total}")
    finally:
        if display is not None:
            display.stop()


# ---- Stale / non-git directory discovery ----

def discover_extras(
    platform_root: Path,
    expected_dests: set[Path],
) -> list[Outcome]:
    """Single-pass walk of platform_root. Returns outcomes for:
      - stale-on-disk: a git repo whose path isn't in expected_dests
      - non-git-dir: a directory tree under platform_root with no .git anywhere

    For non-git-dir, only the topmost offending directory is reported. Each
    on-disk directory is visited exactly once.
    """
    if not platform_root.is_dir():
        return []

    expected_resolved = {p.resolve() for p in expected_dests}

    def walk(dir_path: Path) -> tuple[bool, list[Outcome]]:
        """Returns (has_repo_in_subtree, outcomes_to_emit).

        If has_repo_in_subtree is False, the caller can choose to discard
        the returned outcomes and emit a single non-git-dir for the parent
        instead — that's how we get topmost-only reporting.
        """
        # A directory containing .git is a git repo. Don't descend.
        if (dir_path / ".git").is_dir():
            oc: list[Outcome] = []
            if dir_path.resolve() not in expected_resolved:
                oc.append(Outcome(_rel(dir_path), Status.STALE_ON_DISK))
            return True, oc

        try:
            children = sorted(
                p for p in dir_path.iterdir()
                if p.is_dir() and not p.is_symlink() and p.name != ".git"
            )
        except OSError:
            return False, []

        has_repo = False
        repo_branch_outcomes: list[Outcome] = []
        non_git_subtree_outcomes: list[Outcome] = []
        for child in children:
            child_has_repo, child_oc = walk(child)
            if child_has_repo:
                has_repo = True
                repo_branch_outcomes.extend(child_oc)
            else:
                non_git_subtree_outcomes.extend(child_oc)

        if has_repo:
            # We're a container. Emit outcomes from repo-containing branches
            # AND from any non-git sibling subtrees (each already collapsed to
            # its own topmost entry by the recursive call).
            return True, repo_branch_outcomes + non_git_subtree_outcomes
        # No repos anywhere in our subtree. Collapse to a single non-git-dir
        # for this directory, discarding the descendants' entries.
        return False, [Outcome(_rel(dir_path), Status.NON_GIT_DIR)]

    try:
        top_children = sorted(
            p for p in platform_root.iterdir()
            if p.is_dir() and not p.is_symlink() and p.name != ".git"
        )
    except OSError:
        return []

    results: list[Outcome] = []
    for child in top_children:
        _, child_oc = walk(child)
        results.extend(child_oc)
    return results


# ---- Run finalization ----

def finish_run(
    platform_root: Path,
    jobs: list[Job],
    skipped: list[Outcome],
    outcomes: OutcomeCollector,
) -> list[Outcome]:
    """Combine sync outcomes, skipped repos, and stale/non-git findings.
    Skipped repo destinations count as 'expected' so they aren't flagged as stale.
    """
    expected = {j.dest for j in jobs}
    for o in skipped:
        expected.add(SYNC_ROOT / o.rel)
    extras = discover_extras(platform_root, expected)
    return outcomes.items + skipped + extras


# ---- Status presentation ----

@dataclass(frozen=True)
class _StatusMeta:
    glyph: str
    color: str
    title: str  # Section header. Empty string = suppress from summary listing.
    legend: str  # Description in the legend. Always shown if non-empty.


_STATUS_META: dict[Status, _StatusMeta] = {
    Status.CLONED: _StatusMeta(
        "+", C_GRN, "Cloned",
        "freshly cloned from remote",
    ),
    Status.UPDATED: _StatusMeta(
        "↑", C_GRN, "Updated",
        "local branch fast-forwarded to new remote tip",
    ),
    Status.UP_TO_DATE: _StatusMeta(
        "=", C_DIM, "",
        "",
    ),
    Status.EMPTY_REMOTE: _StatusMeta(
        "∅", C_DIM, "",
        "",
    ),
    Status.DIRTY: _StatusMeta(
        "~", C_YEL, "Dirty — fetched but not merged",
        "working tree had uncommitted changes; fetched but not merged",
    ),
    Status.DIVERGED: _StatusMeta(
        "⤧", C_YEL, "Diverged — local has commits not on remote",
        "local has commits not on remote, or on a different branch; fetched only",
    ),
    Status.BRANCH_MISSING: _StatusMeta(
        "⚠", C_YEL, "Branch missing on remote",
        "remote is non-empty but doesn't have the API's default branch — likely renamed or deleted upstream",
    ),
    Status.STALE_ON_DISK: _StatusMeta(
        "?", C_MAG, "Stale on disk — not in remote listing",
        "repo exists locally but not in remote listing — may have been deleted or renamed remotely",
    ),
    Status.NON_GIT_DIR: _StatusMeta(
        "?", C_CYA, "Non-git directories under sync root",
        "directory under sync root with no .git anywhere — not managed by this script",
    ),
    Status.SKIPPED: _StatusMeta(
        "-", C_DIM, "Skipped — matched GIT_SYNC_SKIP",
        "matched a GIT_SYNC_SKIP pattern; left untouched",
    ),
    Status.ERROR: _StatusMeta(
        "x", C_RED, "Errors",
        "network, auth, or other failure (re-run to retry)",
    ),
}

# Order shown in the summary. Statuses with empty title are suppressed.
_SUMMARY_ORDER: list[Status] = [
    Status.CLONED,
    Status.UPDATED,
    Status.DIRTY,
    Status.DIVERGED,
    Status.BRANCH_MISSING,
    Status.STALE_ON_DISK,
    Status.NON_GIT_DIR,
    Status.SKIPPED,
    Status.ERROR,
]


def _format_outcome_line(o: Outcome) -> str:
    meta = _STATUS_META[o.status]
    line = f"  {meta.color}{meta.glyph}{C_OFF} {o.rel}"
    if o.status == Status.UPDATED and o.old_sha and o.new_sha:
        s = "s" if o.commits_ahead != 1 else ""
        line += f"  {C_DIM}{o.old_sha} → {o.new_sha}  ({o.commits_ahead} commit{s}){C_OFF}"
        return line

    if o.status == Status.DIVERGED:
        parts: list[str] = []
        if o.detail:
            parts.append(o.detail)
        if o.commits_ahead:
            s = "s" if o.commits_ahead != 1 else ""
            parts.append(f"{o.commits_ahead} local commit{s}")
        if parts:
            line += f"  {C_DIM}{'; '.join(parts)}{C_OFF}"
        return line

    if o.detail:
        line += f"  {C_DIM}{o.detail}{C_OFF}"
    return line


def print_outcome_summary(outcomes: list[Outcome]) -> bool:
    """Print the summary table. Returns True if there were error outcomes."""
    out = sys.stderr
    grouped: dict[Status, list[Outcome]] = {s: [] for s in Status}
    for o in outcomes:
        grouped[o.status].append(o)

    total = len(outcomes)

    print(file=out)
    print(f"{C_BLD}========== Sync summary =========={C_OFF}", file=out)
    print(file=out)

    any_printed = False
    for status in _SUMMARY_ORDER:
        items = grouped[status]
        if not items:
            continue
        meta = _STATUS_META[status]
        if not meta.title:
            continue  # suppressed from summary listing
        any_printed = True
        print(f"{C_BLD}{meta.title} ({len(items)}){C_OFF}", file=out)
        for o in sorted(items, key=lambda x: x.rel):
            print(_format_outcome_line(o), file=out)
        print(file=out)

    if not any_printed:
        print(f"  {C_GRN}Nothing to report — everything in sync.{C_OFF}", file=out)
        print(file=out)

    # Footnote about suppressed entries (statuses with empty title).
    suppressed_counts: list[str] = []
    for status in Status:
        if _STATUS_META[status].title or not grouped[status]:
            continue
        suppressed_counts.append(f"{len(grouped[status])} {status.value}")
    if suppressed_counts:
        print(f"{C_DIM}({' and '.join(suppressed_counts)} not listed — {total} total){C_OFF}", file=out)
        print(file=out)

    # Legend
    print(f"{C_BLD}Legend{C_OFF}", file=out)
    for status in _SUMMARY_ORDER:
        meta = _STATUS_META[status]
        if not meta.legend:
            continue
        print(f"  {meta.color}{meta.glyph}{C_OFF}  {C_BLD}{status.value:<14}{C_OFF} {meta.legend}", file=out)
    print(file=out)
    print(f"{C_BLD}=================================={C_OFF}", file=out)

    return bool(grouped[Status.ERROR])

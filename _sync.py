"""Shared sync helpers. Imported by the per-platform entry scripts."""
from __future__ import annotations

import atexit
import json
import math
import os
import random
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

# Set when the user hits Ctrl-C. Workers check this before each retry sleep
# and before spawning a new subprocess so the script stops generating new
# work promptly instead of riding out 14+ seconds of retry backoffs (during
# which it would otherwise re-download what SIGINT had just killed).
_stop_event = threading.Event()


def stop_requested() -> bool:
    return _stop_event.is_set()


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


# ---- Event emission (for sync-all.py to drive a unified live display) ----
#
# When a parent (sync-all.py) drives multiple platform syncs, it needs to
# render one combined live display showing every active worker across all
# platforms. To enable that, children emit JSON-line state events on stdout
# tagged with a marker prefix. The parent's pump distinguishes event lines
# from regular log output and updates its own state model.

_EVENTS_ENABLED = os.environ.get("GIT_SYNC_EVENTS") == "1"
EVENTS_PREFIX = "\x1eGSE "  # ASCII record-separator + literal "GSE "
_event_lock = threading.Lock()


def _emit_event(kind: str, **fields: object) -> None:
    if not _EVENTS_ENABLED:
        return
    line = EVENTS_PREFIX + json.dumps({"kind": kind, **fields}, separators=(",", ":"))
    with _event_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


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
    pct: "int | None" = None
    # Throttling for event emission — every set_phase call updates local
    # state but only sends an event up to the parent at most ~10x/sec.
    _last_event_at: float = 0.0
    _last_event_phase: str = ""


class _WorkerRegistry:
    """Thread-safe map of worker key -> _WorkerState."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._states: dict[int, _WorkerState] = {}

    def start(self, key: int, rel: str, op: str) -> None:
        with self._lock:
            self._states[key] = _WorkerState(rel=rel, op=op, started_at=time.monotonic())
        _emit_event("worker_start", rel=rel, op=op)

    def set_phase(self, key: int, phase: str, pct: "int | None" = None) -> None:
        emit = False
        rel = ""
        with self._lock:
            st = self._states.get(key)
            if st is None:
                return
            st.phase = phase
            st.pct = pct
            rel = st.rel
            if _EVENTS_ENABLED:
                now = time.monotonic()
                # Always emit on phase change or completion (pct=100); otherwise
                # throttle to ~10Hz to keep the parent's pump from drowning in
                # 1%-step updates from many workers.
                if (phase != st._last_event_phase
                        or pct in (None, 100)
                        or (now - st._last_event_at) >= 0.1):
                    emit = True
                    st._last_event_at = now
                    st._last_event_phase = phase
        if emit:
            _emit_event("worker_phase", rel=rel, phase=phase, pct=pct)

    def finish(self, key: int) -> None:
        rel = ""
        with self._lock:
            st = self._states.pop(key, None)
            if st is not None:
                rel = st.rel
        if rel:
            _emit_event("worker_finish", rel=rel)

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


_prev_sigint_handler: "object | None" = None


def _sigint_handler(signum, frame) -> None:  # noqa: ANN001 — signal handler signature
    # First Ctrl-C: set the stop event so workers stop spawning new git
    # subprocesses, clean up the terminal, and return. The pool drains on its
    # own as workers see the flag and bail. A second Ctrl-C escalates to the
    # default handler (immediate terminate) — useful when a worker is stuck
    # in a syscall and won't notice the flag.
    if _stop_event.is_set():
        # Second Ctrl-C: hand off to the default handler so the process dies.
        _cleanup_terminal()
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGINT)
        return
    _stop_event.set()
    _cleanup_terminal()
    try:
        sys.stderr.write(
            "\n[stopping — workers will finish current step, "
            "Ctrl-C again to force exit]\n"
        )
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — write inside a signal handler is best-effort
        pass


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
    UPDATED_DIRTY = "updated-dirty"
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


def _emit_outcome_event(o: Outcome) -> None:
    """Send a full Outcome up to the parent (sync-all.py) so the parent
    can rebuild the same object and render one unified summary covering
    every platform, instead of three separate per-platform summaries."""
    _emit_event(
        "outcome",
        rel=o.rel,
        status=o.status.value,
        url=o.url,
        detail=o.detail,
        old_sha=o.old_sha,
        new_sha=o.new_sha,
        commits_ahead=o.commits_ahead,
    )


class OutcomeCollector:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._items: list[Outcome] = []

    def add(self, o: Outcome) -> None:
        with self._lock:
            self._items.append(o)
        _emit_outcome_event(o)

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


# Parse git's --progress output. Lines look like:
#   "Receiving objects:  45% (40460/89912), 1.42 GiB | 6.04 MiB/s"
#   "remote: Compressing objects:  43% (33513/78006)"
# Phases come in this rough order: enumerating -> counting -> compressing
# -> receiving -> resolving -> updating. Receiving is usually the dominant
# wall-clock phase for large clones.
_GIT_PROGRESS_RE = re.compile(
    r"^(?:remote:\s+)?"
    r"(Enumerating|Counting|Compressing|Receiving|Resolving|Updating)"
    r"[^:]*:\s+(\d+)%"
)
_PHASE_DISPLAY = {
    "Enumerating": "enumerating",
    "Counting": "counting",
    "Compressing": "compressing",
    "Receiving": "receiving",
    "Resolving": "resolving",
    "Updating": "updating",
}


def _parse_git_progress(line: str) -> "tuple[str, int] | None":
    m = _GIT_PROGRESS_RE.match(line)
    if not m:
        return None
    return _PHASE_DISPLAY[m.group(1)], int(m.group(2))


# Bound SSH connection hangs. ConnectTimeout caps the initial TCP/SSH
# handshake; ServerAliveInterval + ServerAliveCountMax detect a connection
# that goes silent mid-transfer. ~45s ceiling on a hung remote, vs. the
# previous behavior of hanging up to the full run_with_retry timeout (600s).
_SSH_TIMEOUT_OPTS = (
    "-o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
)

# SSH connection multiplexing — every git op to the same host rides one
# authenticated TCP/SSH connection instead of running its own handshake.
# Lets PARALLEL go much higher without tripping sshd's MaxStartups guard
# (default 10:30:60 means probabilistic drops once concurrent unauthenticated
# handshakes pass 10). Each child process gets its own socket directory so
# parallel sync-platform.py runs don't fight over the same control sockets.
_SSH_MUX_ENABLED = os.environ.get("GIT_SYNC_NO_SSH_MUX") != "1"
# Hardcoded /tmp instead of tempfile.gettempdir() — on macOS the per-user
# temp dir resolves to /var/folders/.../T/ (~50 chars), and combined with
# the 40-char %C hash and our dir prefix it can exceed the 104-char UNIX
# socket path limit. /tmp is short and universally available.
_CM_DIR = Path("/tmp") / f"git-sync-cm-{os.getuid()}-{os.getpid()}"
_CM_HOSTS: "set[tuple[str, int]]" = set()  # (host, shard)
_CM_HOSTS_LOCK = threading.Lock()

# Pick enough ControlMaster shards per host that we stay well under
# sshd's MaxSessions=10 default at peak load. ceil(PARALLEL/8) targets
# ~8 channels per master when all workers happen to be hitting one host
# — leaves 2 slots of headroom for the inevitable statistical bursts
# that single-master setups can't absorb.
MASTERS_PER_HOST = max(1, math.ceil(PARALLEL / 8)) if _SSH_MUX_ENABLED else 1

# Each worker thread is assigned a shard for the duration of its
# clone_or_update call so retries hit the same master (warm) and so
# every git subprocess from the same thread routes through the same
# socket without plumbing shard through every function signature.
_ssh_shard_local = threading.local()


def _set_ssh_shard(shard: int) -> None:
    _ssh_shard_local.shard = shard


def _clear_ssh_shard() -> None:
    _ssh_shard_local.shard = None


def _shard_for(rel: str) -> int:
    """Stable hash of the repo path → shard index. Stable so retries land
    on the master that's already authenticated."""
    return (hash(rel) & 0x7fffffff) % MASTERS_PER_HOST


def _control_path(shard: "int | None") -> str:
    # When MASTERS_PER_HOST==1 we collapse the s0- prefix so direct sync-*.py
    # invocations and sync-all runs share a socket dir layout that's easy to
    # eyeball. With more than one shard we always namespace by shard.
    if MASTERS_PER_HOST <= 1:
        return f"{_CM_DIR}/%C"
    s = shard if shard is not None else 0
    return f"{_CM_DIR}/s{s}-%C"


def _ssh_command() -> str:
    parts = ["ssh", _SSH_TIMEOUT_OPTS]
    if _SSH_MUX_ENABLED:
        shard = getattr(_ssh_shard_local, "shard", None)
        parts.append(
            f"-o ControlMaster=auto -o ControlPath={_control_path(shard)} "
            f"-o ControlPersist=120s"
        )
    return " ".join(parts)


def _git_env() -> dict:
    """Env for git subprocesses. Forces C locale so error-message parsing is
    stable, disables interactive credential prompts, and bounds SSH hang time."""
    return {
        **os.environ,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": _ssh_command(),
    }


_SSH_URL_RE = re.compile(r"^(?:([^@:/]+)@)?([^:/]+):")


def _unique_ssh_hosts(jobs: "list[Job]") -> "set[str]":
    """Pull the set of user@host pairs out of a job list's SSH URLs.
    Used to pre-warm a ControlMaster per host before the worker pool fires."""
    hosts: set[str] = set()
    for j in jobs:
        m = _SSH_URL_RE.match(j.ssh_url)
        if m:
            user, host = (m.group(1) or "git"), m.group(2)
            hosts.add(f"{user}@{host}")
    return hosts


def prewarm_ssh_masters(hosts: "set[str]") -> None:
    """Open MASTERS_PER_HOST ControlMaster connections for each host so
    the first burst of parallel git ops all ride existing masters instead
    of racing to create them (defeats the purpose) or stacking on a single
    master past sshd's MaxSessions=10 limit (fixes the bug)."""
    if not _SSH_MUX_ENABLED or not hosts:
        return
    try:
        _CM_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    except OSError as e:
        log_warn(f"could not create SSH control dir {_CM_DIR}: {e}")
        return
    # Pre-warm in parallel; serially this would be ~1s per (host, shard)
    # and at PARALLEL=64 (8 masters) per platform that's a noticeable
    # startup cost in front of the actual work.
    from concurrent.futures import ThreadPoolExecutor

    def _warm_one(host: str, shard: int) -> None:
        with _CM_HOSTS_LOCK:
            _CM_HOSTS.add((host, shard))
        try:
            subprocess.run(
                ["ssh", "-o", "BatchMode=yes",
                 "-o", "ControlMaster=auto",
                 "-o", f"ControlPath={_control_path(shard)}",
                 "-o", "ControlPersist=120s",
                 "-o", "ConnectTimeout=15",
                 host, "true"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
        except (subprocess.TimeoutExpired, OSError):
            # Pre-warming is best-effort; workers will still try directly.
            pass

    pairs = [(h, s) for h in hosts for s in range(MASTERS_PER_HOST)]
    if not pairs:
        return
    with ThreadPoolExecutor(max_workers=min(len(pairs), 16)) as pool:
        list(pool.map(lambda hs: _warm_one(*hs), pairs))


def _cleanup_ssh_masters() -> None:
    """Close every ControlMaster we opened and remove the socket dir.
    Without this the master ssh processes linger until ControlPersist
    (120s) expires, which holds idle TCP connections open and leaves a
    stray /tmp dir behind."""
    if not _SSH_MUX_ENABLED:
        return
    with _CM_HOSTS_LOCK:
        masters = list(_CM_HOSTS)
    for host, shard in masters:
        try:
            subprocess.run(
                ["ssh", "-O", "exit",
                 "-o", f"ControlPath={_control_path(shard)}",
                 host],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        except (subprocess.TimeoutExpired, OSError):
            pass
    try:
        shutil.rmtree(_CM_DIR, ignore_errors=True)
    except OSError:
        pass


atexit.register(_cleanup_ssh_masters)


def run_with_retry(
    cmd: list[str],
    *,
    description: str,
    attempts: int = 3,
    backoff: float = 2.0,
    timeout: "int | None" = None,
    on_retry: "Callable[[], None] | None" = None,
    on_line: "Callable[[str], None] | None" = None,
) -> tuple[bool, str]:
    """Run cmd with retry/backoff. Returns (ok, combined_output).

    If on_retry is provided, it is called before every attempt after the first.
    Useful for cleaning up partial state (e.g. a half-created clone destination)
    so subsequent attempts don't fail on artifacts of the prior failure.

    If on_line is provided, it is called for each output line as it's
    produced. Lines are split on either '\\n' or '\\r' — git's --progress
    output updates the same line in-place via carriage return, and we need
    to surface those updates to the live display, not wait for the next '\\n'.
    """
    if timeout is None:
        timeout = TIMEOUT
    delay = backoff
    output = ""
    for attempt in range(1, attempts + 1):
        if _stop_event.is_set():
            return False, output + "\n[aborted]"
        if attempt > 1 and on_retry is not None:
            try:
                on_retry()
            except Exception as e:  # noqa: BLE001 — cleanup is best-effort
                log_warn(f"{description}: on_retry cleanup failed: {e!r}")
        try:
            ok, output, timed_out = _run_streaming(cmd, timeout=timeout, on_line=on_line)
        except FileNotFoundError as e:
            return False, f"command not found: {e}"
        if timed_out:
            # A timeout means "operation just takes longer than `timeout` seconds";
            # retrying won't help, only burns time. Surface the timeout error
            # immediately instead of wasting two more attempts.
            return False, output
        if ok:
            return True, output
        if attempt < attempts:
            # Suppress per-attempt warnings when running under sync-all: the
            # parent's live block already shows the worker is still alive,
            # and three platforms x 16 workers x N retries = a flood of
            # near-identical lines that scroll the useful logs off-screen.
            if not _EVENTS_ENABLED:
                log_warn(f"{description}: attempt {attempt} failed; retrying in {delay:.0f}s")
            # Jitter ±50% on the backoff. Many transient failures (sshd
            # MaxStartups / MaxSessions, server throttling, transient packet
            # loss) hit several workers at once, and a fixed 2/4/8s schedule
            # makes all the failed workers retry in lockstep — recreating
            # the original condition. Spreading the retry window breaks
            # the herd.
            sleep_for = delay * random.uniform(0.5, 1.5)
            # Interruptible sleep — if Ctrl-C arrives mid-backoff we want to
            # bail out instead of sleeping and spawning a fresh git
            # subprocess to redownload from scratch.
            if _stop_event.wait(sleep_for):
                return False, output + "\n[aborted]"
            delay *= 2
    return False, output


def _run_streaming(
    cmd: list[str],
    *,
    timeout: int,
    on_line: "Callable[[str], None] | None",
) -> tuple[bool, str, bool]:
    """Run cmd, streaming output. Returns (ok, captured_output, timed_out).

    Splits on '\\n' or '\\r' so git's --progress carriage-return updates
    surface immediately. Enforces timeout manually since Popen has no
    timeout= parameter (subprocess.run's `timeout` kwarg uses a watcher
    thread we'd otherwise reimplement).
    """
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,  # unbuffered — \r-updated progress lines arrive promptly
        env=_git_env(),
    )
    deadline = time.monotonic() + timeout
    captured: list[str] = []
    buf = bytearray()
    timed_out = False
    assert proc.stdout is not None
    fd = proc.stdout.fileno()
    aborted = False
    try:
        while True:
            if _stop_event.is_set():
                aborted = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            # select() with the remaining-time budget — wakes immediately on
            # output, sleeps at most until the deadline. Avoids tight polling.
            import select
            rlist, _, _ = select.select([fd], [], [], min(0.5, remaining))
            if not rlist:
                if proc.poll() is not None:
                    # Process exited; drain any final bytes below.
                    break
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                break  # EOF — child closed stdout
            buf.extend(chunk)
            _drain_lines(buf, captured, on_line)
    finally:
        if timed_out or aborted:
            try:
                proc.kill()
            except OSError:
                pass
        # Drain whatever else is in the pipe (process may have closed it
        # after our last read), then wait. Bounded read so a misbehaving
        # child can't keep us here forever.
        try:
            tail = proc.stdout.read()
            if tail:
                buf.extend(tail)
        except OSError:
            pass
        _drain_lines(buf, captured, on_line)
        if buf:
            # Trailing partial line with no terminator.
            line = buf.decode("utf-8", errors="replace")
            captured.append(line)
            if on_line is not None:
                try:
                    on_line(line)
                except Exception:  # noqa: BLE001 — callback errors must not kill the run
                    pass
            buf.clear()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except OSError:
                pass
            proc.wait()

    output = "\n".join(captured)
    if timed_out:
        output = output + f"\n[timed out after {timeout}s]"
        return False, output, True
    if aborted:
        return False, output + "\n[aborted]", False
    return proc.returncode == 0, output, False


def _drain_lines(
    buf: bytearray,
    captured: list[str],
    on_line: "Callable[[str], None] | None",
) -> None:
    """Pull complete lines out of buf, splitting on '\\n' or '\\r'."""
    while True:
        # Find earliest line terminator.
        nl = buf.find(b"\n")
        cr = buf.find(b"\r")
        candidates = [x for x in (nl, cr) if x >= 0]
        if not candidates:
            return
        idx = min(candidates)
        raw = bytes(buf[:idx])
        del buf[: idx + 1]
        if not raw:
            continue
        line = raw.decode("utf-8", errors="replace")
        captured.append(line)
        if on_line is not None:
            try:
                on_line(line)
            except Exception:  # noqa: BLE001 — callback errors must not kill the run
                pass


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
    # Bail before doing any work if the user has already pressed Ctrl-C —
    # ThreadPoolExecutor has no way to cancel queued futures, so each worker
    # has to gate itself. Without this, every queued job would spawn its
    # own git subprocess after the kill and continue downloading.
    if _stop_event.is_set():
        outcomes.add(Outcome(rel, Status.ERROR, url=ssh_url, detail="aborted"))
        return
    key = threading.get_ident()
    op = "fetch" if (dest / ".git").is_dir() else "clone"
    if registry is not None:
        registry.start(key, rel, op)

    # Pin this thread to one SSH master shard for the life of the call.
    # Every git subprocess we spawn (fetch / merge / clone / fallback clone)
    # picks up the same shard via _git_env → _ssh_command → thread-local.
    _set_ssh_shard(_shard_for(rel))
    try:
        _clone_or_update_inner(
            ssh_url=ssh_url, dest=dest, branch=branch,
            outcomes=outcomes, registry=registry, rel=rel,
        )
    finally:
        _clear_ssh_shard()
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

    def _on_line(line: str) -> None:
        if registry is None:
            return
        parsed = _parse_git_progress(line)
        if parsed is None:
            return
        phase, pct = parsed
        registry.set_phase(key, phase, pct)

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
            ["git", "-C", str(dest), "fetch", "--progress",
             *_depth_args(), "--prune", "origin"],
            description=f"{rel} fetch",
            attempts=1 if was_empty else 3,
            on_line=_on_line,
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

        was_dirty = _is_dirty(dest)

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
        # Let git decide whether the FF is safe. With uncommitted changes on
        # non-colliding paths git happily fast-forwards and preserves them; on
        # colliding paths it refuses with "would be overwritten by merge",
        # which we classify as DIRTY below.
        ff_ok, ff_out = run_with_retry(
            ["git", "-C", str(dest), "merge", "--ff-only", f"origin/{branch}"],
            description=f"{rel} ff",
            attempts=1,
        )
        if not ff_ok:
            if was_dirty:
                outcomes.add(Outcome(
                    rel, Status.DIRTY, url=ssh_url,
                    detail="uncommitted changes blocked fast-forward",
                ))
            else:
                ahead = _count_commits_between(dest, f"origin/{branch}", "HEAD")
                outcomes.add(Outcome(
                    rel, Status.DIVERGED, url=ssh_url,
                    detail=f"local '{branch}' has commits not on origin/{branch}",
                    commits_ahead=ahead,
                ))
            return

        new_sha = _head_sha(dest)
        if new_sha == old_sha:
            if was_dirty:
                outcomes.add(Outcome(rel, Status.DIRTY, url=ssh_url, detail="up-to-date with uncommitted changes"))
            else:
                outcomes.add(Outcome(rel, Status.UP_TO_DATE, url=ssh_url))
        else:
            n = _count_commits_between(dest, old_sha, new_sha)
            status = Status.UPDATED_DIRTY if was_dirty else Status.UPDATED
            outcomes.add(Outcome(
                rel, status, url=ssh_url,
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
        ["git", "clone", "--progress", *_depth_args(), "--no-single-branch",
         "--branch", branch, ssh_url, str(dest)],
        description=f"{rel} clone",
        on_retry=_cleanup_partial_clone,
        on_line=_on_line,
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
            ["git", "clone", "--progress", *_depth_args(),
             "--no-single-branch", ssh_url, str(dest)],
            description=f"{rel} clone (no branch)",
            on_retry=_cleanup_partial_clone,
            on_line=_on_line,
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
    _emit_event("session_start", description=description, total=total)
    prewarm_ssh_masters(_unique_ssh_hosts(jobs))
    registry = _WorkerRegistry()
    display: "_LiveDisplay | None" = None
    if _TTY:
        display = _LiveDisplay(registry, outcomes, total, description)
        display.start()

    # Install our SIGINT handler so Ctrl-C sets _stop_event (workers see it
    # and bail) instead of raising KeyboardInterrupt while workers continue
    # spawning fresh git subprocesses. Saved + restored around this run so
    # importing _sync from a notebook/REPL doesn't permanently capture SIGINT.
    global _prev_sigint_handler
    _prev_sigint_handler = signal.getsignal(signal.SIGINT)
    try:
        signal.signal(signal.SIGINT, _sigint_handler)
    except ValueError:
        # signal.signal only works in the main thread.
        _prev_sigint_handler = None
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
                # covers TTY runs. Suppress when events are enabled — the
                # parent (sync-all.py) renders its own live block.
                if (not _TTY and not _EVENTS_ENABLED
                        and (done % 25 == 0 or done == total)):
                    log_info(f"progress: {done}/{total}")
    finally:
        if display is not None:
            display.stop()
        _emit_event("session_end", description=description)
        if _prev_sigint_handler is not None:
            try:
                signal.signal(signal.SIGINT, _prev_sigint_handler)
            except (ValueError, TypeError):
                pass


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
    *,
    discovery_complete: bool = True,
) -> list[Outcome]:
    """Combine sync outcomes, skipped repos, and stale/non-git findings.
    Skipped repo destinations count as 'expected' so they aren't flagged as
    stale.

    discovery_complete=False means the remote listing wasn't fully retrieved
    (e.g. transient API errors during pagination). In that case stale-on-disk
    detection is wrong by construction — every repo we failed to enumerate
    would be flagged as 'deleted upstream' — so we skip the on-disk scan
    entirely and warn loudly. The user should re-run after fixing the
    network issue.
    """
    expected = {j.dest for j in jobs}
    for o in skipped:
        expected.add(SYNC_ROOT / o.rel)
    if discovery_complete:
        extras = discover_extras(platform_root, expected)
    else:
        extras = []
        log_warn(
            "Skipping stale-on-disk scan: remote discovery had errors "
            "(see above). Re-run once the issue is resolved to get an "
            "accurate listing."
        )
    # Skipped + extras come from the platform script / disk scan, not through
    # OutcomeCollector, so they haven't been emitted yet. Send them upstream
    # so the parent's unified summary sees the full picture.
    if _EVENTS_ENABLED:
        for o in skipped:
            _emit_outcome_event(o)
        for o in extras:
            _emit_outcome_event(o)
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
    Status.UPDATED_DIRTY: _StatusMeta(
        "↑", C_YEL, "Updated (over uncommitted changes)",
        "fast-forwarded to new remote tip; uncommitted changes on non-colliding paths were preserved",
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
    Status.UPDATED_DIRTY,
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
    if o.status in (Status.UPDATED, Status.UPDATED_DIRTY) and o.old_sha and o.new_sha:
        s = "s" if o.commits_ahead != 1 else ""
        suffix = "  [dirty]" if o.status == Status.UPDATED_DIRTY else ""
        line += f"  {C_DIM}{o.old_sha} → {o.new_sha}  ({o.commits_ahead} commit{s}){suffix}{C_OFF}"
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
    """Print the summary table. Returns True if there were error outcomes.

    When events are enabled, returns the had_errors signal without printing
    anything — sync-all.py renders one unified summary at the very end
    instead of three separate per-platform summaries.
    """
    grouped: dict[Status, list[Outcome]] = {s: [] for s in Status}
    for o in outcomes:
        grouped[o.status].append(o)
    had_errors = bool(grouped[Status.ERROR])

    if _EVENTS_ENABLED:
        return had_errors

    out = sys.stderr
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
        # SKIPPED is the user's own GIT_SYNC_SKIP list — they configured
        # it, they already know what's in it. Listing every match buries
        # the actually-actionable sections (Dirty, Diverged, Errors).
        if status == Status.SKIPPED:
            print(file=out)
            continue
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

    return had_errors

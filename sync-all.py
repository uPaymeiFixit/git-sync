#!/usr/bin/env python3
"""Run every configured platform sync concurrently with a unified live display.

Children (sync-{platform}.py) emit JSON-line state events on stdout via the
event protocol in _sync.py. This script reads those events from all three
children in parallel and renders a single live block showing every active
worker across every platform. Non-event lines from the children's stderr
are line-prefixed with the platform name and scrolled above the block.

Falls back gracefully in non-TTY environments (cron, piped output): no live
display, just prefixed log lines, including the periodic 'progress: N/M'
each child still emits on its own stderr.
"""
from __future__ import annotations

import atexit
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from _sync import (  # noqa: E402
    EVENTS_PREFIX, EXIT_SKIPPED,
    C_BLD, C_CYA, C_DIM, C_GRN, C_OFF, C_RED, C_YEL,
    Outcome, Status, print_outcome_summary,
)

PLATFORMS = [
    ("gitlab",    HERE / "sync-gitlab.py"),
    ("bitbucket", HERE / "sync-bitbucket.py"),
    ("github",    HERE / "sync-github.py"),
]

_TTY = sys.stderr.isatty()
_MAX_WORKERS_PER_PLATFORM = 16  # cap visible worker rows at 16/platform — 64-deep pools blow out terminal height


# ---- Parent-side state model ----

@dataclass
class _WorkerView:
    rel: str
    op: str
    started_at: float
    phase: str = "starting"
    pct: "int | None" = None


@dataclass
class _PlatformState:
    name: str
    proc_started_at: float
    description: str = ""
    total: int = 0
    workers: dict[str, _WorkerView] = field(default_factory=dict)
    counts: dict[str, int] = field(default_factory=dict)
    outcomes: list[Outcome] = field(default_factory=list)
    session_started: bool = False
    session_ended: bool = False
    exited: bool = False
    exit_code: "int | None" = None

    @property
    def done(self) -> int:
        return sum(self.counts.values())


# ---- Live display (parent) ----

_log_lock = threading.Lock()
_display_lines = 0


_active_display: "_ParentDisplay | None" = None


def _erase_display_locked() -> None:
    global _display_lines
    if _display_lines > 0 and _TTY:
        sys.stderr.write(f"\033[{_display_lines}A\033[J")
        _display_lines = 0


def _write_log_line(line: str) -> None:
    """Print a log line above the live block.

    Erase block → write line → immediately redraw block, all under one lock
    and one flush. Without the synchronous redraw the next ~250ms tick would
    leave the screen blank where the block used to be, producing the flicker
    the user sees when many log lines arrive in bursts.
    """
    with _log_lock:
        _erase_display_locked()
        sys.stderr.write(line)
        if not line.endswith("\n"):
            sys.stderr.write("\n")
        if _active_display is not None:
            _active_display._redraw_locked()
        sys.stderr.flush()


def _hide_cursor() -> None:
    if _TTY:
        sys.stderr.write("\033[?25l")
        sys.stderr.flush()


def _show_cursor() -> None:
    if _TTY:
        sys.stderr.write("\033[?25h")
        sys.stderr.flush()


def _cleanup_terminal() -> None:
    with _log_lock:
        _erase_display_locked()
    _show_cursor()


atexit.register(_cleanup_terminal)


def _format_elapsed(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}"


def _exit_badge(rc: "int | None") -> str:
    """Human-friendly status for an exited platform: done / skipped / failed.
    Raw exit codes are opaque in a live display; named badges are the win."""
    if rc == 0:
        return f"{C_GRN}done{C_OFF}"
    if rc == EXIT_SKIPPED:
        return f"{C_DIM}skipped{C_OFF}"
    return f"{C_RED}failed (exit {rc}){C_OFF}"


class _ParentDisplay:
    RENDER_INTERVAL = 0.25

    def __init__(self, platforms: "dict[str, _PlatformState]") -> None:
        self._platforms = platforms
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
        with _log_lock:
            _erase_display_locked()
            self._redraw_locked()
            sys.stderr.flush()

    def _redraw_locked(self) -> None:
        """Write the block at the cursor. Caller holds _log_lock and has
        already erased any previous block above the cursor."""
        if not _TTY:
            return
        global _display_lines
        lines = self._format_lines()
        if not lines:
            return
        sys.stderr.write("\n".join(lines))
        sys.stderr.write("\n")
        _display_lines = len(lines)

    def _format_lines(self) -> list[str]:
        width = shutil.get_terminal_size((100, 24)).columns
        elapsed = _format_elapsed(time.monotonic() - self._started_at)
        active = sum(1 for p in self._platforms.values() if not p.exited)
        header = (
            f"{C_DIM}[{elapsed}]{C_OFF} {C_BLD}git-sync{C_OFF} — "
            f"{active} platform(s) running"
        )
        out = [header]
        for name, p in self._platforms.items():
            out.extend(self._format_platform(name, p, width))
        return out

    def _format_platform(
        self, name: str, p: _PlatformState, width: int,
    ) -> list[str]:
        lines: list[str] = []

        # Header per platform — show progress fraction once we know the total.
        if p.exited:
            status_str = _exit_badge(p.exit_code)
        elif not p.session_started:
            status_str = f"{C_DIM}discovering…{C_OFF}"
        elif p.total == 0:
            status_str = f"{C_DIM}no repos{C_OFF}"
        else:
            status_str = f"{p.done} / {p.total}"
        label = p.description or name
        lines.append(f"  {C_CYA}▸{C_OFF} {C_BLD}{label}{C_OFF}  {status_str}")

        if p.counts:
            parts = []
            if p.counts.get("cloned"):
                parts.append(f"{C_GRN}cloned: {p.counts['cloned']}{C_OFF}")
            if p.counts.get("updated"):
                parts.append(f"{C_GRN}updated: {p.counts['updated']}{C_OFF}")
            if p.counts.get("up-to-date"):
                parts.append(f"{C_DIM}up-to-date: {p.counts['up-to-date']}{C_OFF}")
            if p.counts.get("error"):
                parts.append(f"{C_RED}errors: {p.counts['error']}{C_OFF}")
            if p.counts.get("skipped"):
                parts.append(f"{C_DIM}skipped: {p.counts['skipped']}{C_OFF}")
            if parts:
                lines.append("      " + "  ".join(parts))

        workers = sorted(p.workers.values(), key=lambda w: w.started_at)
        for w in workers[:_MAX_WORKERS_PER_PLATFORM]:
            lines.append(self._format_worker(w, width))
        hidden = len(workers) - _MAX_WORKERS_PER_PLATFORM
        if hidden > 0:
            lines.append(f"      {C_DIM}…(+{hidden} more){C_OFF}")
        return lines

    def _format_worker(self, w: _WorkerView, width: int) -> str:
        elapsed = _format_elapsed(time.monotonic() - w.started_at)
        if w.pct is not None:
            phase_str = f"{w.phase} {w.pct}%"
        else:
            phase_str = w.phase
        prefix = f"      • [{elapsed}] "
        suffix = f"  {phase_str}"
        budget = max(20, width - len(prefix) - len(suffix) - 1)
        rel = w.rel
        if len(rel) > budget:
            rel = rel[: budget - 1] + "…"
        return f"{prefix}{rel}{C_DIM}{suffix}{C_OFF}"


def _print_per_platform_status(platforms: "dict[str, _PlatformState]") -> None:
    """Print a compact per-platform header above the unified summary so the
    user can tell at a glance which platforms ran, were skipped, or failed
    before they even started syncing."""
    out = sys.stderr
    print(file=out)
    print(f"{C_BLD}Per-platform results{C_OFF}", file=out)
    name_width = max(len(n) for n in platforms) if platforms else 0
    for name, p in platforms.items():
        desc = p.description or name
        elapsed = _format_elapsed(time.monotonic() - p.proc_started_at)
        badge = _exit_badge(p.exit_code)
        print(f"  {desc:<{name_width + 16}}  {badge}  {C_DIM}{elapsed}{C_OFF}", file=out)
    print(file=out)


# ---- Event + log pump ----

def _handle_event(name: str, platforms: "dict[str, _PlatformState]", payload: dict) -> None:
    p = platforms[name]
    kind = payload.get("kind", "")
    if kind == "session_start":
        p.description = payload.get("description", "")
        p.total = int(payload.get("total", 0))
        p.session_started = True
    elif kind == "session_end":
        p.session_ended = True
    elif kind == "worker_start":
        rel = payload.get("rel", "")
        if rel:
            p.workers[rel] = _WorkerView(
                rel=rel,
                op=payload.get("op", ""),
                started_at=time.monotonic(),
            )
    elif kind == "worker_phase":
        rel = payload.get("rel", "")
        w = p.workers.get(rel)
        if w is not None:
            w.phase = payload.get("phase", w.phase)
            w.pct = payload.get("pct", w.pct)
    elif kind == "worker_finish":
        p.workers.pop(payload.get("rel", ""), None)
    elif kind == "outcome":
        status_str = payload.get("status", "")
        if not status_str:
            return
        p.counts[status_str] = p.counts.get(status_str, 0) + 1
        try:
            status = Status(status_str)
        except ValueError:
            return  # unknown status — skip rather than crash on a future enum value
        p.outcomes.append(Outcome(
            rel=payload.get("rel", ""),
            status=status,
            url=payload.get("url", ""),
            detail=payload.get("detail", ""),
            old_sha=payload.get("old_sha", ""),
            new_sha=payload.get("new_sha", ""),
            commits_ahead=int(payload.get("commits_ahead", 0) or 0),
        ))


def _pump_child(
    name: str,
    proc: subprocess.Popen,
    platforms: "dict[str, _PlatformState]",
) -> None:
    stream = proc.stdout
    assert stream is not None
    for line in iter(stream.readline, ""):
        if line.startswith(EVENTS_PREFIX):
            raw = line[len(EVENTS_PREFIX):].rstrip("\n")
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                continue
            _handle_event(name, platforms, payload)
        else:
            # Regular log/output line from the child — prefix it with the
            # platform name so the user can attribute each line.
            _write_log_line(f"[{name}] {line}")
    # stdout closed — child has exited (or is about to). Mark the platform
    # exited from here so the live display flips from "discovering…" the
    # moment a fast-skip child dies, instead of waiting until the main
    # thread's sequential .wait() loop reaches it.
    rc = proc.wait()
    platforms[name].exited = True
    platforms[name].exit_code = rc


# ---- Signal handling ----
#
# Two-stage Ctrl-C: the terminal sends SIGINT to the whole foreground
# process group, so every child also receives it directly. Each child's
# _sync.py SIGINT handler sets a stop flag that makes its workers stop
# spawning new git subprocesses and drain quickly. The parent's job is to
# (a) keep the live block tidy on the way out and (b) escalate to SIGTERM
# if a stuck child doesn't exit promptly after the second Ctrl-C.

_interrupts = 0
_procs_for_handler: "list[tuple[str, subprocess.Popen]]" = []


def _sigint_handler(signum, frame) -> None:  # noqa: ANN001
    global _interrupts
    _interrupts += 1
    if _interrupts == 1:
        try:
            sys.stderr.write(
                "\n[stopping — children are draining, Ctrl-C again to force kill]\n"
            )
            sys.stderr.flush()
        except Exception:  # noqa: BLE001
            pass
        return
    # Second (or later) Ctrl-C: escalate to SIGTERM on any still-running child,
    # then hand off to the default handler so a third Ctrl-C terminates us.
    for _, p in _procs_for_handler:
        if p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass
    _cleanup_terminal()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGINT)


def main() -> int:
    if _TTY:
        try:
            signal.signal(signal.SIGINT, _sigint_handler)
        except ValueError:
            pass

    env = {**os.environ, "GIT_SYNC_EVENTS": "1"}
    platforms: dict[str, _PlatformState] = {}
    procs: list[tuple[str, subprocess.Popen]] = []
    pumps: list[threading.Thread] = []

    for name, script in PLATFORMS:
        platforms[name] = _PlatformState(name=name, proc_started_at=time.monotonic())
        p = subprocess.Popen(
            [sys.executable, str(script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        t = threading.Thread(
            target=_pump_child, args=(name, p, platforms), daemon=True,
        )
        t.start()
        procs.append((name, p))
        pumps.append(t)

    # Give the signal handler a reference to running children so it can
    # send SIGTERM on the second Ctrl-C.
    global _procs_for_handler
    _procs_for_handler = procs

    display = _ParentDisplay(platforms)
    global _active_display
    _active_display = display
    display.start()

    try:
        # Each pump thread waits on its own child (in _pump_child after EOF)
        # and sets exited/exit_code on the platform state. Waiting on the pumps
        # therefore waits on every child to actually exit — and a fast-exiting
        # child's status flips in the display the moment it dies, not when
        # the loop happens to get around to it.
        for t in pumps:
            t.join()
    finally:
        display.stop()

    _print_per_platform_status(platforms)
    combined = [o for p in platforms.values() for o in p.outcomes]
    if combined:
        print_outcome_summary(combined)

    failures = sum(1 for _, p in procs if p.returncode not in (0, EXIT_SKIPPED))
    skipped = sum(1 for _, p in procs if p.returncode == EXIT_SKIPPED)
    ran = sum(1 for _, p in procs if p.returncode == 0)
    if failures:
        print(f"{C_YEL}One or more sync scripts reported failure.{C_OFF}", file=sys.stderr)
        return 1
    if ran == 0 and skipped > 0:
        print("All platforms skipped — no credentials configured.", file=sys.stderr)
        return EXIT_SKIPPED
    return 0


if __name__ == "__main__":
    sys.exit(main())

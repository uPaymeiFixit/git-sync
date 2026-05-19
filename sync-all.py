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
)

PLATFORMS = [
    ("gitlab",    HERE / "sync-gitlab.py"),
    ("bitbucket", HERE / "sync-bitbucket.py"),
    ("github",    HERE / "sync-github.py"),
]

_TTY = sys.stderr.isatty()
_MAX_WORKERS_PER_PLATFORM = 5  # cap visible rows so terminal height isn't blown out


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


def _erase_display_locked() -> None:
    global _display_lines
    if _display_lines > 0 and _TTY:
        sys.stderr.write(f"\033[{_display_lines}A\033[J")
        sys.stderr.flush()
        _display_lines = 0


def _write_log_line(line: str) -> None:
    with _log_lock:
        _erase_display_locked()
        sys.stderr.write(line)
        if not line.endswith("\n"):
            sys.stderr.write("\n")
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
            status_str = f"{C_DIM}(exit {p.exit_code}){C_OFF}"
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
        visible = workers[:_MAX_WORKERS_PER_PLATFORM]
        hidden = len(workers) - len(visible)
        for w in visible:
            lines.append(self._format_worker(w, width))
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
        status = payload.get("status", "")
        if status:
            p.counts[status] = p.counts.get(status, 0) + 1


def _pump_child(
    name: str,
    stream,
    platforms: "dict[str, _PlatformState]",
) -> None:
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


# ---- Signal handling ----

_orig_sigint = signal.getsignal(signal.SIGINT)


def _sigint_handler(signum, frame) -> None:  # noqa: ANN001
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
            target=_pump_child, args=(name, p.stdout, platforms), daemon=True,
        )
        t.start()
        procs.append((name, p))
        pumps.append(t)

    display = _ParentDisplay(platforms)
    display.start()

    try:
        for name, p in procs:
            p.wait()
            platforms[name].exited = True
            platforms[name].exit_code = p.returncode
        for t in pumps:
            t.join(timeout=2)
    finally:
        display.stop()

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

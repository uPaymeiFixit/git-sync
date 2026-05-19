#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from _sync import EXIT_SKIPPED  # noqa: E402

# Each child has its own stdout pipe (so it sees a non-TTY and falls back to
# the periodic 'progress: N/M' log line — the live worker block is for direct
# per-platform invocations, where you can actually see one platform at a time).
PLATFORMS = [
    ("gitlab",    HERE / "sync-gitlab.py"),
    ("bitbucket", HERE / "sync-bitbucket.py"),
    ("github",    HERE / "sync-github.py"),
]


def _stream_with_prefix(stream, prefix: str) -> None:
    for line in iter(stream.readline, ""):
        sys.stderr.write(f"[{prefix}] {line}")
        sys.stderr.flush()


def main() -> int:
    procs: list[tuple[str, subprocess.Popen]] = []
    pumps: list[threading.Thread] = []
    for name, script in PLATFORMS:
        p = subprocess.Popen(
            [sys.executable, str(script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,  # line-buffered: children emit log lines one at a time
        )
        t = threading.Thread(
            target=_stream_with_prefix, args=(p.stdout, name), daemon=True,
        )
        t.start()
        procs.append((name, p))
        pumps.append(t)

    for _, p in procs:
        p.wait()
    for t in pumps:
        t.join(timeout=2)

    failures = sum(1 for _, p in procs if p.returncode not in (0, EXIT_SKIPPED))
    skipped = sum(1 for _, p in procs if p.returncode == EXIT_SKIPPED)
    ran = sum(1 for _, p in procs if p.returncode == 0)
    if failures:
        print("One or more sync scripts reported failure.", file=sys.stderr)
        return 1
    if ran == 0 and skipped > 0:
        print("All platforms skipped — no credentials configured.", file=sys.stderr)
        return EXIT_SKIPPED
    return 0


if __name__ == "__main__":
    sys.exit(main())

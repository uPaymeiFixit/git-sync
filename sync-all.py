#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from _sync import EXIT_SKIPPED  # noqa: E402

SCRIPTS = [HERE / "sync-gitlab.py", HERE / "sync-bitbucket.py"]


def main() -> int:
    failures = 0
    skipped = 0
    ran = 0
    for script in SCRIPTS:
        rc = subprocess.run([sys.executable, str(script)]).returncode
        if rc == 0:
            ran += 1
        elif rc == EXIT_SKIPPED:
            skipped += 1
        else:
            failures += 1
    if failures:
        print("One or more sync scripts reported failure.", file=sys.stderr)
        return 1
    if ran == 0 and skipped > 0:
        print("All platforms skipped — no credentials configured.", file=sys.stderr)
        return EXIT_SKIPPED
    return 0


if __name__ == "__main__":
    sys.exit(main())

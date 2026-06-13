#!/usr/bin/env bash
# Differential test: prove the Swift RepoSyncer port matches the Python
# clone_or_update on every fixture branch.
#
#   scripts/diff-engine.sh [path-to-GitSync-binary]
#
# Builds the fixtures, runs the Python oracle and the Swift engine against
# the SAME fixtures (each rebuilt fresh so neither sees the other's side
# effects), and diffs the resulting (status, detail, shas) per fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

# Default to the raw SPM binary (`swift build` updates this directly). The
# .app bundle is only refreshed by build.sh, so it can be stale right after
# a plain `swift build` — using it silently ran an old binary during dev.
BIN="${1:-menubar/.build/release/GitSync}"
if [[ ! -x "$BIN" ]]; then
    echo "GitSync binary not found at $BIN — build it first (cd menubar && swift build -c release)" >&2
    exit 1
fi

PY_DIR="$(mktemp -d)/py"
SW_DIR="$(mktemp -d)/sw"
trap 'rm -rf "$(dirname "$PY_DIR")" "$(dirname "$SW_DIR")"' EXIT

# Build identical fixtures for each side (separate dirs: clone/update mutates
# the on-disk state, so each engine needs its own pristine copy).
python3 scripts/diff-fixtures.py build "$PY_DIR" >/dev/null
python3 scripts/diff-fixtures.py build "$SW_DIR" >/dev/null

echo "» Python oracle"
python3 scripts/diff-fixtures.py oracle "$PY_DIR" >/dev/null

echo "» Swift engine"
"$BIN" --diff-engine "$SW_DIR" >/dev/null

echo "» diff"
python3 - "$PY_DIR/oracle.json" "$SW_DIR/swift.json" <<'PYEOF'
import json, sys
oracle = {r["name"]: r for r in json.load(open(sys.argv[1]))}
swift  = {r["name"]: r for r in json.load(open(sys.argv[2]))}
keys = sorted(set(oracle) | set(swift))
# Compared exactly: status/detail/commits_ahead. SHAs are NOT compared by
# value — the two sides build independent fixture repos, so commit hashes
# differ by construction (commit timestamps). We instead compare SHA
# PRESENCE (empty vs populated), which is the real signal: did UPDATED
# populate old/new sha? did UP_TO_DATE correctly leave them empty?
exact_fields = ["status", "detail", "commits_ahead"]
def sha_shape(r):
    return (bool(r.get("old_sha")), bool(r.get("new_sha")))
mismatches = 0
for k in keys:
    o, s = oracle.get(k), swift.get(k)
    if o is None or s is None:
        print(f"  MISMATCH {k}: present in {'oracle' if o else 'swift'} only")
        mismatches += 1
        continue
    diffs = [f for f in exact_fields if o.get(f) != s.get(f)]
    if sha_shape(o) != sha_shape(s):
        diffs.append(f"sha_presence(old,new): python={sha_shape(o)} swift={sha_shape(s)}")
    if diffs:
        mismatches += 1
        print(f"  MISMATCH {k}:")
        for f in diffs:
            if f in exact_fields:
                print(f"      {f}: python={o.get(f)!r}  swift={s.get(f)!r}")
            else:
                print(f"      {f}")
    else:
        print(f"  ok   {k:24} {o['status']}")
print()
if mismatches:
    print(f"{mismatches} fixture(s) diverged between Python and Swift.")
    sys.exit(1)
print(f"All {len(keys)} fixtures match. Swift port is faithful to the Python.")
PYEOF

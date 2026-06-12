# GitSync menu-bar app

Native macOS menu-bar app for the git-sync scripts. Persistent **Repositories** inventory of every repo you have access to, organized by status — at-a-glance: which are diverged, dirty, stale, not-yet-cloned, etc. Click a repo to reveal it in Finder; right-click for per-repo actions (sync this one, add to skip list, copy SSH URL).

## Features

- **Repositories window** (⌘H): live inventory keyed by `(platform, rel)`. Searchable + filterable by status and platform. Survives across runs and app restarts. Status pills with hover tooltips.
- **Run history** (⇧⌘H): the per-run log view, for when you want the script's stderr from a specific run.
- **Settings** (⌘,): GIT_SYNC_* env vars + per-platform credentials (Keychain-backed). Bundles `glab` so GitLab works without a separate install.
- **Schedule**: timer-based, with Launch at Login.
- **Per-repo sync**: right-click a repo → "Sync this repo" runs the Python with `--only <rel>`.

## Requirements

- macOS 14+
- Swift 6 toolchain (ships with Xcode 16 or Command Line Tools 16+)
- `/usr/bin/python3` (macOS 14+ ships Python 3.9 there)

## Build + install

```
cd menubar
./build.sh release         # produces .build/release/GitSync.app
cp -r .build/release/GitSync.app /Applications/
xattr -dr com.apple.quarantine /Applications/GitSync.app   # first launch only
open /Applications/GitSync.app
```

The app uses an ad-hoc code signature. For sharing with others, swap `codesign --sign -` in `build.sh` for a Developer ID Application identity and notarize the bundle.

## Architecture

```
GitSync.app
├── AppState              — observable source of truth + event router
├── SyncRunner            — spawns scripts/sync-{platform}.py with GIT_SYNC_EVENTS=1
├── EventBuffer           — batches events; coalesces worker_phase
├── EventParser           — consumes the "\x1eGSE " JSON-line protocol
├── InventoryStore        — persistent repo state keyed by (platform, rel)
├── HistoryStore          — per-run logs on disk
├── SettingsStore         — UserDefaults + Keychain
└── MenuBarExtra UI       — three icon states: idle / running / attention
```

The app never modifies `.envrc`. Settings live in UserDefaults + Keychain (for tokens) and are passed to child processes as env vars on each run. `.envrc` remains the source of truth for command-line invocations.

## CLI test harnesses

The app's executable has four diagnostic modes:

```
.build/.../GitSync.app/Contents/MacOS/GitSync --verify-parser     # EventParser
.build/.../GitSync.app/Contents/MacOS/GitSync --smoke-test        # spawn + skip
.build/.../GitSync.app/Contents/MacOS/GitSync --load-test         # EventBuffer
.build/.../GitSync.app/Contents/MacOS/GitSync --pipe-stress-test  # pipe reader
```

These exist because the Command Line Tools toolchain doesn't ship XCTest or swift-testing.

## Inventory data

Stored at `~/Library/Application Support/GitSync/inventory.json` as a JSON array of `Repo` records. Pruned only when the user manually clears the file (no automatic eviction in v1).

## Python CLI flags

The platform scripts accept two app-driven flags in addition to the env-var config:

- `--list-only` — discover, emit `remote_project` events, exit. No clones. Used to refresh the inventory cheaply.
- `--only <rel>` — discover, then narrow `jobs` to a single repo. Used by the Repositories view's per-repo "Sync this repo" action.

These flags are silently ignored when running the scripts directly from a shell without GIT_SYNC_EVENTS=1; the unbatched output is the same as before.

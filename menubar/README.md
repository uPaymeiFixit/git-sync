# git-sync menu-bar app

Native macOS menu-bar app for the git-sync scripts. Shows last-run status, surfaces non-optimal repo states (dirty, diverged, stale), lets you trigger runs manually, and runs on a schedule you set.

## Status

Early scaffold. Builds and launches into the menu bar. Most features are stubs — see the implementation plan in `../../.claude/plans/wait-stop-don-t-implement-moonlit-perlis.md` for the roadmap.

## Requirements

- macOS 14+
- Swift 6 toolchain (ships with Xcode 16 or Command Line Tools 16+)
- Python 3.9+ on `/usr/bin/python3` or wherever you point the app

## Build

```
cd menubar
./build.sh           # release build, produces .build/release/GitSyncMenuBar.app
./build.sh debug     # debug build
```

Install:

```
cp -r .build/release/GitSyncMenuBar.app /Applications/
xattr -d com.apple.quarantine /Applications/GitSyncMenuBar.app   # first launch only
open /Applications/GitSyncMenuBar.app
```

The app uses an ad-hoc code signature. For sharing with others, swap `codesign --sign -` in `build.sh` for a Developer ID Application identity and notarize the bundle.

## Architecture

```
GitSyncMenuBar.app
├── AppState              — observable source of truth
├── SyncRunner            — spawns scripts/sync-{platform}.py with GIT_SYNC_EVENTS=1
├── EventParser           — consumes the "\x1eGSE " JSON-line protocol
└── MenuBarExtra UI       — three icon states: idle / running / attention
```

The app never modifies `.envrc`. Settings live in UserDefaults + Keychain (for tokens) and are passed to child processes as env vars on each run. `.envrc` remains the source of truth for command-line invocations.

## Testing

```
cd menubar
swift test
```

The `Tests/GitSyncMenuBarTests/Fixtures/` directory holds captured event streams from real runs (record with `GIT_SYNC_EVENTS=1 python3 ../scripts/sync-gitlab.py > fixture.txt`).

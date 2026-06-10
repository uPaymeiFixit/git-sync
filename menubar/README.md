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

This project builds against the Swift toolchain shipped with the Command Line Tools, which does not include XCTest or swift-testing. Instead the parser is exercised at runtime via:

```
./build.sh debug
.build/debug/GitSyncMenuBar.app/Contents/MacOS/GitSyncMenuBar --verify-parser
```

The fixture lives at [Sources/GitSyncMenuBar/Resources/all-events.txt](Sources/GitSyncMenuBar/Resources/all-events.txt) and is inlined into [Sources/GitSyncMenuBar/VerifyParser.swift](Sources/GitSyncMenuBar/VerifyParser.swift) (so the `.app` doesn't need to ship a resource bundle). To refresh:

```
python3 synthesize_fixture.py > Sources/GitSyncMenuBar/Resources/all-events.txt
# then paste the contents into VerifyParser.swift's embeddedFixture
```

When this project is opened in Xcode later, swap the inlined fixture for a real test target reading `all-events.txt` directly.

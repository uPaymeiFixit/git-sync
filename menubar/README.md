# GitSync menu-bar app

Native macOS menu-bar app that mirrors every repo you have access to across
GitLab/GitHub/Bitbucket to local disk. Persistent **Repositories** inventory
organized by status — at-a-glance: which are diverged, dirty, stale,
not-yet-cloned, etc. Click a repo to reveal it in Finder; right-click for
per-repo actions (sync this one, add to skip list, copy SSH URL).

The sync engine is pure Swift — it drives git directly (no Python, no external
CLIs). Configuration is in-app (UserDefaults + Keychain); there are no env vars.

## Features

- **Repositories window** (⌘H): live inventory keyed by `(providerID, platform, rel)`. Searchable + filterable by status and platform. Survives across runs and app restarts. Status pills with hover tooltips.
- **Run history** (⇧⌘H): the per-run log view, for investigating a specific run.
- **Settings** (⌘,): a list of providers (host/scope/token/folder/skip per provider), plus Behavior + Schedule. Tokens are Keychain-backed.
- **Schedule**: timer-based, with Launch at Login.
- **Per-repo sync**: right-click a repo → "Sync this repo" syncs just that one.

## Requirements

- macOS 15+
- Swift 6 toolchain (ships with Xcode 16 or Command Line Tools 16+)

## Build + install

```
cd menubar
./build.sh release         # produces .build/release/GitSync.app
cp -r .build/release/GitSync.app /Applications/
xattr -dr com.apple.quarantine /Applications/GitSync.app   # first launch only
open /Applications/GitSync.app
```

### Code signing & keychain prompts

`build.sh` signs with a stable local identity ("GitSync Self-Signed") so the
keychain ACL on your stored tokens matches across rebuilds — without that you'd
re-enter your login password for every secret on each launch. Run the one-time
setup before your first build:

```
./Tools/make-signing-cert.sh
```

This creates the identity **and** trusts it for code signing. Both matter: a
stable signature that isn't *trusted* still triggers keychain prompts. If you
created the cert with an older version of the script (no trust step), repair it
without recreating the cert:

```
security find-certificate -c "GitSync Self-Signed" -p > /tmp/gitsync.pem
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" /tmp/gitsync.pem
```

After trusting, relaunch once and click **Always Allow** a final time; prompts
should stop. For distribution to other Macs, set `SIGN_IDENTITY` to a Developer
ID Application identity and notarize the bundle.

## Architecture

```
GitSync.app
├── AppState              — observable source of truth + event router
├── SyncEngine            — pure-Swift sync engine; drives git directly (no Python)
│   ├── PlatformDiscovery — GitLab/GitHub/Bitbucket REST clients
│   └── RepoSyncer        — the clone_or_update decision tree
├── BufferSink/EventBuffer— engine emits events; batched + coalesced for the UI
├── InventoryStore        — persistent repo state keyed by (providerID, platform, rel)
├── ProviderStore         — configured sync sources (UserDefaults) + tokens (Keychain)
├── HistoryStore          — per-run logs on disk
├── SettingsStore         — shared run config (UserDefaults)
└── MenuBarExtra UI       — three icon states: idle / running / attention
```

The app never modifies `.envrc`. Configuration lives in UserDefaults (providers
+ shared settings) and the Keychain (per-provider tokens); the engine runs git
in-process with the inherited environment so git behaves as it does in a shell.

## CLI test harnesses

The app's executable has several diagnostic modes (the Command Line Tools
toolchain ships no XCTest, so these stand in):

```
.build/.../GitSync.app/Contents/MacOS/GitSync --verify-parser              # EventParser
.build/.../GitSync.app/Contents/MacOS/GitSync --smoke-test                 # engine wiring (no providers)
.build/.../GitSync.app/Contents/MacOS/GitSync --load-test                  # EventBuffer throughput
.build/.../GitSync.app/Contents/MacOS/GitSync --trash-test                 # delete-path safety
.build/.../GitSync.app/Contents/MacOS/GitSync --whitelist-test             # tracked-only filter
.build/.../GitSync.app/Contents/MacOS/GitSync --provider-migration-test    # legacy→provider migration
.build/.../GitSync.app/Contents/MacOS/GitSync --provider-validation-test   # provider folder-collision guard
.build/.../GitSync.app/Contents/MacOS/GitSync --abort-reset-test           # cancel doesn't poison later syncs
.build/.../GitSync.app/Contents/MacOS/GitSync --engine-sync [--only <rel>|--list-only]   # run the engine from a shell
```

## Inventory data

Stored at `~/Library/Application Support/GitSync/inventory.json` as a JSON array of `Repo` records. Pruned only when the user manually clears the file (no automatic eviction in v1).

# GitSync

A native macOS menu-bar app that mirrors every repo you have access to across
multiple Git hosts to local disk, and keeps them up to date. Idempotent — runs
on a schedule or on demand, and never overwrites local work.

**Supports:** self-hosted GitLab, GitHub.com, and Bitbucket Cloud. Configure any
subset as independent *providers* — you can have several of the same kind (e.g.
two GitLab instances), each with its own host, scope, token, and disk folder.

The sync engine is pure Swift (no Python, no external CLIs). All configuration
lives in the app — there are no environment variables or config files to manage.

## Build & install

```
./Tools/make-signing-cert.sh    # one-time: stable signing identity (stops keychain re-prompts)
./build.sh release              # produces .build/release/GitSync.app
cp -r .build/release/GitSync.app /Applications/
xattr -dr com.apple.quarantine /Applications/GitSync.app   # first launch only
open /Applications/GitSync.app
```

### Code signing & keychain prompts

`build.sh` signs with a stable local identity ("GitSync Self-Signed") so the
keychain ACL on your stored tokens matches across rebuilds — without that you'd
re-enter your login password for every secret on each launch.
`Tools/make-signing-cert.sh` (run once) creates the identity **and** trusts it
for code signing — both matter: a stable signature that isn't *trusted* still
triggers prompts. If you made the cert with an older version of that script (no
trust step), repair it without recreating it:

```
security find-certificate -c "GitSync Self-Signed" -p > /tmp/gitsync.pem
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" /tmp/gitsync.pem
```

For distribution to other Macs, set `SIGN_IDENTITY` to a Developer ID
Application identity and notarize the bundle.

## Configuration

Everything is configured in the app — **Settings → Providers** (⌘,). Add a
provider per source:

- **GitLab** — the instance **Host** (e.g. `gitlab.example.com`) + a personal
  access token with `read_api` + `read_repository`.
- **GitHub** — the **Organization** + a token. Classic PATs need the `repo`
  scope for private repos; fine-grained PATs need `Contents: Read` +
  `Metadata: Read` on the org.
- **Bitbucket** — the **Workspace** (the `bitbucket.org/<workspace>/…` slug) +
  your Bitbucket **Username** and an **App password** with the
  `read:repository:bitbucket` scope.

Each provider also has its own **disk folder**, **skip patterns**, an
**Include archived repos** toggle, and a **sync scope** (sync everything, or
only repos you've tracked). Tokens are stored in the macOS Keychain.

Other settings live under **Behavior** (parallel workers, clone depth, timeout)
and **Schedule** (manual / every-N-hours / daily, plus Launch at Login).

## Behavior

For each repo: clone if missing, otherwise fetch + fast-forward the default
branch when safe. **Never** force, reset, or overwrite local work. Uncommitted
changes on non-colliding paths are preserved across the fast-forward (so leaving
e.g. `.vscode/settings.json` edited won't block updates); if your changes would
collide with incoming files, git refuses and the repo is reported as dirty
instead. Diverged branches (local commits not on remote) are reported, not
touched.

The **Repositories** window (⌘H) shows a live inventory of every known repo
keyed by `(provider, platform, rel)`, grouped by status (diverged, dirty, stale,
not-cloned-yet, …) and searchable/filterable. Click a repo to reveal it in
Finder; right-click for per-repo actions (sync this one, add to skip list, copy
SSH URL). **Run history** (⇧⌘H) keeps the per-run log for when something needs
investigating.

## Skipping repos

Each provider has a **Skip patterns** field: a comma-separated list of repo
names or path prefixes to skip (case-insensitive, prefix match), e.g.
`legacy-monorepo, some-group/archive/`. Skipped repos still appear in the
inventory (marked skipped) so you know they exist; their on-disk state is left
alone.

## Scheduling

Set **Settings → Schedule** to every-N-hours or daily. Scheduled runs fire while
GitSync is running, with sleep-aware catch-up for missed runs; enable **Launch
at Login** so the app comes back after a reboot. A platform that's unreachable
(e.g. GitLab behind a VPN that's down) is isolated — it stays due and retries
cheaply without dragging the others along or touching any repos.

## Architecture

Single Swift package (`Package.swift` at the repo root, sources under
`Sources/GitSync/`):

```
GitSync.app
├── AppState              — observable source of truth + event router
├── SyncEngine            — pure-Swift sync engine; drives git directly
│   ├── PlatformDiscovery — GitLab/GitHub/Bitbucket REST clients
│   └── RepoSyncer        — the clone-or-update decision tree
├── BufferSink/EventBuffer— engine emits events; batched + coalesced for the UI
├── InventoryStore        — persistent repo state keyed by (providerID, platform, rel)
├── ProviderStore         — configured sync sources (UserDefaults) + tokens (Keychain)
├── HistoryStore          — per-run logs on disk
├── SettingsStore         — shared run config (UserDefaults)
└── MenuBarExtra UI       — three icon states: idle / running / attention
```

The engine runs git in-process with the inherited environment (so git's
`~/.config`, credential helpers, and ssh config behave as they do in a shell).
The inventory persists at `~/Library/Application Support/GitSync/inventory.json`
(a JSON array of `Repo` records; cleared only by deleting the file).

## CLI test harnesses

The Command Line Tools toolchain ships no XCTest, so the executable carries its
own diagnostic modes:

```
.build/release/GitSync.app/Contents/MacOS/GitSync --verify-parser              # event wire-format parser
.build/release/GitSync.app/Contents/MacOS/GitSync --smoke-test                 # engine wiring (no providers)
.build/release/GitSync.app/Contents/MacOS/GitSync --load-test                  # EventBuffer throughput
.build/release/GitSync.app/Contents/MacOS/GitSync --trash-test                 # delete-path safety
.build/release/GitSync.app/Contents/MacOS/GitSync --whitelist-test             # tracked-only filter
.build/release/GitSync.app/Contents/MacOS/GitSync --provider-migration-test    # legacy→provider migration
.build/release/GitSync.app/Contents/MacOS/GitSync --provider-validation-test   # provider folder-collision guard
.build/release/GitSync.app/Contents/MacOS/GitSync --abort-reset-test           # cancel doesn't poison later syncs
.build/release/GitSync.app/Contents/MacOS/GitSync --scheduler-test             # due/catch-up logic
```

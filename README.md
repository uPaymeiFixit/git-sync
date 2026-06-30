<div align="center">

# GitSync

**Mirror every repo you can access — across GitLab, GitHub, and Bitbucket —
to your Mac, and keep them current. From the menu bar.**

Idempotent, schedule-aware, and safe: it never overwrites your local work.

<img src="https://github.com/user-attachments/assets/57b0a080-afea-4b86-8859-bb817a67aea8" width="820" alt="The Repositories window showing a filterable inventory of repos grouped by sync status, with a live sync-progress panel at the top">

</div>

---

## What it does

GitSync logs into the Git hosts you use, discovers **every repository you have
access to**, and clones or updates each one to a folder on your Mac. Run it once
and you have a local mirror of everything; leave it on a schedule and that mirror
stays current — search code locally, grep across hundreds of repos, work offline,
keep a backup.

It is **safe by design**. For each repo it clones if missing, otherwise fetches
and fast-forwards the default branch *only when that's safe*. It never force-
pushes, resets, or discards local changes. Uncommitted edits and diverged
branches are reported, not touched.

## Highlights

- **Many hosts, many accounts.** Self-hosted GitLab, GitHub.com, and Bitbucket
  Cloud — configured as independent *providers*. Run several of the same kind
  (e.g. two GitLab instances) side by side, each with its own host, token, and
  disk folder.
- **A live inventory of everything.** One searchable, filterable window listing
  every repo it knows about — cloned, not-yet-cloned, diverged, dirty, stale —
  grouped and color-coded by status.
- **Never loses your work.** Fast-forward only; uncommitted changes survive
  updates; collisions and diverged branches are surfaced, not clobbered.
- **Fast.** A pure-Swift engine drives git directly with a large worker pool —
  thousands of repos in a couple of minutes, with a live "what's each worker
  doing right now" panel so a stall is obvious.
- **Schedule-aware.** Every-N-hours or daily, with sleep-aware catch-up for runs
  missed while your Mac was asleep, and Launch at Login. A host that's
  unreachable (VPN down) is isolated and retried cheaply — it never drags the
  others down or touches your repos.
- **No config files.** Everything lives in the app; tokens go in the macOS
  Keychain. Nothing to edit by hand, no environment variables to set.

## Screenshots

| The menu bar |
| --- |
| <img src="https://github.com/user-attachments/assets/8da6f9dc-6d71-4c2a-b237-73ac71af15d2" width="280" alt="The GitSync menu-bar dropdown"> |
| Run on demand, jump to the inventory, open the activity log, or open Settings — all from the menu bar. The icon spins while syncing and flags anomalies when a run finishes. |

| Providers |
| --- |
| <img src="https://github.com/user-attachments/assets/7564eb79-a07d-4364-a502-05fcd9eb6d54" width="620" alt="Settings → Providers, listing configured sync sources"> |
| Add a provider per source. Each has its own host/scope, token, disk folder, skip patterns, and sync scope. |

| Editing a provider |
| --- |
| <img src="https://github.com/user-attachments/assets/f6160ed6-4e54-4549-99c8-cbb2113d92a1" width="520" alt="The provider editor sheet"> |
| Host, scope, token, and the folder its repos clone into — validated against your other providers so two can't collide on disk. |

## Install

> **Requires macOS 15 (Sequoia) or later.**

Download `GitSync.app` from the [latest release][releases], move it to
`/Applications`, and launch it. On first launch macOS may quarantine it
(unsigned by an Apple Developer ID); if it won't open, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/GitSync.app
```

### Build from source

```sh
./Tools/make-signing-cert.sh    # one-time: stable signing identity (see below)
./build.sh release              # produces .build/release/GitSync.app
cp -r .build/release/GitSync.app /Applications/
xattr -dr com.apple.quarantine /Applications/GitSync.app   # first launch only
open /Applications/GitSync.app
```

[releases]: https://github.com/uPaymeiFixit/git-sync/releases/latest

## Setup

On first launch GitSync walks you through adding your first provider. After that,
manage everything in **Settings → Providers** (⌘,). Add a provider per source:

| Host | You provide | Token scopes |
| --- | --- | --- |
| **GitLab** | Instance **Host** (e.g. `gitlab.example.com`) + a personal access token | `read_api`, `read_repository` |
| **GitHub** | The **Organization** + a token | Classic: `repo` · Fine-grained: `Contents: Read`, `Metadata: Read` |
| **Bitbucket** | The **Workspace** slug + your **Username** + an **App password** | `read:repository:bitbucket` |

Each provider also has its own **disk folder**, **skip patterns**, an **Include
archived repos** toggle, and a **sync scope** (sync everything, or only repos
you've explicitly tracked). Tokens are stored in the macOS Keychain — never on
disk in plain text.

Other settings live under **Behavior** (parallel workers, clone depth, network
timeout) and **Schedule** (manual / every-N-hours / daily, plus Launch at Login).

### Skipping repos

Each provider's **Skip patterns** field takes a comma-separated list of repo
names or path prefixes to skip (case-insensitive, prefix match), e.g.
`legacy-monorepo, some-group/archive/`. Skipped repos still appear in the
inventory (marked *skipped*) so you know they exist — their on-disk state is just
left alone.

## Using it

- **Run now** from the menu, or let the schedule do it.
- Open **Repositories** (⌘H) to browse the inventory: search by path, filter by
  status or host, click a repo to reveal it in Finder, or right-click for
  per-repo actions (sync just this one, add to skip list, copy SSH URL, move to
  Trash).
- **Move to Trash** is the only destructive action, and it's careful: it refuses
  any repo with uncommitted changes or unpushed commits, and everything it does
  remove goes to the macOS Trash (recoverable), never `rm`.

### Activity log

Every sync, one-off resync, per-repo outcome, and deletion is written to the
macOS unified log — so there's a durable record of what happened without GitSync
storing log files itself. **Open activity log…** (⌘L) opens Terminal on a live,
filtered tail of exactly GitSync's entries (recent history first, then streaming).
Or run it yourself from any terminal:

```sh
log show   --predicate 'subsystem == "com.uPaymeiFixit.GitSync"' --info --last 1d
log stream --predicate 'subsystem == "com.uPaymeiFixit.GitSync"' --info
```

(The system keeps these on a rolling budget — durable for days, not forever.)

---

## Under the hood

<details>
<summary>Architecture, code signing, and test harnesses</summary>

### Architecture

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
├── SettingsStore         — shared run config (UserDefaults)
├── RunLog                — unified-logging record of runs, outcomes, deletions
└── MenuBarExtra UI       — three icon states: idle / running / attention
```

The engine runs git in-process with the inherited environment (so git's
`~/.config`, credential helpers, and ssh config behave as they do in a shell).
The inventory persists at `~/Library/Application Support/GitSync/inventory.json`
(a JSON array of `Repo` records; it's a rebuildable cache — delete the file and
the next run repopulates it).

### Code signing & keychain prompts

`build.sh` signs with a stable local identity ("GitSync Self-Signed") so the
keychain ACL on your stored tokens matches across rebuilds — without that, macOS
re-prompts for your login password for every secret on each launch.
`Tools/make-signing-cert.sh` (run once) creates the identity **and** trusts it
for code signing — both matter: a stable signature that isn't *trusted* still
triggers prompts. If you made the cert with an older version of that script (no
trust step), repair it without recreating it:

```sh
security find-certificate -c "GitSync Self-Signed" -p > /tmp/gitsync.pem
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" /tmp/gitsync.pem
```

For distribution to other Macs, set `SIGN_IDENTITY` to a Developer ID
Application identity and notarize the bundle.

### CLI test harnesses

The Command Line Tools toolchain ships no XCTest, so the executable carries its
own diagnostic modes:

```
.../Contents/MacOS/GitSync --verify-parser              # event wire-format parser
.../Contents/MacOS/GitSync --smoke-test                 # engine wiring (no providers)
.../Contents/MacOS/GitSync --load-test                  # EventBuffer throughput
.../Contents/MacOS/GitSync --trash-test                 # delete-path safety
.../Contents/MacOS/GitSync --whitelist-test             # tracked-only filter
.../Contents/MacOS/GitSync --provider-migration-test    # legacy→provider migration
.../Contents/MacOS/GitSync --provider-validation-test   # provider folder-collision guard
.../Contents/MacOS/GitSync --abort-reset-test           # cancel doesn't poison later syncs
.../Contents/MacOS/GitSync --scheduler-test             # due/catch-up logic
```

</details>

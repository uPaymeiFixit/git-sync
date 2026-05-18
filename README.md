# git-sync

Sync every repo you have access to across multiple Git hosts to local disk. Idempotent — re-run anytime.

**Currently supports:** Bitbucket Cloud, self-hosted GitLab, and GitHub.com. Each is optional — configure any subset.

## Setup

**Prereqs:** Python 3.10+, `git`, [`glab`](https://gitlab.com/gitlab-org/cli) (for GitLab), SSH access to the hosts you'll sync from.

**Bitbucket creds** — either `~/.netrc` (preferred, `chmod 600`):

```
machine api.bitbucket.org
    login <bitbucket-username>
    password <app-password>
```

or env vars (see [.envrc.example](.envrc.example)). The app password needs the `read:repository:bitbucket` scope (create at https://bitbucket.org/account/settings/app-passwords/).

**GitLab creds** — `glab auth login --hostname <your-gitlab-host>` (token needs `read_api` + `read_repository`).

**GitHub creds** — either `~/.netrc` (preferred):

```
machine api.github.com
    login <github-username>
    password <personal-access-token>
```

or env var `GIT_SYNC_GITHUB_TOKEN`. Classic PATs need the `repo` scope to access private repos; fine-grained PATs need `Contents: Read` + `Metadata: Read` on the target org. Create one at https://github.com/settings/tokens.

Any platform's creds may be omitted — that platform is skipped with a notice.

## Configuration

All configuration is via environment variables. See [.envrc.example](.envrc.example) for the full list with comments. The short version:

| Var | Required? |
|---|---|
| `GIT_SYNC_ROOT` | Always |
| `GIT_SYNC_BITBUCKET_WORKSPACE` | Only if syncing Bitbucket |
| `GITLAB_HOST` | Only if syncing GitLab |
| `GIT_SYNC_GITHUB_ORG` | Only if syncing GitHub |
| `GIT_SYNC_SKIP` | Optional |
| `GIT_SYNC_BITBUCKET_USER`, `GIT_SYNC_BITBUCKET_APP_PASSWORD` | Optional (alternative to `~/.netrc`) |
| `GIT_SYNC_GITHUB_TOKEN` | Optional (alternative to `~/.netrc`) |
| `GIT_SYNC_PARALLEL` | Optional (default 8) |
| `GIT_SYNC_DEPTH` | Optional (default 100; `0` for full history) |
| `GIT_SYNC_ALL_BRANCHES` | Optional (default off; `1` to clone all branches per repo) |
| `GIT_SYNC_TIMEOUT` | Optional (default 1800; max seconds per clone/fetch) |

Quickest setup: `cp .envrc.example .envrc`, edit values, then either `direnv allow` or `source .envrc`.

## Usage

From inside the repo:

```
./sync-all.py        # all configured platforms
./sync-bitbucket.py
./sync-gitlab.py
./sync-github.py
```

Or invoke by full path from anywhere — cwd doesn't matter, the scripts use `GIT_SYNC_ROOT` for paths.

## Behavior

For each repo: clone if missing, otherwise fetch + fast-forward the default branch when safe. **Never** force, reset, or overwrite local work — dirty trees and diverged branches are reported, not touched. End-of-run summary categorizes every repo (see the legend the script prints).

## Skipping repos

Set `GIT_SYNC_SKIP` to a comma-separated list of repo names or path prefixes. Case-insensitive, prefix match. Examples:

```
GIT_SYNC_SKIP="legacy-monorepo"             # skip one repo
GIT_SYNC_SKIP="some-group/archive/"         # skip a whole subtree
GIT_SYNC_SKIP="legacy, some-group/archive"  # multiple
```

Skipped repos are listed in the summary so you know they exist; their on-disk state is left alone.

## Scheduling with cron

Cron runs with a minimal environment, so set the vars inline. Example: sync once a day at 3 AM, log to a file.

```
0 3 * * * GIT_SYNC_ROOT=$HOME/git/synced GIT_SYNC_BITBUCKET_WORKSPACE=my-workspace GITLAB_HOST=gitlab.example.com $HOME/git/git-sync/sync-all.py >> $HOME/.git-sync.log 2>&1
```

Adjust `$HOME/git/git-sync/` to wherever you cloned this repo.

If credentials live in `~/.netrc` (Bitbucket) and `glab`'s config (GitLab), cron will find them — no extra setup. If you use env-var-based Bitbucket creds, add `GIT_SYNC_BITBUCKET_USER=...` and `GIT_SYNC_BITBUCKET_APP_PASSWORD=...` to the same line.

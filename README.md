# gitlab-github-mirror

Reconcile a personal **GitLab** and **GitHub** account and keep them mirrored —
using only the free tier and the `gh`/`glab` CLIs.

`mirror.sh` is a single POSIX `sh` script. It audits both accounts, creates the
missing counterpart repositories, configures a server-side **GitLab → GitHub
push mirror** for every project, and runs a scheduled **GitHub → GitLab safety
net** that rescues commits pushed directly to GitHub.

## Why this design (the GitLab Free constraint)

The two forges do not offer the same mirroring on their free plans:

| Direction | Feature | Availability |
|-----------|---------|--------------|
| GitLab → GitHub | GitLab **push mirror** | Free / Premium / Ultimate |
| GitHub → GitLab | GitLab **pull mirror** | **Premium / Ultimate only** |
| Both ways | GitLab bidirectional mirror | Premium, conflict-prone |
| GitHub → anywhere | ongoing server-side mirror | **not offered for `github.com`** |

So on the free tier only one direction is native and server-side: GitLab can
push to GitHub. `mirror.sh` therefore makes **GitLab canonical**:

- **Primary:** configure a GitLab push mirror so every GitLab commit is published
  to GitHub automatically by GitLab (no machine of yours has to be running).
- **Safety net:** a recurring `sync` job pulls/branches from GitHub and
  fast-forwards *clean* GitHub-side commits into GitLab, so work that lands on
  GitHub is not stranded there.
- **Conflict rule:** when the histories truly diverge, **GitLab wins** (the
  default). The GitHub ref is force-updated from GitLab; nothing is merged and no
  ref is deleted.

## Prerequisites

- `git`, [`gh`](https://cli.github.com/) (GitHub CLI) and
  [`glab`](https://gitlab.com/gitlab-org/cli) (GitLab CLI) on `PATH`.
- Authenticated CLIs:

  ```sh
  gh auth login
  glab auth login
  ```

- A GitHub credential with permission to read/push repository contents. The
  GitHub token is embedded in the GitLab push-mirror URL, so GitLab can push to
  GitHub on your behalf.

  - **Fine-grained PAT:** grant **Contents: Read and write** on the repositories
    you mirror. If any repository contains files under `.github/workflows/`,
    also grant **Workflows: Read and write** — GitHub rejects pushes that touch
    workflow files without it. `setup` creates repositories too, so the token
    also needs to be allowed to create repositories (with a fine-grained token,
    **Administration: Read and write**).
  - **Classic PAT (alternative):** `repo` scope, plus `workflow` if you push
    workflow files.

  Export it as `GITHUB_TOKEN`, or rely on the token stored by `gh auth login`
  (`mirror.sh` falls back to `gh auth token`).

- GitLab authentication is delegated entirely to `glab`; the tool never stores or
  prints a GitLab token.

## Install

```sh
install -m 0755 mirror.sh /usr/local/bin/mirror.sh
```

No runtime dependencies beyond the CLIs above; there is no `jq` requirement.

## Commands

```
mirror.sh <command> [options]

  audit   Report drift between GitLab and GitHub (read-only)
  setup   Create missing repos and configure GitLab -> GitHub push mirrors
  sync    GitHub -> GitLab fast-forward safety net
  help    Show this help
```

### `audit` — read-only drift report

Enumerates the GitLab personal namespace and the GitHub account (case-insensitive,
literal name matching) and prints one line per finding:

- `GitLab only: <name>` — missing on GitHub.
- `GitHub only: <name>` — missing on GitLab.
- For repos present on both sides, the push-mirror health:
  - `no push mirror: <name>`
  - `push mirror disabled: <name>`
  - `push mirror error: <name>`
  - `duplicate push mirrors: <name> (<count>)`
- `visibility mismatch: <name> (<gitlab> vs <github>)` — the visibility GitLab
  would map to (`public`/`private`) differs from what GitHub reports.
- `divergent: <name>` — a branch exists on both sides but neither history is an
  ancestor of the other (needs `--force-align` or a manual fix).
- `empty: <name>` — a both-present repo with no commits (no default branch);
  reported and skipped.

`audit` never mutates a remote. To detect divergent histories it reads through
(and therefore populates) the local cache and only ever fetches. Extra/duplicate
mirrors are reported, never deleted.

`audit` accepts `--json` (one machine-readable JSON object with a `gitlab_only`,
`github_only`, `no_mirror`, `mirror_disabled`, `mirror_error`,
`duplicate_mirrors`, `visibility_mismatch`, `divergent` and `empty` array),
`--exit-code` (exit non-zero when any bucket is non-empty) and `--verbose`
(per-bucket counts to stderr).

### `setup` — create the missing side and configure the push mirror

Prints a plan first, then applies it after confirmation. Actions:

- `create-github <name> <visibility>` — GitLab-only project: create the GitHub
  repo (GitLab `public` → GitHub `public`; `internal`/`private` → `private`).
- `configure-mirror <name> <project_id>` — ensure a healthy GitLab push mirror to
  `github.com/<user>/<name>.git`.
- `create-gitlab <name> <visibility>` — GitHub-only repo: create the GitLab
  project (GitHub `public` → GitLab `public`; otherwise GitLab `private`).
- `seed-gitlab <name>` — GitHub-only repo: bare-clone GitHub once and push all
  branches and tags to the new GitLab project (explicit refspecs, never
  `--mirror`), so GitLab starts equal to GitHub and can become canonical.

`setup` is idempotent and never deletes anything. Without `--yes` it prompts on a
terminal; with no terminal it refuses to run rather than hang. Re-running is a
no-op when nothing changed. Empty GitLab projects (no default branch) still get a
mirror configured and are not an error.

### `sync` — GitHub → GitLab safety net

For each GitLab project in the personal namespace (subject to `--only` /
`--exclude`):

1. Maintain a bare cache repo with `github` and `gitlab` remotes under the cache
   directory and fetch both.
2. **Branches:** create on GitLab if missing; fast-forward GitLab when GitLab is
   an ancestor of GitHub; otherwise treat as a conflict.
3. **Tags:** create on GitLab if missing; a same-named tag that points elsewhere
   is treated as a conflict.
4. Apply the conflict policy (`--conflict=lab` by default; see below).

A `mkdir` lock under the cache directory prevents overlapping `sync` runs; a
second concurrent run exits with `sync already running`.

## Options

| Option | Applies to | Meaning |
|--------|-----------|---------|
| `--dry-run` | `setup`, `sync` | Print the plan / commands and change nothing. For `sync` it echoes the git commands (including fetches) instead of running them; it still creates the local cache repository and takes the `sync` lock. |
| `--yes`, `-y` | `setup`, `sync` | Apply without interactive confirmation. |
| `--only NAME` | `sync` | Restrict to `NAME` (repeatable; case-insensitive, literal). |
| `--exclude NAME` | `sync` | Skip `NAME` (repeatable; case-insensitive, literal). |
| `--force-align` | `sync` | One-time force **GitLab → GitHub** for refs of divergent repos. |
| `--conflict=MODE` | `sync` | Conflict policy: `lab` (default, GitLab wins) or `report` (warn only). |
| `--json` | `audit` | Emit one machine-readable JSON object summarising every audit bucket. |
| `--exit-code` | `audit` | Exit non-zero when any drift bucket (not the `empty` bucket) is non-empty (default `audit` still exits `0`). |
| `--verbose`, `-v` | `audit` | Print per-bucket audit counts to stderr (no effect on stdout). |
| `--help`, `-h` | — | Show usage. |

Exit codes: `0` on success. `audit` reports drift but exits `0` unless
`--exit-code` is given, in which case it exits `1` when any drift bucket is
non-empty (an empty repo alone does not trigger it).
`setup`/`sync` exit non-zero if any intended action failed (per-repo failures are
reported and do not abort the rest of the run). An unknown command exits `2`.

### `--conflict` and `--force-align`

- `--conflict=lab` (default): on a truly divergent branch/tag, GitLab wins. The
  specific GitHub ref is force-updated from the cached GitLab ref. Only that ref
  changes; no other ref is touched and nothing is deleted.
- `--conflict=report`: warn and change neither side.
- `--force-align`: after the normal sync, for every GitHub branch/tag that exists
  on both sides and differs, force-update GitHub from GitLab once. It force-updates
  **only** refs that already exist on GitHub and **never deletes** a ref. This is
  destructive to GitHub's versions of those refs — see Caveats.

## Configuration (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `MIRROR_GITHUB_USER` | `gh api user -q .login` | GitHub account / namespace. |
| `MIRROR_GITLAB_USER` | parsed from `glab api user` | GitLab namespace. |
| `GITHUB_TOKEN` | `gh auth token` | GitHub credential embedded in the push-mirror URL. |
| `MIRROR_CACHE` | `${XDG_CACHE_HOME:-$HOME/.cache}/gitlab-github-mirror` | Cache repos and the `sync` lock. |
| `MIRROR_MAP` | unset | Optional name/visibility override file (see below). |
| `MIRROR_GITHUB_HOST` | `github.com` | GitHub host used to build URLs. |
| `MIRROR_GITLAB_HOST` | `gitlab.com` | GitLab host used to build URLs. |
| `MIRROR_GITHUB_URL_BASE` | `https://$MIRROR_GITHUB_HOST` | Override GitHub URL base (self-hosted/tests). |
| `MIRROR_GITLAB_URL_BASE` | `https://$MIRROR_GITLAB_HOST` | Override GitLab URL base (self-hosted/tests). |
| `GIT` | `git` | `git` binary to invoke. |
| `MIRROR_NO_MAIN` | `0` | Source-guard: when `1`, sourcing the script does not run `main`. |

Secrets are never echoed. The GitHub token appears only inside the mirror URL
sent to GitLab (GitLab stores it encrypted and scrubs it from API responses); the
request body is written to a `0600` file and passed to `glab api --input`.

### `MIRROR_MAP` file format

Plain text, one repo per line, whitespace-separated fields:

```
<gitlab-name> <github-name> [visibility]
```

Blank lines and lines starting with `#` are ignored. Only the GitHub **name**
mapping is applied in this version; the optional third field is accepted for
forward compatibility but is currently ignored, so the destination visibility is
always derived from the source repository. Anything not listed falls back to the
default same-name (case-insensitive) mapping.

## Scheduled sync

The tool does not schedule itself. Two equivalent examples:

### cron

```cron
*/15 * * * * /usr/local/bin/mirror.sh sync --yes >>"$HOME/.cache/gitlab-github-mirror/sync.log" 2>&1
```

(Note: cron does not expand `$HOME` in the command itself; use an absolute path
to the log, e.g. `>>/home/you/.cache/gitlab-github-mirror/sync.log`.)

### systemd

Example units live in `systemd/`. Install them in `~/.config/systemd/user/` (or
`/etc/systemd/system/` for a system service) and enable the timer:

```sh
systemctl --user daemon-reload
systemctl --user enable --now mirror-sync.timer
systemctl --user list-timers mirror-sync.timer
```

## How the safety net behaves

- A commit pushed directly to GitHub with GitLab as an ancestor fast-forwards
  cleanly and is rescued.
- A GitHub branch that GitLab has never seen is created on GitLab.
- A GitHub tag that GitLab lacks is pushed to GitLab.
- After a successful rescue GitLab holds the commit, and the GitLab → GitHub
  push mirror republishes it to GitHub as a no-op.

## Caveats

- **Only clean GitHub-side commits are rescued.** The safety net fast-forwards.
  If a GitHub branch diverged (both sides changed), it is not merged.
- **GitLab wins conflicts.** With the default `--conflict=lab`, the GitHub ref is
  force-updated from GitLab on divergence. Use `--conflict=report` to be warned
  instead of overwriting a GitHub-side commit.
- **`--force-align` is destructive to GitHub refs.** It force-updates GitHub
  branches/tags to GitLab's state. It never deletes a ref, but any GitHub-only
  commit on those refs is discarded.
- **Git refs only.** Issues, merge requests/PRs, wikis, releases, and CI settings
  are not mirrored.
- **Personal namespaces only.** Groups/organizations are out of scope.
- **Repo names are matched case-insensitively** and are assumed equal unless a
  `MIRROR_MAP` entry says otherwise.
- **Push mirrors:** GitLab allows up to 10 per project. The tool manages exactly
  one (to `$MIRROR_GITHUB_URL_BASE/<user>/<name>.git`, which defaults to
  `https://$MIRROR_GITHUB_HOST/<user>/<name>.git`); pre-existing extra mirrors are
  reported but never deleted, and the tool will not create a duplicate.
- **API/network failures** are reported per repo and do not abort the run; the
  run exits non-zero if any repo failed.

## Tests

```sh
sh test/run.sh     # fake-CLI unit/integration tests (hermetic, no network)
sh test/check.sh   # POSIX portability: sh -n, dash -n, shellcheck, checkbashisms
```

## Manual smoke test

Against real accounts (read-only), after authenticating both CLIs:

```sh
./mirror.sh audit
./mirror.sh setup --dry-run
```

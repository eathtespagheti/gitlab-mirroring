# Design: `mirror.sh` — GitLab ⇄ GitHub reconciler and mirror manager

- **Date:** 2026-10-09
- **Status:** Draft for review
- **Author:** brainstorming session (human + agent)
- **Base path:** `docs/superpowers/specs/2026-10-09-gitlab-github-mirror-design.md`

## 1. Problem

The user hosts most projects on GitLab and uses GitHub for forks, contributions,
and visibility. Today the two accounts have drifted:

- many GitLab projects are missing on GitHub, or exist but are not synced;
- some projects exist only on GitHub and are missing on GitLab;
- setting up mirroring by hand, per project, is tedious and error-prone.

The user wants a small tool that reconciles the two accounts and keeps them
mirrored going forward, built on the `gh` and `glab` CLIs.

### Research summary (context for the chosen design)

- **GitLab push mirror** (GitLab → external): **Free/Premium/Ultimate**. Server
  side, syncs commits/branches/tags automatically (~5 min, or ~1 min with
  "only protected branches"). Configured per project via the UI or the
  `POST /projects/:id/remote_mirrors` API.
- **GitLab pull mirror** (external → GitLab): **Premium/Ultimate only.**
- **GitLab bidirectional mirror:** Premium (since 13.9); conflict-prone.
- **GitHub** has no ongoing pull-mirror for `github.com` (one-time import or CI
  Actions only). Therefore GitLab must be the sync hub.
- Existing tools are close but incomplete for this use case:
  - `grdl/gitlab-mirror-maker` — public repos only, one-way GitLab→GitHub,
    same-name assumption, no reconciliation of GitHub-only repos, does not use
    `gh`/`glab`.
  - `cooperspencer/gickup` — scheduled clone/push backup across forges; not
    server-side mirroring and not account reconciliation.

**Conclusion:** build a focused POSIX `sh` utility.

## 2. Goals

- Audit both accounts and report drift (missing repos, missing/disabled/errored
  mirrors, visibility mismatches, divergent histories).
- Reconcile: create the missing counterpart repo on the other side.
- Configure a free, server-side **GitLab → GitHub push mirror** for every repo.
- Provide a recurring **GitHub → GitLab "safety net"** pull (no Premium) that
  rescues commits pushed directly to GitHub.
- Be safe, idempotent, and re-runnable; never delete repositories or branches.
- Be portable: runs under `dash`, `ash`, `sh`, `zsh`, and `bash`.

## 3. Non-goals

- Mirroring issues, merge requests/PRs, wikis, releases, or CI settings. Git refs
  only (branches, tags, commits).
- Groups/organizations or non-personal namespaces. Personal namespaces only.
- GitHub-native mirroring (does not exist for `github.com`).
- A long-running daemon or web UI.
- Renaming or deleting repositories.

## 4. Assumptions and constraints

- **Namespaces:** the authenticated GitLab user's personal namespace and the
  authenticated GitHub user's account only. Public and private repos included.
- **Name mapping:** same repo name on both sides, matched case-insensitively.
  An optional override file (`MIRROR_MAP`) handles exceptions (name or
  visibility differences).
- **Direction:** GitLab is always canonical. GitLab → GitHub is the primary,
  server-side mirror. GitHub → GitLab is a best-effort rescue of *clean*
  (fast-forward) GitHub-side commits.
- **Language:** POSIX `sh` only. No bashisms (`[[ ]]`, arrays, `local` where not
  POSIX-safe, `$'...'`, `function`, `pipefail`, process substitution,
  `${var,,}`). No hard `jq` dependency; use `gh`/`glab` built-in `--jq` where
  available and simple `sed`/`awk` for the one small GitLab response that needs
  it.
- **External tools required:** `sh`, `git`, `gh`, `glab`. On PATH.
- **Auth:** `gh` and `glab` must already be logged in. A GitHub token for the
  mirror URL is taken from `$GITHUB_TOKEN` or `gh auth token`.
- **Git-level auth for `sync`:** the tool does not manage GitLab tokens. `git`
  fetch/push uses the user's existing Git configuration — either SSH keys or a
  credential helper (e.g. `glab`'s git credential helper). Remotes are built
  from the standard HTTPS/SSH clone URL; a `MIRROR_GITLAB_HOST` /
  `MIRROR_GITHUB_HOST` override supports self-hosted GitLab or GitHub
  Enterprise.

## 5. Design overview

```
                 GitLab (canonical)                 GitHub (mirror + net)
                        |                                    ^
                        |  native push mirror (free)         |
                        +------------------------------------+
                        |                                    |
                        |  scheduled safety-net sync         |
                        +------------------------------------+
                        v                                    |
                 (fast-forward rescue)  <-------------------+
```

- GitLab → GitHub: GitLab's built-in push mirror (real-time, server-side).
- GitHub → GitLab: `mirror.sh sync`, run periodically by cron/systemd, which
  fast-forwards GitLab refs from GitHub and applies a conflict policy.
- `keep_divergent_refs=true` on the push mirror ensures GitHub-side commits are
  not clobbered before `sync` can rescue them.

## 6. CLI interface

`mirror.sh <command> [options]`

Commands:

| Command | Mutates? | Purpose |
|---------|----------|---------|
| `audit` | no | Report drift between the two accounts. |
| `setup` | yes | Create missing repos; configure push mirrors. |
| `sync`  | yes | GitHub → GitLab fast-forward rescue. |
| `help`  | no  | Usage. |

Common options:

- `--dry-run` — print the plan, change nothing.
- `--yes` — apply without interactive confirmation.
- `--only <name>` — restrict to one repo (repeatable).
- `--exclude <name>` — skip a repo (repeatable).
- `--force-align` — for divergent pairs, one-time force GitLab → GitHub.
- `--conflict=<lab|report>` — conflict policy for `sync` (default `lab`).
- `--json` — machine-readable output for `audit`.
- `--exit-code` — make `audit` exit non-zero when drift is found.
- `--verbose` — extra diagnostics to stderr.

Default behavior: `setup` and `sync` compute a plan and, without `--yes`, prompt
for confirmation before mutating.

Exit codes: `0` on success. `audit` returns `0` even when drift is found
(drift is reported, not an error) unless `--exit-code` is set. Any per-repo
failure that prevented an intended action makes the run exit non-zero.

## 7. Configuration and authentication

| Setting | Resolution order |
|---------|------------------|
| GitHub username | `$MIRROR_GITHUB_USER`, else `gh api user -q .login` |
| GitLab username | `$MIRROR_GITLAB_USER`, else `glab api user` parsed |
| GitHub token (mirror URL) | `$GITHUB_TOKEN`, else `gh auth token` |
| GitLab auth | delegated to `glab` (already logged in) |
| Cache dir | `$MIRROR_CACHE`, else `${XDG_CACHE_HOME:-$HOME/.cache}/gitlab-github-mirror` |
| Name/visibility overrides | `$MIRROR_MAP` file (optional) |
| Hosts | `$MIRROR_GITHUB_HOST` (default `github.com`), `$MIRROR_GITLAB_HOST` |

Secrets are never echoed. The GitHub token appears only inside the mirror URL
sent to GitLab (which stores it encrypted and scrubs it from API responses).

`MIRROR_MAP` is a plain-text file, one repo per line, with whitespace-separated
fields: `<gitlab-name> <github-name> [visibility]`, where `visibility` is
`public` or `private`. Blank lines and `#` comments are ignored. It overrides
the default same-name/case-insensitive mapping.

## 8. `audit`

1. List GitLab projects in the user namespace:
   `glab repo list --mine --per-page 100 --output json --jq '...'`, emitting
   `name`, `id`, `visibility`, and the configured-mirror summary.
2. List GitHub repos: `gh repo list "$GH_USER" --limit 1000 --json name,isPrivate,visibility -q '...'`.
3. Build case-insensitive sets and print buckets:
   - **GitLab only** → will be created on GitHub.
   - **GitHub only** → will be created on GitLab and seeded.
   - **Both, no active push mirror** → will be configured.
   - **Both, mirror disabled/erroring** → will be repaired.
   - **Visibility mismatch** → reported.
   - **Divergent histories** → reported (needs `--force-align` or manual fix).
   - **Empty repos** (no commits) → reported/skipped.
4. Output is human-readable; `--json` emits a machine-readable summary.

`audit` never mutates a remote. To detect divergent histories it may read
through (and therefore populate) the local cache, but it performs no remote
writes.

## 9. `setup` (idempotent; never deletes)

Preconditions: `gh` and `glab` logged in; GitHub token resolvable.

For each repo, after `audit`:

1. **GitLab only**
   - `gh repo create "$GH_USER/$name" --public|--private`
     (GitLab `public` → GitHub `public`; `private`/`internal` → GitHub `private`).
   - Configure the push mirror (§10) so GitLab populates the empty GitHub repo.
2. **GitHub only**
   - `glab repo create "$name" --public|--private|--internal --skipGitInit`
     (GitHub `public` → GitLab `public`; `private` → GitLab `private`).
   - Seed once: bare-clone GitHub and `git push --mirror` to GitLab, so
     GitLab starts equal to GitHub and can become canonical.
   - Configure the push mirror (§10).
3. **Both**
   - Ensure the push mirror exists and is healthy (§10).
   - If histories are divergent: report; with `--force-align`, force-update
     matching GitHub refs to GitLab's refs once (`git push --force` per ref,
     never `--mirror`), so no GitHub refs are deleted. Afterwards the
     steady-state mirror is left in place.

All creations preserve visibility. Every action is printed as a plan first and
requires `--yes` (or interactive confirmation) to run. Re-running is a no-op
when nothing changed.

Mirror-specific edge: GitLab allows up to 10 push mirrors per project. The tool
manages exactly one mirror targeting `github.com/<gh-user>/<name>.git`. If other
mirrors already exist they are reported, never auto-deleted; the tool declines to
add a duplicate.

## 10. Push mirror configuration (GitLab → GitHub)

`GET /projects/:id/remote_mirrors` (idempotency check) then, if needed,
`POST /projects/:id/remote_mirrors` with:

```
url                  = https://<gh-user>:<gh-token>@github.com/<gh-user>/<name>.git
auth_method          = password
enabled              = true
only_protected_branches = false
keep_divergent_refs  = true
```

Notes:

- `keep_divergent_refs=true` prevents the automatic push from overwriting
  GitHub-side commits, which is what makes the `sync` safety net viable.
- The idempotency GET returns scrubbed URLs
  (`https://*****:*****@github.com/<user>/<name>.git`); matching is done on the
  `github.com/<user>/<name>.git` fragment.
- The `remote_mirrors` response is small and parsed with `sed` to avoid a `jq`
  dependency. Only `id`, `url`, `enabled`, and `last_error` are needed.
- Optional `POST /projects/:id/remote_mirrors/:mirror_id/sync` can force an
  immediate push after setup.

## 11. `sync` — GitHub → GitLab safety net

Purpose: rescue *clean* GitHub-side commits that the push mirror has not (and
must not) overwrite.

Per managed repo, using a bare cache at `$MIRROR_CACHE/<name>.git`:

1. Initialise the cache if absent (`git init --bare`, add `github` and `gitlab`
   remotes). Remote URLs use the standard clone URL for each host; `git`'s
   authentication (SSH keys or a credential helper) is inherited from the user's
   environment. The tool never stores or echoes a GitLab token.
2. Fetch both sides with prune:
   `+refs/heads/*:refs/remotes/github/*`, same for `gitlab`, and tags.
3. For each GitHub branch `b`:
   - If `refs/remotes/gitlab/b` is missing, or
     `git merge-base --is-ancestor refs/remotes/gitlab/b refs/remotes/github/b`
     is true → GitHub is ahead/clean → push
     `refs/remotes/github/b:refs/heads/b` to GitLab.
   - Else → diverged. Apply conflict policy:
     - `--conflict=lab` (default): force GitLab → GitHub for that ref (GitLab
       wins; the GitHub-side commit is discarded).
     - `--conflict=report`: report only; change nothing.
4. For each GitHub tag: push if missing in GitLab; if present and different,
   treat as conflict per policy.
5. Read-only under `--dry-run`.

After a successful rescue, GitLab holds the rescued commit and the push mirror
re-publishes it to GitHub as a no-op.

### Why this policy

On a clean GitHub-ahead push, GitLab is an ancestor → fast-forward is safe and
non-destructive. On true divergence, both sides changed; per the user's stated
preference, **GitLab wins**. `--conflict=report` is available when the user
prefers to be warned rather than discard a GitHub-side commit.

## 12. Scheduling (external to the tool)

The tool does not run itself. Documented examples:

- **cron:** `*/15 * * * * /usr/local/bin/mirror.sh sync --yes >>"$HOME/.cache/gitlab-github-mirror/sync.log" 2>&1`
- **systemd:** a `mirror-sync.service` + `mirror-sync.timer` pair (units shipped
  in the repo as examples).
- Add a lock (e.g. `mkdir` lock in the cache dir) so overlapping runs of `sync`
  do not collide.

## 13. Error handling and safety

- Never delete repos, branches, or tags (except the explicit force-align /
  GitLab-wins conflict case, which overwrites a ref, not deletes a repo).
- All mutations are planned first; `--dry-run` and confirmation are respected.
- Missing `gh`/`glab`/`git`, or unauthenticated CLI, produce a clear message and
  non-zero exit before any mutation.
- Network/API failures are reported per repo and do not abort the whole run;
  the run ends with a non-zero exit if any repo failed.
- Rate limiting: use `--paginate` for `glab` and high `--limit` for `gh`; report
  API errors verbatim.
- A `sync` lock prevents concurrent runs.

## 14. Testing strategy (TDD)

- **Unit/integration without network:** place fake `gh`, `glab`, and `git` shims
  earlier in `PATH` that return canned JSON/text. Assert:
  - matching and bucketing in `audit`;
  - visibility mapping in `setup`;
  - SSH/HTTPS mirror URL construction and idempotency;
  - the ancestry/divergence decision table in `sync`;
  - `--dry-run` performs no mutation.
- **Portability checks:** `dash -n`, `sh -n`, `shellcheck`, `checkbashisms` in a
  `make check` / `test/run.sh`.
- **Live smoke test:** `mirror.sh audit` and `mirror.sh setup --dry-run` against
  the real accounts.

## 15. Deliverables

- `mirror.sh` — the POSIX `sh` utility.
- `README.md` — install, auth, usage, cron/systemd examples, caveats.
- `test/` — fake-CLI test harness and `test/run.sh`.
- Example `systemd/` units (optional).
- This spec.

## 16. Open questions (resolved during brainstorming)

- ~~Two-way native?~~ No — GitLab Free; use push mirror + scheduled rescue.
- ~~Per-repo direction?~~ No — GitLab always canonical.
- ~~Reverse job?~~ Recurring safety net with GitLab-wins conflict policy.
- ~~Scope?~~ Personal namespaces only, public + private.
- ~~Implementation?~~ POSIX `sh`, using `gh`/`glab`/`git`, no `jq` dependency.

---
name: gitlab-github-mirror
description: Use when the user wants to mirror, sync, reconcile, or back up repositories between their personal GitLab and GitHub accounts, configure GitLab-to-GitHub push mirrors, schedule the GitHub-to-GitLab sync, or troubleshoot that drift — using the mirror.sh tool in this repo.
---

# GitLab ⇄ GitHub Mirror (`mirror.sh`)

## Overview

`mirror.sh` reconciles one person's GitLab and GitHub accounts on the **free**
tier. GitLab is canonical: GitLab→GitHub is a native server-side **push mirror**,
and GitHub→GitLab is a scheduled **safety net** that fast-forwards clean
GitHub-side commits. Git refs only. The script is `./mirror.sh` in this repo;
`./mirror.sh help` and `README.md` are the authoritative flag/config reference.

## When to Use

- User wants to mirror, sync, reconcile, or back up repos between GitLab and GitHub.
- Configure or repair GitLab→GitHub push mirrors; schedule the recurring sync.
- Investigate drift (missing repos, broken mirrors, diverged histories).

Not for: groups/organizations or non-personal namespaces; issues, MRs/PRs,
wikis, or releases (git refs only).

## Safety contract

- **Always** run `audit` and a `--dry-run` first and show the user the plan
  before anything with `--yes`.
- **Never** run `setup --yes`, `sync --yes --force-align`, or `sync` with the
  default `--conflict=lab` without explicit consent — they can overwrite or
  discard GitHub-side refs. Prefer `--conflict=report` when unsure.
- `--force-align` is destructive to GitHub refs. Offer it; do not assume it.
- Never echo the GitHub token. Let the tool supply it (`$GITHUB_TOKEN` or
  `gh auth token`); it travels to GitLab inside a `0600 --input` file.
- Roll out carefully: `--only NAME` / `--exclude NAME` are honored by `sync`
  **only** (`setup` always processes all managed repos). Verify one repo with
  `sync --only NAME` before a fleet-wide sync.
- Enabling `systemd/mirror-sync.service` runs `sync --yes` with the default
  `--conflict=lab`, so turning the timer on is itself the consent for
  force-updating divergent GitHub refs. Use `--conflict=report` if unsure.
- The tool never deletes repos/branches/tags and never uses `git push --mirror`.

## Prerequisites

- `git`, `gh`, `glab` on `PATH`; `gh auth login` and `glab auth login` done.
- GitHub token needs **`contents:write`** (fine-grained) or `repo` (classic);
  add **`Workflows`/`workflow`** if any repo contains `.github/workflows/`.
- Run as `./mirror.sh` from this repo (or install it on `PATH`).

## Commands

| Command | Mutates | Purpose |
|---|---|---|
| `./mirror.sh audit` | no | Drift report (read-only). |
| `./mirror.sh setup` | yes | Create missing repos + configure push mirrors. |
| `./mirror.sh sync` | yes | GitHub→GitLab fast-forward rescue. |
| `./mirror.sh help` | no | Usage. |

Flags: `--dry-run`, `--yes`/`-y`, `--only NAME`, `--exclude NAME`,
`--force-align`, `--conflict=lab|report`, `--json`, `--exit-code`, `--verbose`.
`--json`/`--exit-code`/`--verbose` apply to `audit`; run `./mirror.sh help` for
the definitive list. Env: `MIRROR_GITHUB_USER`, `MIRROR_GITLAB_USER`,
`GITHUB_TOKEN`, `MIRROR_CACHE`, `MIRROR_MAP`, `MIRROR_GITHUB_HOST`/
`MIRROR_GITLAB_HOST` (see README for the table).

## Recommended workflow

1. `./mirror.sh audit --verbose` — review drift.
2. `./mirror.sh setup --dry-run` — show the plan.
3. With consent: `./mirror.sh setup --yes`.
4. `./mirror.sh sync --dry-run` then `./mirror.sh sync --yes` (or schedule it).
5. Schedule: install `systemd/mirror-sync.{service,timer}` for a user timer
   (`systemctl --user enable --now mirror-sync.timer` + `loginctl enable-linger`),
   or cron: `*/15 * * * * /path/mirror.sh sync --yes >>"$HOME/.cache/gitlab-github-mirror/sync.log" 2>&1`.

## Behavior to expect

- `setup` creates the missing GitHub repo (or a GitLab project seeded from
  GitHub), then configures a push mirror with `enabled=true`,
  `only_protected_branches=false`, `keep_divergent_refs=true`. Because divergent
  refs are kept, the automatic mirror will **not** clobber GitHub-side commits —
  that is what the `sync` safety net rescues.
- `sync`: fast-forwards GitLab from GitHub when GitHub is ahead; a no-op when
  GitLab is ahead; on true divergence it applies `--conflict` (default `lab`:
  GitLab wins and force-updates GitHub; `report`: warn only).

## Red flags / common mistakes

- Running `setup --yes` or `--force-align` without audit + dry-run and consent.
- Assuming GitHub→GitLab is real-time — it only runs when `sync` is scheduled
  and the machine/timer is up.
- Expecting issues/MRs/wikis/releases to sync — they do not.
- Expecting `--only`/`--exclude` to limit `setup` — they only filter `sync`.
- Missing the Workflows token scope → pushes with `.github/workflows/` fail.
- Pointing it at groups/orgs — it manages the personal namespace only.
- Expecting `--exit-code` to fail on empty repos — it fails only on real drift.

## Troubleshooting

- Mirror `error`/`disabled`: `./mirror.sh audit`; check token scope/expiry, then
  `setup --dry-run` and `setup --yes` to repair.
- `divergent`: reported by `audit`; resolve manually, or with consent
  `setup --yes --force-align` (or `sync --conflict=lab`).
- `sync already running`: stale `$MIRROR_CACHE/.sync.lock`; remove only if no
  sync is actually running. Default cache: `~/.cache/gitlab-github-mirror`.

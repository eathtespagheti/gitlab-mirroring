#!/bin/sh
# Task 7: `sync` core — rescue GitHub-side commits into GitLab. Branches and
# tags that only exist on GitHub are created; commits GitLab is an ancestor of
# are fast-forwarded. Real `git` runs against local bare repos (file:// URL
# bases), so the test is hermetic — no network, nothing written under the repo.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/test/helpers.sh"

# Capture the real git before the fake CLI dir goes on PATH; only glab/gh are
# faked, so `GIT` is pinned to the real binary and every test-side git call uses
# it directly.
GIT_BIN=$(command -v git) || { echo "git not found" >&2; exit 1; }
rev() { "$GIT_BIN" -C "$1" rev-parse --verify -q "$2" 2>/dev/null; }

work=$(mktemp -d)
seed=$(mktemp -d)
trap 'rm -rf "$work" "$seed"' EXIT

# Local "remotes": a bare repo per host per project, laid out the way
# resolve_config builds URLs: <URL_BASE>/<user>/<name>.git.
mkdir -p "$work/github/u" "$work/gitlab/u"
init_bare() { "$GIT_BIN" -c init.defaultBranch=main init --bare -q "$1" >/dev/null 2>&1; }
init_bare "$work/github/u/proj.git"
init_bare "$work/gitlab/u/proj.git"
init_bare "$work/github/u/other.git"
init_bare "$work/gitlab/u/other.git"
# `missing` exists on GitHub only (no GitLab bare repo) to exercise failures.
init_bare "$work/github/u/missing.git"

# Seed GitHub proj: main=one, feature=one, annotated tag v1 on one.
"$GIT_BIN" -C "$seed" -c init.defaultBranch=main init -q
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m one
"$GIT_BIN" -C "$seed" branch -q feature
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a tag -a -m v1 v1
"$GIT_BIN" -C "$seed" push -q "$work/github/u/proj.git" main feature v1
# Seed GitHub other: main=o1.
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m o1
"$GIT_BIN" -C "$seed" push -q "$work/github/u/other.git" HEAD:main

export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x
export MIRROR_GITHUB_URL_BASE="file://$work/github"
export MIRROR_GITLAB_URL_BASE="file://$work/gitlab"
export MIRROR_CACHE="$work/cache"
export GIT="$GIT_BIN"
export PATH="$ROOT/test/fakes:$PATH"

printf 'proj\t1\tprivate\tmain\nother\t2\tprivate\tmain\n' > "$work/gl.tsv"
printf 'missing\t3\tprivate\tmain\n' > "$work/missing.tsv"
printf '{"id":9,"enabled":true,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}\n' > "$work/mir.ndjson"
export FAKE_GLAB_PROJECTS="$work/gl.tsv" FAKE_GLAB_API_OUT="$work/mir.ndjson"

# --- rescue: main, missing branch `feature`, and tag v1 ---------------------
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj 2>&1); rc=$?
assert_eq "rescue rc" 0 "$rc"
assert_eq "proj main rescued" \
  "$(rev "$work/github/u/proj.git" main)" \
  "$(rev "$work/gitlab/u/proj.git" main)"
assert_eq "proj missing branch created" \
  "$(rev "$work/github/u/proj.git" feature)" \
  "$(rev "$work/gitlab/u/proj.git" feature)"
assert_eq "proj tag rescued" \
  "$(rev "$work/github/u/proj.git" v1)" \
  "$(rev "$work/gitlab/u/proj.git" v1)"
# --only must restrict work to proj.
other_rc=0
"$GIT_BIN" -C "$work/gitlab/u/other.git" rev-parse --verify -q main >/dev/null 2>&1 || other_rc=$?
assert_eq "--only leaves other untouched" 1 "$other_rc"

# --- fast-forward and --exclude --------------------------------------------
proj_before=$(rev "$work/gitlab/u/proj.git" main)
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m two
"$GIT_BIN" -C "$seed" push -q "$work/github/u/proj.git" main
"$GIT_BIN" -C "$seed" push -q "$work/github/u/other.git" HEAD:main
proj_after=$(rev "$work/github/u/proj.git" main)

out=$(sh "$ROOT/mirror.sh" sync --yes --exclude proj 2>&1); rc=$?
assert_eq "exclude rc" 0 "$rc"
assert_eq "proj excluded, not advanced" "$proj_before" \
  "$(rev "$work/gitlab/u/proj.git" main)"
assert_eq "other synced by exclude run" \
  "$(rev "$work/github/u/other.git" main)" \
  "$(rev "$work/gitlab/u/other.git" main)"

sh "$ROOT/mirror.sh" sync --yes --only proj >/dev/null 2>&1; rc=$?
assert_eq "fast-forward rc" 0 "$rc"
assert_eq "proj fast-forwarded to github" "$proj_after" \
  "$(rev "$work/gitlab/u/proj.git" main)"

# A second identical run is a no-op: GitHub is no longer ahead.
sh "$ROOT/mirror.sh" sync --yes --only proj >/dev/null 2>&1; rc=$?
assert_eq "idempotent rc" 0 "$rc"
assert_eq "idempotent ref" "$proj_after" \
  "$(rev "$work/gitlab/u/proj.git" main)"

# --- failure tracking: GitLab side unreachable must fail the run loudly ------
FAKE_GLAB_PROJECTS="$work/missing.tsv"
export FAKE_GLAB_PROJECTS
out=$(sh "$ROOT/mirror.sh" sync --yes --only missing 2>&1); rc=$?
assert_eq "unreachable GitLab exits non-zero" 1 "$rc"
assert_contains "failure names the repo" "missing" "$out"

# --- conflict policy: report vs lab (GitLab wins) ---------------------------
# Build a true divergence in a fresh pair of bare repos: a common commit, then
# GitLab gets commit L and GitHub gets commit G from that same base.
w2=$(mktemp -d)
mkdir -p "$w2/github/u" "$w2/gitlab/u"
"$GIT_BIN" -c init.defaultBranch=main init --bare -q "$w2/github/u/proj.git" >/dev/null
"$GIT_BIN" -c init.defaultBranch=main init --bare -q "$w2/gitlab/u/proj.git" >/dev/null

s=$(mktemp -d)
"$GIT_BIN" -C "$s" -c init.defaultBranch=main init -q
"$GIT_BIN" -C "$s" -c user.email=a@b -c user.name=a commit -q --allow-empty -m base
"$GIT_BIN" -C "$s" push -q "$w2/github/u/proj.git" main
"$GIT_BIN" -C "$s" push -q "$w2/gitlab/u/proj.git" main
# GitLab side: commit L.
"$GIT_BIN" -C "$s" -c user.email=a@b -c user.name=a commit -q --allow-empty -m L
"$GIT_BIN" -C "$s" push -q "$w2/gitlab/u/proj.git" main
L=$(rev "$w2/gitlab/u/proj.git" main)
# GitHub side: commit G from the common base.
"$GIT_BIN" -C "$s" -c user.email=a@b -c user.name=a reset -q --hard HEAD~1
"$GIT_BIN" -C "$s" -c user.email=a@b -c user.name=a commit -q --allow-empty -m G
"$GIT_BIN" -C "$s" push -q --force "$w2/github/u/proj.git" main
G=$(rev "$w2/github/u/proj.git" main)

export MIRROR_GITHUB_URL_BASE="file://$w2/github" MIRROR_GITLAB_URL_BASE="file://$w2/gitlab"
export MIRROR_CACHE="$w2/cache"
export FAKE_GLAB_PROJECTS="$w2/gl.tsv" FAKE_GLAB_API_OUT="$w2/mir.ndjson"
printf 'proj\t1\tprivate\tmain\n' > "$w2/gl.tsv"
printf '{"id":9,"enabled":true,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}\n' > "$w2/mir.ndjson"

# --conflict=report: warn and change neither side.
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj --conflict=report 2>&1); rc=$?
assert_eq "report rc" 0 "$rc"
assert_eq "report leaves gitlab alone" "$L" "$(rev "$w2/gitlab/u/proj.git" main)"
assert_eq "report leaves github alone" "$G" "$(rev "$w2/github/u/proj.git" main)"

# Default (lab): GitLab is canonical, GitHub is force-updated to L.
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj 2>&1); rc=$?
assert_eq "lab rc" 0 "$rc"
assert_contains "gitlab wins on conflict" "conflict" "$out"
assert_eq "github forced to gitlab" "$L" "$(rev "$w2/github/u/proj.git" main)"

# --force-align forces GitLab -> GitHub even under --conflict=report.
"$GIT_BIN" -C "$w2/github/u/proj.git" update-ref refs/heads/main "$G"
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj --conflict=report --force-align 2>&1); rc=$?
assert_eq "force-align rc" 0 "$rc"
assert_contains "force-align announced" "force-align" "$out"
assert_eq "force-align github to gitlab" "$L" "$(rev "$w2/github/u/proj.git" main)"

# A same-named tag that diverges follows the same policy (GitLab wins).
"$GIT_BIN" -C "$w2/gitlab/u/proj.git" tag -f t1 "$L" >/dev/null 2>&1
"$GIT_BIN" -C "$w2/github/u/proj.git" tag -f t1 "$G" >/dev/null 2>&1
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj 2>&1); rc=$?
assert_eq "tag conflict rc" 0 "$rc"
assert_contains "tag conflict gitlab wins" "tag conflict" "$out"
assert_eq "github tag forced to gitlab" "$L" "$(rev "$w2/github/u/proj.git" t1)"

# --- GitLab ahead is not a conflict: no warning, no force-push ---------------
# Fresh pair: base on both, then a GitLab-only commit, so GitHub is an ancestor
# of GitLab (the normal state between push-mirror updates).
w3=$(mktemp -d); s3=$(mktemp -d)
mkdir -p "$w3/github/u" "$w3/gitlab/u"
init_bare "$w3/github/u/proj.git"
init_bare "$w3/gitlab/u/proj.git"
"$GIT_BIN" -C "$s3" -c init.defaultBranch=main init -q
"$GIT_BIN" -C "$s3" -c user.email=a@b -c user.name=a commit -q --allow-empty -m base
"$GIT_BIN" -C "$s3" push -q "$w3/github/u/proj.git" main
"$GIT_BIN" -C "$s3" push -q "$w3/gitlab/u/proj.git" main
"$GIT_BIN" -C "$s3" -c user.email=a@b -c user.name=a commit -q --allow-empty -m L
"$GIT_BIN" -C "$s3" push -q "$w3/gitlab/u/proj.git" main
gl_ahead=$(rev "$w3/gitlab/u/proj.git" main)
gh_behind=$(rev "$w3/github/u/proj.git" main)
export MIRROR_GITHUB_URL_BASE="file://$w3/github" MIRROR_GITLAB_URL_BASE="file://$w3/gitlab"
export MIRROR_CACHE="$w3/cache"
printf 'proj\t1\tprivate\tmain\n' > "$w3/gl.tsv"
export FAKE_GLAB_PROJECTS="$w3/gl.tsv"
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj 2>&1); rc=$?
assert_eq "gitlab-ahead rc" 0 "$rc"
assert_eq "gitlab-ahead GitLab unchanged" "$gl_ahead" "$(rev "$w3/gitlab/u/proj.git" main)"
assert_eq "gitlab-ahead GitHub untouched" "$gh_behind" "$(rev "$w3/github/u/proj.git" main)"
assert_not_contains "gitlab-ahead is not a conflict" "conflict" "$out"

# --- MIRROR_MAP: the GitHub remote must use the mapped name ------------------
# GlName has no same-named GitHub repo: only GhName exists. A rescue can only
# succeed if sync builds the github remote from the mapped name.
w4=$(mktemp -d); s4=$(mktemp -d)
mkdir -p "$w4/github/u" "$w4/gitlab/u"
init_bare "$w4/github/u/GhName.git"
init_bare "$w4/gitlab/u/GlName.git"
"$GIT_BIN" -C "$s4" -c init.defaultBranch=main init -q
"$GIT_BIN" -C "$s4" -c user.email=a@b -c user.name=a commit -q --allow-empty -m base
"$GIT_BIN" -C "$s4" push -q "$w4/github/u/GhName.git" main
"$GIT_BIN" -C "$s4" push -q "$w4/gitlab/u/GlName.git" main
"$GIT_BIN" -C "$s4" -c user.email=a@b -c user.name=a commit -q --allow-empty -m more
"$GIT_BIN" -C "$s4" push -q "$w4/github/u/GhName.git" main
export MIRROR_GITHUB_URL_BASE="file://$w4/github" MIRROR_GITLAB_URL_BASE="file://$w4/gitlab"
export MIRROR_CACHE="$w4/cache"
printf 'GlName\t1\tprivate\tmain\n' > "$w4/gl.tsv"
printf 'GlName GhName\n' > "$w4/map"
export FAKE_GLAB_PROJECTS="$w4/gl.tsv" MIRROR_MAP="$w4/map"
out=$(sh "$ROOT/mirror.sh" sync --yes --only GlName 2>&1); rc=$?
assert_eq "mapped-name sync rc" 0 "$rc"
assert_eq "mapped-name rescue" \
  "$(rev "$w4/github/u/GhName.git" main)" "$(rev "$w4/gitlab/u/GlName.git" main)"
assert_contains "mapped github remote url" "github/u/GhName.git" \
  "$(cat "$w4/cache/GlName.git/config")"
unset MIRROR_MAP
rm -rf "$w3" "$s3" "$w4" "$s4"

# --- lock: a pre-existing lock makes sync refuse and is left intact ----------
rm -rf "$MIRROR_CACHE"
mkdir -p "$MIRROR_CACHE/.sync.lock"
out=$(sh "$ROOT/mirror.sh" sync --yes 2>&1); rc=$?
assert_eq "locked rc" 1 "$rc"
assert_contains "locked msg" "already running" "$out"
assert_eq "foreign lock preserved" 0 "$( [ -d "$MIRROR_CACHE/.sync.lock" ]; echo $? )"
rmdir "$MIRROR_CACHE/.sync.lock"

rm -rf "$w2" "$s"

report

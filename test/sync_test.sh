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

report

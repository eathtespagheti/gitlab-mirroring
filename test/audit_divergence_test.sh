#!/bin/sh
# Task 10: `audit` reports divergent histories (read-only, cache-backed).
# Uses real `git` against local bare repos (file:// URL bases) as in Task 8, so
# the test is hermetic: no network, nothing written under the repository.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/test/helpers.sh"

GIT_BIN=$(command -v git) || { echo "git not found" >&2; exit 1; }
rev() { "$GIT_BIN" -C "$1" rev-parse --verify -q "$2" 2>/dev/null; }

work=$(mktemp -d)
seed=$(mktemp -d)
trap 'rm -rf "$work" "$seed"' EXIT

mkdir -p "$work/github/u" "$work/gitlab/u"
init_bare() { "$GIT_BIN" -c init.defaultBranch=main init --bare -q "$1" >/dev/null 2>&1; }
init_bare "$work/github/u/proj.git"
init_bare "$work/gitlab/u/proj.git"
# A second, non-divergent pair: GitHub is strictly ahead (fast-forwardable).
init_bare "$work/github/u/ff.git"
init_bare "$work/gitlab/u/ff.git"

# proj: common base, then GitLab=L and GitHub=G from that same base (true fork).
"$GIT_BIN" -C "$seed" -c init.defaultBranch=main init -q
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m base
"$GIT_BIN" -C "$seed" push -q "$work/github/u/proj.git" main
"$GIT_BIN" -C "$seed" push -q "$work/gitlab/u/proj.git" main
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m L
"$GIT_BIN" -C "$seed" push -q "$work/gitlab/u/proj.git" main
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a reset -q --hard HEAD~1
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m G
"$GIT_BIN" -C "$seed" push -q --force "$work/github/u/proj.git" main

# ff: base on both, then GitHub-only commit (GitLab is an ancestor).
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m b2
"$GIT_BIN" -C "$seed" push -q "$work/github/u/ff.git" main
"$GIT_BIN" -C "$seed" push -q "$work/gitlab/u/ff.git" main
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m c2
"$GIT_BIN" -C "$seed" push -q "$work/github/u/ff.git" main

export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x
export MIRROR_GITHUB_URL_BASE="file://$work/github"
export MIRROR_GITLAB_URL_BASE="file://$work/gitlab"
export MIRROR_CACHE="$work/cache"
export GIT="$GIT_BIN"
export PATH="$ROOT/test/fakes:$PATH"

printf 'proj\t1\tprivate\tmain\nff\t2\tprivate\tmain\n' > "$work/gl.tsv"
printf 'proj\tprivate\nff\tprivate\n' > "$work/gh.tsv"
printf '{"id":9,"enabled":true,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}\n' > "$work/mir.ndjson"
export FAKE_GLAB_PROJECTS="$work/gl.tsv" FAKE_GH_REPOS="$work/gh.tsv"
export FAKE_GLAB_API_OUT="$work/mir.ndjson"

out=$(sh "$ROOT/mirror.sh" audit 2>&1); rc=$?
assert_eq "audit rc with divergence" 0 "$rc"
assert_contains "divergent proj reported" "divergent: proj" "$out"
assert_not_contains "fast-forward ff not divergent" "divergent: ff" "$out"

json=$(sh "$ROOT/mirror.sh" audit --json 2>/dev/null)
assert_contains "json divergent list" '"divergent":["proj"]' "$json"

# --exit-code fires on the divergence alone.
sh "$ROOT/mirror.sh" audit --exit-code >/dev/null 2>&1
assert_eq "exit-code on divergence" 1 "$?"

# --- MIRROR_MAP: divergence detection must fetch the mapped GitHub name ------
# GlMap has no same-named GitHub repo; only GhMap exists. A true divergence can
# only be proven when the mapping is applied.
init_bare "$work/github/u/GhMap.git"
init_bare "$work/gitlab/u/GlMap.git"
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m base3
"$GIT_BIN" -C "$seed" push -q "$work/github/u/GhMap.git" main
"$GIT_BIN" -C "$seed" push -q "$work/gitlab/u/GlMap.git" main
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m L3
"$GIT_BIN" -C "$seed" push -q "$work/gitlab/u/GlMap.git" main
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a reset -q --hard HEAD~1
"$GIT_BIN" -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m G3
"$GIT_BIN" -C "$seed" push -q --force "$work/github/u/GhMap.git" main

printf 'GlMap\t3\tprivate\tmain\n' >> "$work/gl.tsv"
printf 'GlMap\tprivate\n' >> "$work/gh.tsv"
printf 'GlMap GhMap\n' > "$work/map"
export MIRROR_MAP="$work/map"
out=$(sh "$ROOT/mirror.sh" audit 2>&1)
assert_contains "mapped divergence reported" "divergent: GlMap" "$out"
unset MIRROR_MAP

report

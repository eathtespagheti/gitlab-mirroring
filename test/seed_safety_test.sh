#!/bin/sh
# Final-review fix: seeding must never clobber an existing GitLab project.
# Layer 1 (apply_setup): `seed-gitlab X` runs only when `create-gitlab X`
# actually created the project in this run. Layer 2 (seed_gitlab_from_github):
# refuse to seed when the target GitLab project already advertises refs.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/test/helpers.sh"
source_mirror "$ROOT"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$ROOT/test/fakes:$PATH"
export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x
export GITHUB_URL_BASE="file://$tmp/github" GITLAB_URL_BASE="file://$tmp/gitlab"
GH_USER=u
GL_USER=u
ASSUME_YES=1
DRY_RUN=0

# --- Layer 1a: project already exists -> create skipped -> seed skipped ------
WORK_DIR="$tmp/a"; mkdir -p "$WORK_DIR"
: > "$WORK_DIR/setup.gh.tsv"
printf 'X\t5\tprivate\tmain\n' > "$WORK_DIR/setup.gl.tsv"
plan_setup() { printf 'create-gitlab X private\nseed-gitlab X\n'; }
: > "$tmp/calls_a"
create_gitlab_project() { printf 'CREATE\n' >> "$tmp/calls_a"; }
seed_gitlab_from_github() { printf 'SEED\n' >> "$tmp/calls_a"; }
out=$(apply_setup 2>&1); rc=$?
assert_eq "existing-project apply rc" 0 "$rc"
assert_contains "existing project create skipped" "already exists, skipping: X" "$out"
assert_not_contains "existing project not created" "CREATE" "$(cat "$tmp/calls_a")"
assert_not_contains "existing project not seeded" "SEED" "$(cat "$tmp/calls_a")"

# --- Layer 1b: create fails -> seed skipped ----------------------------------
WORK_DIR="$tmp/b"; mkdir -p "$WORK_DIR"
: > "$WORK_DIR/setup.gh.tsv"
: > "$WORK_DIR/setup.gl.tsv"
plan_setup() { printf 'create-gitlab X private\nseed-gitlab X\n'; }
: > "$tmp/calls_b"
create_gitlab_project() { printf 'CREATE\n' >> "$tmp/calls_b"; return 1; }
seed_gitlab_from_github() { printf 'SEED\n' >> "$tmp/calls_b"; }
out=$(apply_setup 2>&1); rc=$?
assert_eq "failed-create apply rc" 1 "$rc"
assert_not_contains "failed create not seeded" "SEED" "$(cat "$tmp/calls_b")"
assert_contains "failed create skip message" "skipping seed for X" "$out"

# --- Layer 2: seeding a target that already has refs refuses -----------------
# Re-source to restore the real seed_gitlab_from_github (the stubs above shadow
# it), then point GIT at the fake so `ls-remote` reports an existing ref.
source_mirror "$ROOT"
WORK_DIR="$tmp/c"; mkdir -p "$WORK_DIR"
export GIT="$ROOT/test/fakes/git"
: > "$tmp/git.log"; export FAKE_GIT_LOG="$tmp/git.log"
FAKE_GIT_LSREMOTE="abc123	refs/heads/main"; export FAKE_GIT_LSREMOTE
out=$(seed_gitlab_from_github X 2>&1); rc=$?
assert_eq "seed-existing rc" 0 "$rc"
assert_contains "seed-existing refuses" "refusing to seed X" "$out"
assert_not_contains "seed-existing no clone" "clone" "$(cat "$tmp/git.log")"
assert_not_contains "seed-existing no push" "push" "$(cat "$tmp/git.log")"

report

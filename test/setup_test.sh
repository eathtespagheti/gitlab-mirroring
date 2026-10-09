#!/bin/sh
# Task 5: `setup` plan generation (dry-run). plan_setup must describe the
# reconcile actions without mutating anything.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Alpha exists on BOTH hosts with a healthy mirror (exercises mirror_status);
# Empty is GitLab-only (empty repo); Gamma is GitHub-only.
printf 'Alpha\t11\tpublic\tmain\nEmpty\t12\tprivate\t\n' > "$tmp/gl.tsv"
printf 'Alpha\tpublic\nGamma\tpublic\n' > "$tmp/gh.tsv"
printf '{"id":101,"enabled":true,"url":"https://*****:*****@github.com/u/Alpha.git","last_error":null}\n' > "$tmp/mir.ndjson"

export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x MIRROR_CACHE="$tmp/cache"
export PATH="$ROOT/test/fakes:$PATH"
: > "$tmp/calls.log"; export FAKE_CALLS_LOG="$tmp/calls.log"
export FAKE_GLAB_PROJECTS="$tmp/gl.tsv" FAKE_GH_REPOS="$tmp/gh.tsv" FAKE_GLAB_API_OUT="$tmp/mir.ndjson"

out=$(sh "$ROOT/mirror.sh" setup --dry-run 2>&1)
# Plan lines are space-separated (repo names contain no spaces).
assert_contains "GitLab-only Empty created on GitHub" "create-github Empty private" "$out"
assert_contains "Empty gets a mirror configured"      "configure-mirror Empty 12" "$out"
assert_contains "empty repo handled"                  "Empty" "$out"
assert_contains "GitHub-only Gamma created on GitLab" "create-gitlab Gamma public" "$out"
assert_contains "Gamma is seeded"                     "seed-gitlab Gamma" "$out"
# Alpha exists on both with a healthy mirror -> no configure line for it
case "$out" in *"configure-mirror Alpha"*) assert_eq "Alpha mirror untouched" "absent" "present" ;; esac
# dry-run must not mutate
calls=$(cat "$FAKE_CALLS_LOG")
case "$calls" in *"repo create"*) assert_eq "no mutation in dry-run" "no create" "created" ;; esac

# Direct interface: an empty GitLab project (blank default branch) still gets a
# mirror configured and never crashes. Fixture is committed; the fake serves it
# read-only, so repeated runs leave the tree clean.
out=$(FAKE_GLAB_PROJECTS="$ROOT/test/fixtures/gl_empty.tsv" FAKE_GH_REPOS=/dev/null \
      sh "$ROOT/mirror.sh" setup --dry-run 2>&1); rc=$?
assert_eq "empty-only plan rc" 0 "$rc"
assert_contains "empty-only create-github" "create-github Empty private" "$out"
assert_contains "empty-only configure-mirror" "configure-mirror Empty 12" "$out"

# A failing listing must fail the command loudly, never silently plan nothing.
FAKE_GLAB_PROJECTS=/nonexistent
export FAKE_GLAB_PROJECTS
out=$(sh "$ROOT/mirror.sh" setup --dry-run 2>&1); rc=$?
assert_contains "failing listing reports error" "failed to list GitLab projects" "$out"
case "$rc" in
  0) assert_eq "failing listing exits nonzero" "nonzero" "0" ;;
  *) : ;;
esac

# apply: `setup --yes` creates the missing repos, seeds, and configures push
# mirrors. GIT points at the fake so seeding is observed, never networked; the
# GitHub token is a sentinel so the test can prove it is never printed (it rides
# in the `--input` body file, which the fake records).
export FAKE_GLAB_PROJECTS="$tmp/gl.tsv" FAKE_GH_REPOS="$tmp/gh.tsv" FAKE_GLAB_API_OUT="$tmp/mir.ndjson"
export GIT="$ROOT/test/fakes/git" FAKE_GIT_LOG="$tmp/git.log" FAKE_BODY_LOG="$tmp/body.log"
export GITHUB_TOKEN="token_SENTINEL_6f3a"
: > "$FAKE_CALLS_LOG"; : > "$FAKE_GIT_LOG"; : > "$FAKE_BODY_LOG"
out=$(sh "$ROOT/mirror.sh" setup --yes 2>&1); rc=$?
assert_eq "apply rc" 0 "$rc"
calls=$(cat "$FAKE_CALLS_LOG")
assert_contains "created GitHub repo Empty" "gh repo create u/Empty --private" "$calls"
assert_contains "created GitLab project Gamma" "glab repo create Gamma" "$calls"
assert_contains "seeded from github" "clone" "$(cat "$FAKE_GIT_LOG")"
assert_contains "configured mirror Empty" "glab api -X POST projects/12/remote_mirrors" "$calls"
body=$(cat "$FAKE_BODY_LOG")
assert_contains "mirror url" "github.com/u/Empty.git" "$body"
assert_contains "keep divergent" '"keep_divergent_refs":true' "$body"
assert_contains "enabled" '"enabled":true' "$body"
assert_contains "auth method" '"auth_method":"password"' "$body"
assert_contains "only protected false" '"only_protected_branches":false' "$body"
# The secret must never be printed: it is carried inside the --input body only.
assert_contains "token carried in body" "https://u:token_SENTINEL_6f3a@github.com/u/Empty.git" "$body"
assert_not_contains "token not printed" "token_SENTINEL_6f3a" "$out"

# Without --yes and without a terminal the apply must refuse, never hang and
# never mutate.
: > "$FAKE_CALLS_LOG"
out=$(sh "$ROOT/mirror.sh" setup </dev/null 2>&1); rc=$?
assert_contains "non-interactive refuses" "refusing to apply without --yes" "$out"
case "$rc" in
  0) assert_eq "non-interactive exits nonzero" "nonzero" "0" ;;
  *) : ;;
esac
case "$(cat "$FAKE_CALLS_LOG")" in
  *"repo create"*) assert_eq "no mutation without --yes" "no create" "created" ;;
esac

# A disabled existing mirror is updated in place (PUT by id), never duplicated.
printf 'Beta\t13\tpublic\tmain\n' > "$tmp/gl_disabled.tsv"
printf 'Beta\tpublic\n' > "$tmp/gh_beta.tsv"
printf '{"id":202,"enabled":false,"url":"https://*****:*****@github.com/u/Beta.git","last_error":null}\n' > "$tmp/mir_disabled.ndjson"
export FAKE_GLAB_PROJECTS="$tmp/gl_disabled.tsv" FAKE_GH_REPOS="$tmp/gh_beta.tsv" FAKE_GLAB_API_OUT="$tmp/mir_disabled.ndjson"
: > "$FAKE_CALLS_LOG"; : > "$FAKE_BODY_LOG"
out=$(sh "$ROOT/mirror.sh" setup --yes 2>&1); rc=$?
assert_eq "apply disabled rc" 0 "$rc"
assert_contains "disabled mirror updated in place" "glab api -X PUT projects/13/remote_mirrors/202" "$(cat "$FAKE_CALLS_LOG")"
assert_contains "disabled mirror body" "github.com/u/Beta.git" "$(cat "$FAKE_BODY_LOG")"
case "$(cat "$FAKE_CALLS_LOG")" in
  *"remote_mirrors --input"*) assert_eq "no duplicate mirror created" "no POST" "POST" ;;
esac

report

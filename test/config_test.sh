#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"
source_mirror "$ROOT"

assert_eq "public -> public"   public   "$(gl_to_gh_visibility public)"
assert_eq "internal -> private" private "$(gl_to_gh_visibility internal)"
assert_eq "private -> private" private  "$(gl_to_gh_visibility private)"
assert_eq "PRIVATE -> private" private  "$(gh_to_gl_visibility PRIVATE)"
assert_eq "PUBLIC -> public"   public   "$(gh_to_gl_visibility PUBLIC)"
assert_eq "INTERNAL -> internal" internal "$(gh_to_gl_visibility INTERNAL)"

# MIRROR_MAP override + case-insensitive default
tmp=$(mktemp -d); printf 'MyRepo my-renamed public\n' > "$tmp/map"
MIRROR_MAP=$tmp/map
export MIRROR_MAP
assert_eq "map override" "my-renamed" "$(map_github_name MyRepo)"
assert_eq "map fallback" "other"      "$(map_github_name other)"
unset MIRROR_MAP

# Args
parse_args audit --dry-run --only a --exclude b --conflict=report
assert_eq "cmd" audit "$CMD"
assert_eq "dry-run on" 1 "$DRY_RUN"
assert_eq "conflict report" report "$CONFLICT"

parse_args sync -y
assert_eq "yes" 1 "$ASSUME_YES"

# Missing token must fail before mutation. Simulate by unsetting GITHUB_TOKEN and
# making the fake `gh auth token` return nothing (exit 1).
out=$(env -u GITHUB_TOKEN FAKE_GH_TOKEN_EMPTY=1 PATH="$ROOT/test/fakes:$PATH" \
      MIRROR_NO_MAIN=0 MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u \
      MIRROR_CACHE="$tmp/cache" \
      sh "$ROOT/mirror.sh" audit --dry-run 2>&1); rc=$?
assert_eq "missing token rc" 1 "$rc"
assert_contains "missing token msg" "GitHub token" "$out"

report

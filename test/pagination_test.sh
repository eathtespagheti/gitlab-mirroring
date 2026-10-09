#!/bin/sh
# Final-review fix: list_gitlab_projects must page past the first 100 projects.
# The fake glab serves --per-page 100 slices; 100 projects on page 1 plus 1 on
# page 2 must yield 101 unduplicated lines.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/test/helpers.sh"
source_mirror "$ROOT"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$ROOT/test/fakes:$PATH"
export FAKE_CALLS_LOG="$tmp/calls"
: > "$FAKE_CALLS_LOG"

i=1
: > "$tmp/gl.tsv"
while [ "$i" -le 101 ]; do
  printf 'proj%03d\t%s\tprivate\tmain\n' "$i" "$i" >> "$tmp/gl.tsv"
  i=$((i + 1))
done
export FAKE_GLAB_PROJECTS="$tmp/gl.tsv"

out=$(list_gitlab_projects); rc=$?
assert_eq "pagination rc" 0 "$rc"
assert_eq "pagination serves both pages" 101 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "pagination first line intact" \
  "$(printf 'proj001\t1\tprivate\tmain')" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "pagination last line intact" \
  "$(printf 'proj101\t101\tprivate\tmain')" "$(printf '%s\n' "$out" | sed -n 101p)"
assert_eq "pagination requested two pages" 2 "$(grep -c -- '--page' "$FAKE_CALLS_LOG")"

report

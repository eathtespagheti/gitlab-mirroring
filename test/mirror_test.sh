#!/bin/sh
# Task 4: parse GitLab push-mirror records and classify the mirror to GitHub.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"
source_mirror "$ROOT"
GH_USER=u

FAKEDIR="$ROOT/test/fakes"
FIX="$ROOT/test/fixtures"
PATH="$FAKEDIR:$PATH"; export PATH
# Consume the fixtures directly, so no cache dir (and nothing under $HOME) is touched.
export FAKE_GLAB_API_OUT="$FIX/mirrors_present.ndjson"

# mirror_list parses compact NDJSON (no jq) into id<TAB>url<TAB>enabled<TAB>last_error.
list_out=$(mirror_list 11)
assert_eq "mirror_list parses fields" \
  "$(printf '101\thttps://*****:*****@github.com/u/proj.git\ttrue\tnull')" \
  "$(printf '%s\n' "$list_out" | sed -n 1p)"
assert_eq "mirror_list second record" \
  "$(printf '102\thttps://*****:*****@github.com/u/proj.name.git\ttrue\tnull')" \
  "$(printf '%s\n' "$list_out" | sed -n 2p)"
assert_eq "mirror_list record count" 2 "$(printf '%s\n' "$list_out" | wc -l | tr -d ' ')"

# present + healthy
export FAKE_GLAB_API_OUT="$FIX/mirrors_present.ndjson"
assert_eq "healthy mirror" ok "$(mirror_status 11 proj)"

# disabled
export FAKE_GLAB_API_OUT="$FIX/mirrors_disabled.ndjson"
assert_eq "disabled mirror" disabled "$(mirror_status 11 proj)"

# missing (no mirror to github)
export FAKE_GLAB_API_OUT="$FIX/mirrors_missing.ndjson"
assert_eq "missing mirror" missing "$(mirror_status 11 proj)"

# erroring mirror (last_error non-null)
export FAKE_GLAB_API_OUT="$FIX/mirrors_error.ndjson"
assert_eq "erroring mirror" error "$(mirror_status 11 proj)"

# metacharacter repo name must be matched literally
export FAKE_GLAB_API_OUT="$FIX/mirrors_present.ndjson"
assert_eq "dot name literal" ok "$(mirror_status 11 'proj.name')"

# Regression guard: '.' must never act as a wildcard, so a.b must not match aXb.
export FAKE_GLAB_API_OUT="$FIX/mirrors_metachar.ndjson"
assert_eq "dot is not a wildcard" missing "$(mirror_status 11 'a.b')"
assert_eq "literal name still matches" ok "$(mirror_status 11 'aXb')"

# Case-insensitive target: GitLab project Beta vs GitHub repo beta.
export FAKE_GLAB_API_OUT="$FIX/mirrors_present.ndjson"
assert_eq "case-insensitive match" ok "$(mirror_status 11 'Proj')"

# A healthy duplicate wins over a stale disabled mirror to the same target.
export FAKE_GLAB_API_OUT="$FIX/mirrors_dupes.ndjson"
assert_eq "healthy duplicate wins" ok "$(mirror_status 11 proj)"

# A failing GitLab API must surface as error (and warn), never as missing.
err_log=$(mktemp) || exit 1
export FAKE_GLAB_API_FAIL=1
api_status=$(mirror_status 11 proj 2>"$err_log")
assert_eq "api failure -> error" error "$api_status"
assert_contains "api failure warns" \
  "mirror: warning: could not query mirrors for project 11" "$(cat "$err_log")"
unset FAKE_GLAB_API_FAIL
rm -f "$err_log"

# The target is anchored on "@github.com/", so a lookalike host cannot match.
export FAKE_GLAB_API_OUT="$FIX/mirrors_fakehost.ndjson"
assert_eq "lookalike host does not match" missing "$(mirror_status 11 proj)"

report

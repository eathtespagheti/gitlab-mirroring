#!/bin/sh
# Task 3/4: audit buckets repos case-insensitively and reports push-mirror health.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"

# Hermetic: keep resolve_config's cache dir (and any temp files) out of $HOME.
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Fixtures are committed and only read, so repeated runs leave the tree clean.
# GitLab: Alpha (only), Beta (case-mismatched vs GitHub), dot.name (both),
#         weird+name (both, regex metachars), a.b (only, dot must not be a wildcard)
export FAKE_GLAB_PROJECTS="$ROOT/test/fixtures/gl_projects.tsv"
# GitHub: beta (lowercase), Gamma (only), dot.name (both), weird+name (both),
#         aXb (only; a.b regex would falsely match it)
export FAKE_GH_REPOS="$ROOT/test/fixtures/gh_repos.tsv"
export MIRROR_CACHE="$TMP/cache"
export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x
export PATH="$ROOT/test/fakes:$PATH"
export FAKE_CALLS_LOG="$TMP/calls.log"

out=$(sh "$ROOT/mirror.sh" audit --dry-run 2>&1); rc=$?
assert_eq "audit rc" 0 "$rc"

# GitLab-only bucket.
assert_contains "GitLab-only Alpha" "GitLab only: Alpha" "$out"
assert_contains "GitLab-only dot-literal a.b" "GitLab only: a.b" "$out"

# GitHub-only bucket.
assert_contains "GitHub-only Gamma" "GitHub only: Gamma" "$out"
assert_contains "GitHub-only dot-literal aXb" "GitHub only: aXb" "$out"

# Case-insensitive match: Beta/beta must NOT be reported as only-on-one-host.
assert_not_contains "Beta not gitlab-only" "GitLab only: Beta" "$out"
assert_not_contains "beta not github-only" "GitHub only: beta" "$out"

# Same-name repos must not be reported.
assert_not_contains "dot.name not gitlab-only" "GitLab only: dot.name" "$out"
assert_not_contains "dot.name not github-only" "GitHub only: dot.name" "$out"

# Literal metacharacter matching: '+' must not act as a regex quantifier and '.'
# must not act as a wildcard.
assert_not_contains "weird+name not gitlab-only" "GitLab only: weird+name" "$out"
assert_not_contains "weird+name not github-only" "GitHub only: weird+name" "$out"
assert_not_contains "a.b not github-only (no wildcard)" "GitHub only: a.b" "$out"
assert_not_contains "Alpha not github-only" "GitHub only: Alpha" "$out"
assert_not_contains "Gamma not gitlab-only" "GitLab only: Gamma" "$out"

# Both-present repos default to "no push mirror" when no mirror fixture is set.
# Beta/beta (casing differs) and dot.name (metacharacter name) must survive.
assert_contains "no push mirror Beta" "no push mirror: Beta" "$out"
assert_contains "no push mirror dot.name" "no push mirror: dot.name" "$out"
assert_contains "no push mirror weird+name" "no push mirror: weird+name" "$out"

# Both-present push-mirror status reporting. One fixture is served for every
# project, so each repo is classified by the target its own name selects:
#   dot.name  -> enabled/healthy to .../u/dot.name.git  => silent
#   weird+name-> disabled mirror                        => "push mirror disabled"
#   Beta      -> enabled but last_error, to .../u/beta.git (case-insensitive)
#                                                       => "push mirror error"
out=$(FAKE_GLAB_API_OUT="$ROOT/test/fixtures/mirrors_audit.ndjson" \
      sh "$ROOT/mirror.sh" audit --dry-run 2>&1); rc=$?
assert_eq "audit rc with mirrors" 0 "$rc"
assert_contains "disabled mirror reported" "push mirror disabled: weird+name" "$out"
assert_contains "erroring mirror reported" "push mirror error: Beta" "$out"
assert_not_contains "healthy dot.name silent (literal match)" "no push mirror: dot.name" "$out"
assert_not_contains "healthy dot.name not disabled" "push mirror disabled: dot.name" "$out"
assert_not_contains "healthy dot.name not error" "push mirror error: dot.name" "$out"
assert_not_contains "case-insensitive Beta not missing" "no push mirror: Beta" "$out"

# Pre-existing duplicate mirrors to the same target are reported, not hidden.
out=$(FAKE_GLAB_API_OUT="$ROOT/test/fixtures/mirrors_audit_dupes.ndjson" \
      sh "$ROOT/mirror.sh" audit --dry-run 2>&1); rc=$?
assert_eq "audit rc with dup mirrors" 0 "$rc"
assert_contains "duplicate mirrors reported" "duplicate push mirrors: dot.name (2)" "$out"
assert_not_contains "unique repo has no dup line" "duplicate push mirrors: Beta" "$out"

# A failing mirror API must not masquerade as "no push mirror".
out=$(FAKE_GLAB_API_FAIL=1 sh "$ROOT/mirror.sh" audit --dry-run 2>&1); rc=$?
assert_eq "audit rc with api failure" 0 "$rc"
assert_contains "api failure reports error" "push mirror error: Beta" "$out"
assert_not_contains "api failure not missing" "no push mirror: Beta" "$out"

# Direct interface checks: list_* fields and repo_key lowercasing.
source_mirror "$ROOT"
GH_USER=u
gl_out=$(list_gitlab_projects)
assert_contains "list_gitlab_projects fields" "$(printf 'Alpha\t11\tpublic\tmain')" "$gl_out"
gh_out=$(list_github_repos)
assert_contains "list_github_repos fields" "$(printf 'beta\tprivate')" "$gh_out"
assert_eq "repo_key lowercases" "hello.world" "$(repo_key 'Hello.World')"

report

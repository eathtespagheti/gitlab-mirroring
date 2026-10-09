# GitLab ⇄ GitHub Mirror Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `mirror.sh`, a POSIX `sh` utility that reconciles a personal GitLab and GitHub account, configures free server-side GitLab→GitHub push mirrors, and runs a scheduled GitHub→GitLab fast-forward "safety net".

**Architecture:** A single POSIX `sh` script with subcommands (`audit`, `setup`, `sync`, `help`) plus a fake-CLI test harness. `audit`/`setup` call `gh` and `glab`; `sync` uses real `git` against the two remotes. GitLab is always canonical; the push mirror uses `keep_divergent_refs=true` so GitHub-side commits survive until `sync` rescues them.

**Tech Stack:** POSIX `sh` (`dash`/`ash`/`sh`/`zsh`/`bash` compatible), `git`, `gh`, `glab`. No `jq` dependency (uses the CLIs' built-in `--jq` and a small `sed` parser).

**Spec:** `docs/superpowers/specs/2026-10-09-gitlab-github-mirror-design.md`

## Global Constraints

- **POSIX `sh` only.** No bashisms: no `[[ ]]`, arrays, `$'...'`, `function`, `pipefail`, process substitution, `${var,,}`. Must pass `dash -n`, `sh -n`, `shellcheck`, and `checkbashisms` (when installed).
- **External tools:** `sh`, `git`, `gh`, `glab` on `PATH`. No `jq`.
- **Never delete** repositories, branches, or tags. `--force-align` uses `git push --force` per ref, **never** `--mirror`.
- **Never echo secrets** (the GitHub token).
- **Scope:** personal namespaces only, public + private; same repo name both sides, matched **case-insensitively**; `MIRROR_MAP` overrides.
- **Push mirror params (exact):** `auth_method=password`, `enabled=true`, `only_protected_branches=false`, `keep_divergent_refs=true`, `url=https://<gh-user>:<gh-token>@github.com/<gh-user>/<name>.git`.
- **Exit codes:** `0` success; non-zero on any per-repo failure or usage error. `audit` exits `0` with drift unless `--exit-code`.
- **Test hooks (env):** `MIRROR_GITHUB_USER`, `MIRROR_GITLAB_USER`, `GITHUB_TOKEN`, `MIRROR_CACHE`, `MIRROR_MAP`, `MIRROR_GITHUB_HOST`, `MIRROR_GITLAB_HOST`, `MIRROR_GITHUB_URL_BASE`, `MIRROR_GITLAB_URL_BASE`, `MIRROR_NO_MAIN`.

## Review Focus

Inputs/conditions the spec implies but whose tests could be missed. Each is pinned to a test in the task that owns the code.

1. **Repo-name casing differs between hosts** (`MyApp` on GitLab vs `myapp` on GitHub) → must match case-insensitively and NOT create a duplicate. (Task 3)
2. **Repo names containing `sed`/glob metacharacters** (`.`, `+`, `[`, `*`) → matching and `sed` parsing must not corrupt or over-match. (Tasks 3 and 4)
3. **Empty GitLab project** (zero commits / no default branch) → `setup` must not crash and must still configure the mirror. (Task 5)
4. **Missing or invalid GitHub token** → clear error before any mutation; no partial writes. (Tasks 2 and 6)
5. **Concurrent `sync` runs** → the lock prevents two runs colliding in the cache. (Task 8)
6. **GitLab `internal` visibility → GitHub `private`** (GitHub has no `internal`). (Task 2)

---

### Task 1: Skeleton, arg parsing, dispatch, help, portability gate

**Files:**
- Create: `mirror.sh`
- Create: `test/run.sh`
- Create: `test/helpers.sh`
- Create: `test/cli_test.sh`
- Create: `test/check.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `main "$@"`; `die <msg>` (exit 1, stderr); `warn <msg>`; `info <msg>`; globals `CMD`, `DRY_RUN`, `ASSUME_YES`, `FORCE_ALIGN`, `CONFLICT`, `JSON_OUT`, `EXIT_CODE`, `VERBOSE`, `ONLY_LIST`, `EXCLUDE_LIST`; `use_main_guard` via `MIRROR_NO_MAIN`.

- [ ] **Step 1: Write the failing test** (`test/cli_test.sh`)

```sh
#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"

out=$("$ROOT/mirror.sh" help 2>&1)
assert_contains "help lists audit" "audit" "$out"
assert_contains "help lists setup" "setup" "$out"
assert_contains "help lists sync" "sync" "$out"

out=$("$ROOT/mirror.sh" bogus 2>&1); rc=$?
assert_eq "unknown command rc" 2 "$rc"
assert_contains "unknown command msg" "unknown command" "$out"

"$ROOT/mirror.sh" >/dev/null 2>&1
assert_eq "no args exits 2" 2 $?

# sourcing must not run main (MIRROR_NO_MAIN guard)
out=$(MIRROR_NO_MAIN=1 sh -c '. "$1"; map_github_name Foo' sh "$ROOT/mirror.sh")
assert_eq "sourcing does not run main" "Foo" "$out"

report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/cli_test.sh`
Expected: FAIL — `mirror.sh` does not exist.

- [ ] **Step 3: Implement `mirror.sh` skeleton and test helpers**

`mirror.sh` (top, then bottom):

```sh
#! /bin/sh
# mirror.sh - reconcile a personal GitLab and GitHub account and keep them mirrored.
LC_ALL=C
export LC_ALL
: "${MIRROR_NO_MAIN:=0}"

die()  { printf 'mirror: error: %s\n' "$1" >&2; exit 1; }
warn() { printf 'mirror: warning: %s\n' "$1" >&2; }
info() { printf '%s\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: mirror.sh <command> [options]

Commands:
  audit   Report drift between GitLab and GitHub (read-only)
  setup   Create missing repos and configure GitLab -> GitHub push mirrors
  sync    GitHub -> GitLab fast-forward safety net
  help    Show this help

Options:
  --dry-run          Print the plan, change nothing
  --yes, -y          Apply without interactive confirmation
  --only NAME        Restrict to NAME (repeatable)
  --exclude NAME     Skip NAME (repeatable)
  --force-align      One-time force GitLab -> GitHub for divergent repos
  --conflict=MODE    sync conflict policy: lab (default) or report
  --json             Machine-readable audit output
  --exit-code        audit exits non-zero when drift is found
  --verbose, -v      Verbose diagnostics to stderr
EOF
}

map_github_name() { printf '%s\n' "$1"; }   # replaced in Task 2

parse_args() { CMD="help"; }                # replaced in Task 2
cmd_audit() { die "audit not implemented"; }
cmd_setup() { die "setup not implemented"; }
cmd_sync()  { die "sync not implemented"; }

main() {
  parse_args "$@"
  case "$CMD" in
    help) usage ;;
    -h|--help) usage ;;
    audit) cmd_audit ;;
    setup) cmd_setup ;;
    sync)  cmd_sync ;;
    *) printf 'mirror: unknown command: %s\n' "$CMD" >&2; usage >&2; exit 2 ;;
  esac
}

if [ "$MIRROR_NO_MAIN" != "1" ]; then
  main "$@"
fi
```

`test/helpers.sh`:

```sh
#!/bin/sh
# Shared POSIX test helpers.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() { # desc expected actual
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" != "$3" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3" >&2
  fi
}

assert_contains() { # desc needle haystack
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$3" in
    *"$2"*) : ;;
    *) TESTS_FAILED=$((TESTS_FAILED + 1))
       printf 'FAIL: %s\n  needle: [%s]\n  in:     [%s]\n' "$1" "$2" "$3" >&2 ;;
  esac
}

source_mirror() { # ROOT
  MIRROR_NO_MAIN=1
  export MIRROR_NO_MAIN
  # shellcheck disable=SC1091
  . "$1/mirror.sh"
}

report() {
  printf '  %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED" >&2
  [ "$TESTS_FAILED" -eq 0 ]
}
```

Simplify `test/cli_test.sh` to use only `assert_*`/`report` (no `check`):

```sh
out=$("$ROOT/mirror.sh" help 2>&1); assert_contains "help lists audit" "audit" "$out"
out=$("$ROOT/mirror.sh" bogus 2>&1); rc=$?; assert_eq "unknown rc" 2 "$rc"
assert_contains "unknown msg" "unknown command" "$out"
"$ROOT/mirror.sh" >/dev/null 2>&1; assert_eq "no args rc" 2 $?
out=$(MIRROR_NO_MAIN=1 sh -c '. "$1"; map_github_name Foo' sh "$ROOT/mirror.sh")
assert_eq "source guard + stub map" "Foo" "$out"
report
```

`test/run.sh`:

```sh
#!/bin/sh
set -u
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail=0
for t in "$dir"/*_test.sh; do
  printf '== %s ==\n' "$t"
  sh "$t" || fail=1
done
exit $fail
```

`test/check.sh`:

```sh
#!/bin/sh
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rc=0
sh -n "$root/mirror.sh" || rc=1
if command -v dash >/dev/null 2>&1; then dash -n "$root/mirror.sh" || rc=1; fi
if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh "$root/mirror.sh" || rc=1; fi
if command -v checkbashisms >/dev/null 2>&1; then checkbashisms -f "$root/mirror.sh" || rc=1; fi
exit $rc
```

Make test files executable: `chmod +x test/*.sh mirror.sh`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/run.sh && sh test/check.sh`
Expected: all checks pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add mirror.sh test/
git commit -m "feat: add POSIX sh skeleton, dispatch, and test harness"
```

---

### Task 2: Configuration resolution, name mapping, visibility mapping

**Files:**
- Modify: `mirror.sh`
- Create: `test/config_test.sh`
- Create: `test/fakes/gh`
- Create: `test/fakes/glab`

**Interfaces:**
- Consumes: `parse_args`, globals from Task 1.
- Produces:
  - `resolve_config()` → sets `GH_USER`, `GL_USER`, `GH_TOKEN`, `CACHE_DIR`, `GITHUB_URL_BASE`, `GITLAB_URL_BASE`, `GIT` (default `git`).
  - `map_github_name <gl_name>` → prints GitHub repo name (applies `MIRROR_MAP`).
  - `gl_to_gh_visibility <public|internal|private>` → `public|private`.
  - `gh_to_gl_visibility <PUBLIC|PRIVATE|INTERNAL>` → `public|private|internal`.
  - `parse_args "$@"` → sets `CMD`, `DRY_RUN` (0/1), `ASSUME_YES` (0/1), `FORCE_ALIGN` (0/1), `CONFLICT` (`lab|report`), `JSON_OUT` (0/1), `EXIT_CODE` (0/1), `VERBOSE` (0/1), `ONLY_LIST`/`EXCLUDE_LIST` (newline-separated).

- [ ] **Step 1: Write the failing test** (`test/config_test.sh`)

```sh
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
      sh "$ROOT/mirror.sh" audit --dry-run 2>&1); rc=$?
assert_eq "missing token rc" 1 "$rc"
assert_contains "missing token msg" "GitHub token" "$out"

report
```

`test/fakes/gh` must implement `auth token`: when `FAKE_GH_TOKEN_EMPTY=1`, print nothing and exit 1; otherwise print `${FAKE_GH_TOKEN:-ghp_fake}`.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/config_test.sh`
Expected: FAIL — `gl_to_gh_visibility` and the real `parse_args` are missing.

- [ ] **Step 3: Implement**

`parse_args`: loop over `"$@"`; first non-option token is `CMD`; handle `--only`/`--exclude` (append with trailing newline), `--conflict=X` and `--conflict X`, `--dry-run`, `--yes|-y`, `--force-align`, `--json`, `--exit-code`, `--verbose|-v`, `--help|-h` (sets `CMD=help`). Unknown `--*` → `die "unknown option: $1"`. Default `CMD=help`.

`resolve_config` (called at the start of every command from `main`):
- `GH_USER=${MIRROR_GITHUB_USER:-}`; if empty → `GH_USER=$(gh api user -q .login)`; empty → `die`.
- `GL_USER=${MIRROR_GITLAB_USER:-}`; if empty → parse `glab api user` output: `GL_USER=$(glab api user | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')`; also accept pretty JSON spacing with a second sed pattern `s/.*"username": *"\([^"]*\)".*/\1/p`. Empty → `die`.
- `GH_TOKEN=${GITHUB_TOKEN:-}`; if empty → `command -v gh >/dev/null || die "GitHub token required (set GITHUB_TOKEN)"; GH_TOKEN=$(gh auth token 2>/dev/null)`; empty → `die "GitHub token not available; run 'gh auth login' or set GITHUB_TOKEN"`.
- `CACHE_DIR=${MIRROR_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gitlab-github-mirror}`; `mkdir -p "$CACHE_DIR"`.
- `GITHUB_HOST=${MIRROR_GITHUB_HOST:-github.com}`; `GITLAB_HOST=${MIRROR_GITLAB_HOST:-gitlab.com}`.
- `GITHUB_URL_BASE=${MIRROR_GITHUB_URL_BASE:-https://$GITHUB_HOST}`; `GITLAB_URL_BASE=${MIRROR_GITLAB_URL_BASE:-https://$GITLAB_HOST}`.

`map_github_name`: if `MIRROR_MAP` is set and readable, scan lines with a `while IFS= read -r line` loop; strip `#` comments and blank lines; match field 1 exactly (`[ "$gl_name" = "$f1" ]`); print field 2; return. Otherwise print the argument.

`gl_to_gh_visibility`: `case` → `public) public;; internal|private|*) private;;` (guard unknown → `private`, and `warn`).

`gh_to_gl_visibility`: lowercase-fold manually: `case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')"` → `public) public;; private) private;; internal) internal;; *) private;;`.

`main`: after `parse_args`, if `CMD` is one of `audit|setup|sync`, call `resolve_config` before dispatching.

Test fakes:

`test/fakes/gh`:

```sh
#!/bin/sh
: "${FAKE_CALLS_LOG:=/dev/null}"
printf 'gh %s\n' "$*" >> "$FAKE_CALLS_LOG"
case "$1 $2" in
  "api user") printf '%s\n' "${FAKE_GH_USER:-tester}" ;;
  "auth token")
    if [ "${FAKE_GH_TOKEN_EMPTY:-0}" = "1" ]; then exit 1; fi
    printf '%s\n' "${FAKE_GH_TOKEN:-ghp_fake}" ;;
  "repo list") cat "${FAKE_GH_REPOS:-/dev/null}" ;;
  "repo view")
    if [ -n "${FAKE_GH_EXISTING:-}" ] && grep -qxF "$3" "$FAKE_GH_EXISTING"; then exit 0; fi
    printf 'not found\n' >&2; exit 1 ;;
  "repo create") printf 'https://github.com/%s\n' "$2" ;;
  *) printf 'fake-gh: unhandled: %s\n' "$*" >&2; exit 1 ;;
esac
```

`test/fakes/glab`:

```sh
#!/bin/sh
: "${FAKE_CALLS_LOG:=/dev/null}"
printf 'glab %s\n' "$*" >> "$FAKE_CALLS_LOG"
case "$1 $2" in
  "api user") printf '%s\n' "${FAKE_GLAB_USER_JSON:-{\"username\":\"tester\"}}" ;;
  "repo list") cat "${FAKE_GLAB_PROJECTS:-/dev/null}" ;;
  "repo create") printf 'https://gitlab.com/%s\n' "$2" ;;
  "api "*)  # endpoint in $2; see Task 4 for remote_mirrors handling
    cat "${FAKE_GLAB_API_OUT:-/dev/null}" ;;
  *) printf 'fake-glab: unhandled: %s\n' "$*" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/config_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mirror.sh test/
git commit -m "feat: config resolution, name mapping, visibility mapping"
```

---

### Task 3: `audit` — enumerate and bucket repos

**Files:**
- Modify: `mirror.sh`
- Create: `test/audit_test.sh`
- Create: `test/fixtures/gl_projects.tsv`, `test/fixtures/gh_repos.tsv`

**Interfaces:**
- Consumes: `resolve_config`, `map_github_name`.
- Produces:
  - `list_gitlab_projects()` → one line per project: `gl_name<TAB>project_id<TAB>visibility<TAB>default_branch`.
  - `list_github_repos()` → one line per repo: `gh_name<TAB>visibility` (visibility lowercased: `public|private|internal`).
  - `repo_key <name>` → lowercased key for case-insensitive matching.
  - `cmd_audit` → prints buckets.

- [ ] **Step 1: Write the failing test** (`test/audit_test.sh`)

```sh
#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"

# Fixtures: GitLab has Alpha, Beta(case mismatched vs GitHub), dot.name
printf 'Alpha\t11\tpublic\tmain\nBeta\t12\tprivate\tmain\ndot.name\t13\tpublic\tmain\n' > "$ROOT/test/fixtures/gl_projects.tsv"
# GitHub has beta (lowercase), Gamma, dot.name
printf 'beta\tprivate\nGamma\tpublic\ndot.name\tpublic\n' > "$ROOT/test/fixtures/gh_repos.tsv"

export FAKE_GLAB_PROJECTS="$ROOT/test/fixtures/gl_projects.tsv"
export FAKE_GH_REPOS="$ROOT/test/fixtures/gh_repos.tsv"
export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x
export PATH="$ROOT/test/fakes:$PATH"

out=$(sh "$ROOT/mirror.sh" audit --dry-run 2>&1)
assert_contains "GitLab-only Alpha" "GitLab only: Alpha" "$out"
assert_contains "GitHub-only Gamma" "GitHub only: Gamma" "$out"
case "$out" in *"Beta"*|*"beta"*) : ;; *) assert_eq "case-insensitive match" "Beta matched" "no match" ;; esac
# Beta/beta must NOT appear in the "only" buckets:
case "$out" in *"GitLab only: Beta"*) assert_eq "Beta not gitlab-only" "absent" "present" ;; esac
case "$out" in *"GitHub only: beta"*) assert_eq "beta not github-only" "absent" "present" ;; esac
assert_contains "dot.name treated literally" "dot.name" "$out"

report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/audit_test.sh`
Expected: FAIL — `cmd_audit` still dies "not implemented".

- [ ] **Step 3: Implement**

`repo_key`: `printf '%s' "$1" | tr 'A-Z' 'a-z'`.

`list_gitlab_projects`:

```sh
list_gitlab_projects() {
  glab repo list --mine --per-page 100 --output json \
    --jq '.[] | select(.namespace.kind == "user") | [.path, (.id|tostring), .visibility, (.default_branch // "")] | @tsv'
}
```

`list_github_repos`:

```sh
list_github_repos() {
  gh repo list "$GH_USER" --limit 1000 --json name,visibility \
    --jq '.[] | [.name, (.visibility|ascii_downcase)] | @tsv'
}
```

`cmd_audit`:
- Read `list_gitlab_projects` into a temp file `$WORK_DIR/gl.tsv`; read `list_github_repos` into `$WORK_DIR/gh.tsv`.
- Build a lookup of GitHub keys (`awk -F'\t' '{print tolower($1)}'`).
- Iterate GitLab lines with `while IFS="$(printf '\t')" read -r name id vis branch`; compute `key=$(repo_key "$name")`; if not present in GH keys → print `GitLab only: $name`; else → print nothing (Task 4 adds the "both" buckets).
- Iterate GitHub lines; if key not present in GitLab keys → print `GitHub only: $name`.
- Never `echo` unquoted JSON; use `awk`/`grep -F` for literal matching (`grep -qxF "$key"`).
- `mkdir -p "$WORK_DIR"` in `main` via `mktemp -d` and `trap 'rm -rf "$WORK_DIR"' EXIT`.

Add to `main`, before dispatch, for `audit|setup|sync`:
```sh
WORK_DIR=$(mktemp -d) || die "cannot create temp dir"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/audit_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add mirror.sh test/
git commit -m "feat: audit enumerates and buckets repos (case-insensitive)"
```

---

### Task 4: Mirror status parsing and audit integration

**Files:**
- Modify: `mirror.sh`, `test/fakes/glab`, `test/audit_test.sh`
- Create: `test/mirror_test.sh`, `test/fixtures/mirrors_{present,missing,dupes}.ndjson`

**Interfaces:**
- Consumes: `cmd_audit`, `map_github_name`, `GH_USER`.
- Produces:
  - `mirror_list <project_id>` → `id<TAB>url<TAB>enabled<TAB>last_error` per line (parsed from `glab api ... --output ndjson`).
  - `mirror_status <project_id> <gh_name>` → one of `ok|disabled|error|missing`, printed to stdout.

- [ ] **Step 1: Write the failing test** (`test/mirror_test.sh`)

```sh
#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"
source_mirror "$ROOT"
GH_USER=u

# present + healthy
FAKE_GLAB_API_OUT="$ROOT/test/fixtures/mirrors_present.ndjson"
export FAKE_GLAB_API_OUT
PATH="$ROOT/test/fakes:$PATH"; export PATH
assert_eq "healthy mirror" ok "$(mirror_status 11 proj)"

# disabled
FAKE_GLAB_API_OUT="$ROOT/test/fixtures/mirrors_disabled.ndjson"; export FAKE_GLAB_API_OUT
assert_eq "disabled mirror" disabled "$(mirror_status 11 proj)"

# missing (no mirror to github)
FAKE_GLAB_API_OUT="$ROOT/test/fixtures/mirrors_missing.ndjson"; export FAKE_GLAB_API_OUT
assert_eq "missing mirror" missing "$(mirror_status 11 proj)"

# metacharacter repo name must be matched literally
FAKE_GLAB_API_OUT="$ROOT/test/fixtures/mirrors_present.ndjson"; export FAKE_GLAB_API_OUT
assert_eq "dot name literal" ok "$(mirror_status 11 'proj.name')"

report
```

Fixtures (`ndjson`, compact, one object per line). `mirrors_present.ndjson`:
```
{"id":101,"enabled":true,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}
{"id":102,"enabled":true,"url":"https://*****:*****@github.com/u/proj.name.git","last_error":null}
```
`mirrors_disabled.ndjson`:
```
{"id":101,"enabled":false,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}
```
`mirrors_missing.ndjson`:
```
{"id":101,"enabled":true,"url":"https://*****:*****@gitlab.com/other/proj.git","last_error":null}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/mirror_test.sh`
Expected: FAIL — `mirror_list`/`mirror_status` undefined.

- [ ] **Step 3: Implement**

Update `test/fakes/glab` `api `* branch to honor `--output ndjson` and `--input` (see Task 6); for now it must output `$FAKE_GLAB_API_OUT` for GETs.

```sh
mirror_list() { # project_id
  glab api "projects/$1/remote_mirrors" --output ndjson 2>/dev/null |
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    mid=$(printf '%s' "$obj"  | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    url=$(printf '%s' "$obj"  | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    en=$(printf  '%s' "$obj"  | sed -n 's/.*"enabled":\(true\|false\).*/\1/p')
    err=$(printf '%s' "$obj"  | sed -n 's/.*"last_error":\("[^"]*"\|null\).*/\1/p')
    printf '%s\t%s\t%s\t%s\n' "$mid" "$url" "$en" "$err"
  done
}

mirror_status() { # project_id gh_name
  target="github.com/$GH_USER/$2.git"
  status=missing
  mirror_list "$1" | while IFS="$(printf '\t')" read -r mid url en err; do
    case "$url" in
      *"$target"*)
        if [ "$en" = "true" ] && { [ "$err" = "null" ] || [ -z "$err" ]; }; then status=ok; else
          if [ "$err" != "null" ] && [ -n "$err" ]; then status=error; else status=disabled; fi
        fi ;;
    esac
  done
  printf '%s\n' "$status"
}
```

Note: the `while ... |` loop runs in a subshell, so accumulate with a command substitution instead:

```sh
mirror_status() {
  target="github.com/$GH_USER/$2.git"
  found=$(mirror_list "$1" | awk -F'\t' -v t="$target" 'index($2,t){print $3"\t"$4; exit}')
  [ -n "$found" ] || { printf 'missing\n'; return; }
  en=${found%%"$(printf '\t')"*}
  err=${found#*"$(printf '\t')"}
  if [ "$en" = "true" ] && { [ "$err" = "null" ] || [ -z "$err" ]; }; then
    printf 'ok\n'
  elif [ "$err" != "null" ] && [ -n "$err" ]; then
    printf 'error\n'
  else
    printf 'disabled\n'
  fi
}
```

`awk index()` performs a literal substring search, avoiding regex metacharacter issues.

`cmd_audit` additions: for each both-present repo, call `mirror_status "$id" "$(map_github_name "$name")"` and print `no push mirror: X` / `push mirror disabled: X` / `push mirror error: X`. Cases 1 and 2 of Review Focus are pinned here (case-insensitive match, metacharacter names).

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/mirror_test.sh && sh test/audit_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add mirror.sh test/
git commit -m "feat: parse and report GitLab push mirror status in audit"
```

---

### Task 5: `setup` plan generation (dry-run)

**Files:**
- Modify: `mirror.sh`
- Create: `test/setup_test.sh`, `test/fixtures/gl_empty.tsv`

**Interfaces:**
- Consumes: `list_gitlab_projects`, `list_github_repos`, `mirror_status`, `map_github_name`, visibility mappers.
- Produces: `plan_setup` → prints one **space-separated** action line per repo (no side effects): `create-github <name> <visibility>`, `create-gitlab <name> <visibility>`, `seed-gitlab <name>`, `configure-mirror <name> <project_id>`, `skip <name> <reason>`, `align <name>`. Repo names contain no spaces, so spaces are a safe separator. `cmd_setup` prints these and, when `DRY_RUN=1`, stops.

- [ ] **Step 1: Write the failing test** (`test/setup_test.sh`)

```sh
#!/bin/sh
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

report
```

Note: the fake `glab repo list` returns the fixture verbatim; mirror lookups all use `FAKE_GLAB_API_OUT`, so the Alpha "ok" case needs the fixture to contain Alpha's URL. To test multiple statuses, the fake `glab` may select a fixture by project id via a small case (documented in the fake).

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/setup_test.sh`
Expected: FAIL — `plan_setup` undefined / `cmd_setup` dies.

- [ ] **Step 3: Implement `plan_setup`**

Algorithm:
1. Load GL and GH maps.
2. For each GL project:
   - gh_name=`map_github_name "$name"`.
   - If GH missing → print `create-github\t$gh_name\t$(gl_to_gh_visibility "$vis")`, then `configure-mirror\t$name\t$id` (the new repo will exist after apply).
   - Else: `st=$(mirror_status "$id" "$gh_name")`; `case $st` → `missing`/`disabled`/`error` → `configure-mirror\t$name\t$id`; `ok` → nothing.
3. For each GH-only repo → `create-gitlab\t$name\t$(gh_to_gl_visibility "$vis")`, then `seed-gitlab\t$name`.
4. Never print a plan line for a repo matched case-insensitively to an existing counterpart.
5. Empty GL projects (blank `default_branch`) still get `configure-mirror` and are not treated as errors (Review Focus 3).

`cmd_setup`: collect `plan_setup`; print header + lines; if `DRY_RUN=1` → print "dry run; no changes" and return 0; else apply (Task 6).

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test/setup_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add mirror.sh test/
git commit -m "feat: setup plan generation (dry-run) with empty-repo handling"
```

---

### Task 6: `setup` apply — create repos, seed, configure push mirrors

**Files:**
- Modify: `mirror.sh`, `test/fakes/gh`, `test/fakes/glab`, `test/setup_test.sh`

**Interfaces:**
- Consumes: `plan_setup`, globals, `GH_TOKEN`.
- Produces:
  - `run <cmd...>` → prints the command (masking the token) and executes it unless `DRY_RUN=1`.
  - `create_github_repo <name> <visibility>`.
  - `create_gitlab_project <name> <visibility>`.
  - `seed_gitlab_from_github <name>`.
  - `ensure_push_mirror <project_id> <gh_name>`.
  - `apply_setup` (reads a plan and executes each action).
  - `confirm_or_abort` → if `ASSUME_YES=1` returns 0; else prompts on the terminal; non-interactive without `--yes` → `die`.

- [ ] **Step 1: Write the failing test** (extend `test/setup_test.sh`)

```sh
# apply
export GIT="$ROOT/test/fakes/git"
: > "$FAKE_CALLS_LOG"; : > "$ROOT/test/fixtures/git.log"; : > "$ROOT/test/fixtures/body.log"
sh "$ROOT/mirror.sh" setup --yes >/dev/null 2>&1
calls=$(cat "$FAKE_CALLS_LOG")
assert_contains "created GitLab project Gamma" "glab repo create Gamma" "$calls"
assert_contains "seeded from github" "clone" "$(cat "$ROOT/test/fixtures/git.log")"
assert_contains "configured mirror Empty" "glab api -X POST projects/12/remote_mirrors" "$calls"
body=$(cat "$ROOT/test/fixtures/body.log")
assert_contains "mirror url" "github.com/u/Empty.git" "$body"
assert_contains "keep divergent" '"keep_divergent_refs":true' "$body"
assert_contains "enabled" '"enabled":true' "$body"

report
```

Extend the fakes:
- `test/fakes/gh`: log to `$FAKE_CALLS_LOG`; `repo create` prints a URL.
- `test/fakes/glab`: handle `repo create`; for `api projects/<id>/remote_mirrors` with `-X POST`, read the `--input` file (find the argument after `--input`) and append its contents to `$FAKE_BODY_LOG`, print `{}`; for GET print `$FAKE_GLAB_API_OUT`.
- `test/fakes/git`: append its arguments to `$FAKE_GIT_LOG` and exit 0. Tests point `GIT` at it to observe seeding without real network. `seed_gitlab_from_github` uses `run "$GIT" ...`, and `run` masks credentials in its printed form.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/setup_test.sh`
Expected: FAIL — `apply_setup` undefined.

- [ ] **Step 3: Implement**

`run`:
```sh
run() {
  printf '+ %s\n' "$(printf '%s ' "$@" | sed 's#://[^/@]*@#://***@#g')" >&2   # mask creds
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}
```

`create_github_repo`:
```sh
case "$2" in public) v=--public ;; *) v=--private ;; esac
run gh repo create "$GH_USER/$1" "$v"
```

`create_gitlab_project`:
```sh
case "$2" in public) v=--public ;; private) v=--private ;; internal) v=--internal ;; *) v=--private ;; esac
run glab repo create "$1" "$v" --skipGitInit
```

`seed_gitlab_from_github` (uses `$GIT`, default `git`):
```sh
d="$WORK_DIR/$1.git"
run "$GIT" clone --bare --quiet "$GITHUB_URL_BASE/$GH_USER/$1.git" "$d"
run "$GIT" -C "$d" push --mirror "$GITLAB_URL_BASE/$GL_USER/$1.git"
```

`ensure_push_mirror` (token kept out of argv via `--input`):
```sh
tmp="$WORK_DIR/mirror-body.json"; ( umask 077; : > "$tmp" )
cat > "$tmp" <<EOF
{"url":"https://$GH_USER:$GH_TOKEN@github.com/$GH_USER/$2.git","enabled":true,"auth_method":"password","only_protected_branches":false,"keep_divergent_refs":true}
EOF
run glab api -X POST "projects/$1/remote_mirrors" --input "$tmp"
```
If `mirror_status "$1" "$2"` is already `ok`, skip (idempotency). If `disabled`/`error`, look up the existing mirror id from `mirror_list "$1"` (the line whose `url` contains `github.com/$GH_USER/$2.git`) and update it instead of creating a duplicate:
```sh
mid=$(mirror_list "$1" | awk -F'\t' -v t="github.com/$GH_USER/$2.git" 'index($2,t){print $1; exit}')
run glab api -X PUT "projects/$1/remote_mirrors/$mid" --input "$tmp"
```

`apply_setup`: run `plan_setup` into a temp file; for each action, dispatch; skip actions already satisfied at apply time (re-check) to keep re-runs idempotent. Before applying, `confirm_or_abort`. Missing/invalid token already fails in `resolve_config` (Review Focus 4); additionally verify `gh api user` succeeds before mutations.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/setup_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add mirror.sh test/
git commit -m "feat: apply setup (create repos, seed, configure push mirrors)"
```

---

### Task 7: `sync` core — fetch and fast-forward rescue

**Files:**
- Modify: `mirror.sh`
- Create: `test/sync_test.sh`

**Interfaces:**
- Consumes: `resolve_config`, `$GIT`, URL bases.
- Produces:
  - `cache_repo_dir <name>` → `$CACHE_DIR/<name>.git`.
  - `cache_ensure <name>` → inits bare cache with `github`/`gitlab` remotes.
  - `sync_repo <name>` → prints actions; returns non-zero on failure; uses conflict policy (Task 8).
  - `cmd_sync` → iterates managed repos from `list_gitlab_projects`.

- [ ] **Step 1: Write the failing test** (`test/sync_test.sh`)

```sh
#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"

work=$(mktemp -d)
mkdir -p "$work/github/u" "$work/gitlab/u"
git -c init.defaultBranch=main init --bare "$work/github/u/proj.git" >/dev/null
git -c init.defaultBranch=main init --bare "$work/gitlab/u/proj.git" >/dev/null

# seed github with a commit
seed=$(mktemp -d)
git -C "$seed" -c init.defaultBranch=main init -q
git -C "$seed" -c user.email=a@b -c user.name=a commit -q --allow-empty -m one
git -C "$seed" push -q "$work/github/u/proj.git" main

export MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u GITHUB_TOKEN=x
export MIRROR_GITHUB_URL_BASE="file://$work/github"
export MIRROR_GITLAB_URL_BASE="file://$work/gitlab"
export MIRROR_CACHE="$work/cache"
export PATH="$ROOT/test/fakes:$PATH"
# glab fake needs to report one project and a healthy mirror for config/audit calls
printf 'proj\t1\tprivate\tmain\n' > "$work/gl.tsv"
printf '{"id":9,"enabled":true,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}\n' > "$work/mir.ndjson"
export FAKE_GLAB_PROJECTS="$work/gl.tsv" FAKE_GLAB_API_OUT="$work/mir.ndjson"

sh "$ROOT/mirror.sh" sync --yes --only proj >/dev/null 2>&1

git -C "$work/gitlab/u/proj.git" rev-parse --verify main >/dev/null 2>&1
assert_eq "github commit rescued into gitlab" 0 $?
assert_eq "same commit" \
  "$(git -C "$work/github/u/proj.git" rev-parse main)" \
  "$(git -C "$work/gitlab/u/proj.git" rev-parse main)"

rm -rf "$work" "$seed"
report
```

The script builds remote URLs as `$MIRROR_GITHUB_URL_BASE/$GH_USER/<name>.git`, so the fixture layout is `$work/github/u/proj.git` and `$work/gitlab/u/proj.git`.

The fake `glab` for this test must make `repo list` return `proj` with id and `--only proj` restricts to it; set `FAKE_GLAB_PROJECTS` to a fixture `proj\t1\tprivate\tmain`, and `FAKE_GLAB_API_OUT` to a healthy mirror fixture so config/audit calls don't fail.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/sync_test.sh`
Expected: FAIL — `cmd_sync` dies "not implemented".

- [ ] **Step 3: Implement**

`cache_ensure`:
```sh
d=$(cache_repo_dir "$1")
if [ ! -d "$d" ]; then
  "$GIT" init --bare -q "$d"
  "$GIT" -C "$d" remote add github "$GITHUB_URL_BASE/$GH_USER/$1.git"
  "$GIT" -C "$d" remote add gitlab "$GITLAB_URL_BASE/$GL_USER/$1.git"
fi
```

`sync_repo`:
```sh
d=$(cache_repo_dir "$1"); cache_ensure "$1"
run "$GIT" -C "$d" fetch --prune --quiet github '+refs/heads/*:refs/remotes/github/*' '+refs/tags/*:refs/gh-tags/*'
run "$GIT" -C "$d" fetch --prune --quiet gitlab '+refs/heads/*:refs/remotes/gitlab/*' '+refs/tags/*:refs/gl-tags/*'

"$GIT" -C "$d" for-each-ref --format='%(refname)' refs/remotes/github/ |
while IFS= read -r ref; do
  b=${ref#refs/remotes/github/}
  if ! "$GIT" -C "$d" rev-parse --verify -q "refs/remotes/gitlab/$b" >/dev/null; then
    run "$GIT" -C "$d" push --quiet gitlab "$ref:refs/heads/$b"
  elif "$GIT" -C "$d" merge-base --is-ancestor "refs/remotes/gitlab/$b" "$ref"; then
    run "$GIT" -C "$d" push --quiet gitlab "$ref:refs/heads/$b"
  else
    handle_conflict "$1" "$b"
  fi
done

# tags: push missing/differing per policy
...
```

Key detail: the `for-each-ref | while` loop runs in a subshell; `run` mutations still happen (they are external commands), so that is acceptable. Failures must be tracked: write failures to `$WORK_DIR/failed` and check after the loop.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/sync_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add mirror.sh test/
git commit -m "feat: sync fast-forwards GitHub-side commits into GitLab"
```

---

### Task 8: `sync` conflict policy, `--force-align`, and lock

**Files:**
- Modify: `mirror.sh`
- Modify: `test/sync_test.sh`

**Interfaces:**
- Consumes: `sync_repo`, `CONFLICT`, `FORCE_ALIGN`.
- Produces: `handle_conflict <name> <branch>`; `acquire_lock`/`release_lock`; `force_align <name>`.

- [ ] **Step 1: Write the failing test** (extend `test/sync_test.sh`)

```sh
# Build a divergence in a fresh pair of bare repos:
#   common -> gitlab gets commit L, github gets commit G
w2=$(mktemp -d); mkdir -p "$w2/github/u" "$w2/gitlab/u"
git -c init.defaultBranch=main init --bare "$w2/github/u/proj.git" >/dev/null
git -c init.defaultBranch=main init --bare "$w2/gitlab/u/proj.git" >/dev/null

s=$(mktemp -d); git -C "$s" -c init.defaultBranch=main init -q
git -C "$s" -c user.email=a@b -c user.name=a commit -q --allow-empty -m base
git -C "$s" push -q "$w2/github/u/proj.git" main
git -C "$s" push -q "$w2/gitlab/u/proj.git" main
# gitlab side commit L
git -C "$s" -c user.email=a@b -c user.name=a commit -q --allow-empty -m L
git -C "$s" push -q "$w2/gitlab/u/proj.git" main
L=$(git -C "$w2/gitlab/u/proj.git" rev-parse main)
# github side commit G (from the common base)
git -C "$s" -c user.email=a@b -c user.name=a reset -q --hard HEAD~1
git -C "$s" -c user.email=a@b -c user.name=a commit -q --allow-empty -m G
git -C "$s" push -q --force "$w2/github/u/proj.git" main
G=$(git -C "$w2/github/u/proj.git" rev-parse main)

export MIRROR_GITHUB_URL_BASE="file://$w2/github" MIRROR_GITLAB_URL_BASE="file://$w2/gitlab"
export MIRROR_CACHE="$w2/cache"
export GITHUB_TOKEN=x MIRROR_GITHUB_USER=u MIRROR_GITLAB_USER=u
printf 'proj\t1\tprivate\tmain\n' > "$w2/gl.tsv"
printf '{"id":9,"enabled":true,"url":"https://*****:*****@github.com/u/proj.git","last_error":null}\n' > "$w2/mir.ndjson"
export FAKE_GLAB_PROJECTS="$w2/gl.tsv" FAKE_GLAB_API_OUT="$w2/mir.ndjson"

sh "$ROOT/mirror.sh" sync --yes --only proj --conflict=report >/dev/null 2>&1
assert_eq "report leaves gitlab alone"   "$L" "$(git -C "$w2/gitlab/u/proj.git" rev-parse main)"
assert_eq "report leaves github alone"   "$G" "$(git -C "$w2/github/u/proj.git" rev-parse main)"
out=$(sh "$ROOT/mirror.sh" sync --yes --only proj 2>&1)   # default: lab wins
assert_contains "gitlab wins on conflict" "conflict" "$out"
assert_eq "github forced to gitlab"      "$L" "$(git -C "$w2/github/u/proj.git" rev-parse main)"

# lock: a pre-existing lock makes sync refuse
rm -rf "$MIRROR_CACHE"
mkdir -p "$MIRROR_CACHE/.sync.lock"
out=$(sh "$ROOT/mirror.sh" sync --yes 2>&1); rc=$?
assert_eq "locked rc" 1 "$rc"
assert_contains "locked msg" "already running" "$out"
rmdir "$MIRROR_CACHE/.sync.lock"

rm -rf "$w2" "$s"
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test/sync_test.sh`
Expected: FAIL — `handle_conflict` undefined.

- [ ] **Step 3: Implement**

`handle_conflict`:
```sh
case "$CONFLICT" in
  report) warn "conflict on $1/$2 (GitLab kept; GitHub not changed)"; return 0 ;;
  lab)
    warn "conflict on $1/$2: GitLab wins; force-updating GitHub"
    run "$GIT" -C "$(cache_repo_dir "$1")" push --force github \
      "refs/remotes/gitlab/$2:refs/heads/$2"
    ;;
  *) die "invalid --conflict: $CONFLICT" ;;
esac
```

`force_align <name>`: same as the `lab` branch but for every divergent ref, driven by `--force-align` during setup or sync.

Lock (acquired in `cmd_sync` only):
```sh
acquire_lock() {
  mkdir "$CACHE_DIR/.sync.lock" 2>/dev/null || die "sync already running (lock: $CACHE_DIR/.sync.lock)"
}
release_lock() { rmdir "$CACHE_DIR/.sync.lock" 2>/dev/null || :; }
```
Register `release_lock` in the `trap` alongside temp cleanup (Review Focus 5).

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh test/sync_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add mirror.sh test/
git commit -m "feat: sync conflict policy (GitLab wins/report), force-align, lock"
```

---

### Task 9: Documentation, scheduling examples, final validation

**Files:**
- Create: `README.md`
- Create: `systemd/mirror-sync.service`, `systemd/mirror-sync.timer`

**Interfaces:**
- Consumes: the finished CLI.
- Produces: user-facing docs.

- [ ] **Step 1: Write `README.md`**

Sections: what it does and why (Free-tier constraint); prerequisites (`gh auth login`, `glab auth login`, GitHub token scopes — fine-grained `contents:write`, plus `Workflows` if repos contain `.github/workflows`); install (copy `mirror.sh`); usage for `audit`/`setup`/`sync` and every flag; configuration table (all `MIRROR_*` vars); the GitLab-canonical model and the safety-net explanation; **caveats** (only clean GitHub-side commits are rescued, GitLab wins conflicts, no issues/MRs/wikis mirrored, `--force-align` is destructive to GitHub refs); cron example:

```
*/15 * * * * /usr/local/bin/mirror.sh sync --yes >>"$HOME/.cache/gitlab-github-mirror/sync.log" 2>&1
```

- [ ] **Step 2: Write systemd units**

`mirror-sync.service` (oneshot, `ExecStart=/usr/local/bin/mirror.sh sync --yes`) and `mirror-sync.timer` (e.g. `OnCalendar=*:0/15`, `Persistent=true`).

- [ ] **Step 3: Run the full suite and portability gate**

Run: `sh test/run.sh && sh test/check.sh`
Expected: all pass, exit 0. Confirm `dash`, `shellcheck`, and `checkbashisms` are exercised (install/mark skipped if absent, but at minimum `sh -n` and, where available, `dash -n`).

- [ ] **Step 4: Live smoke test (manual, read-only)**

Run: `./mirror.sh audit --dry-run`
Expected: a drift report for the real accounts; no mutations. (Requires `gh`/`glab` authenticated.)

- [ ] **Step 5: Commit**

```bash
git add README.md systemd/
git commit -m "docs: add README, cron/systemd examples; final checks"
```

---

## Self-Review

**1. Spec coverage**
- Problem/research/choice of GitLab hub → Tasks 3–8 realize it; README (Task 9) documents caveats.
- Goals: audit (3,4), reconcile/create (5,6), push mirror (6), safety net (7), safe/idempotent (6,8), portability (1,9).
- Non-goals respected: no issues/MRs/wikis, personal namespaces only, no daemon.
- Config/auth table → Task 2; `MIRROR_MAP` format → Task 2; host/URL bases → Task 2.
- CLI/flags/exit codes → Tasks 1,2; `--force-align`/`--conflict` → Task 8.
- Push mirror exact params → Task 6.
- Sync policy and why → Task 7,8.
- Scheduling → Task 9.
- Error handling/safety → Tasks 2,6,8.
- Testing strategy → harness in Tasks 1,3,4,6,7 and `check.sh` in 1,9.
- Deliverables → all tasks.

**2. Step scan** — each step yields one action with a checkable result; code bodies appear only where the algorithm is not implied by signature + test (the `sed`/`awk` parsers, the ancestry decision).

**3. Type consistency** — function names used across tasks match their Task definitions (`map_github_name`, `mirror_status`, `mirror_list`, `plan_setup`, `ensure_push_mirror`, `cache_repo_dir`, `handle_conflict`, `acquire_lock`/`release_lock`). Data shapes: project TSV `name<TAB>id<TAB>visibility<TAB>branch`; mirror TSV `id<TAB>url<TAB>enabled<TAB>last_error`; plan lines `action arg...` (space-separated).

**4. Review Focus** — each of the six items has a test in its owning task (Tasks 2,3,4,5,6,8).

**5. Proportion** — the plan is task/step oriented; code blocks are signatures, parsers, and test assertions rather than full program transcripts.

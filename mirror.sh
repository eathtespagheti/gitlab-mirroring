#! /bin/sh
# mirror.sh - reconcile a personal GitLab and GitHub account and keep them mirrored.
LC_ALL=C
export LC_ALL
: "${MIRROR_NO_MAIN:=0}"

# Global option state. Defaults are declared here so the Task 1 interface
# contract holds; Task 2's parse_args overwrites them with parsed values.
: "${CMD:=}"
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${FORCE_ALIGN:=0}"
: "${CONFLICT:=lab}"
: "${JSON_OUT:=0}"
: "${EXIT_CODE:=0}"
: "${VERBOSE:=0}"
: "${ONLY_LIST:=}"
: "${EXCLUDE_LIST:=}"

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

# map_github_name <gl_name>: print the GitHub repo name for a GitLab repo name.
# An optional MIRROR_MAP file overrides the default same-name mapping; its
# format is "<gitlab-name> <github-name> [visibility]", with blank lines and
# '#' comment lines ignored.
map_github_name() {
  gl_name=$1
  if [ -n "${MIRROR_MAP:-}" ] && [ -r "$MIRROR_MAP" ]; then
    while IFS= read -r line; do
      case "$line" in
        '' | \#*) continue ;;
      esac
      # Unquoted $line is deliberate: split into whitespace-separated fields.
      # shellcheck disable=SC2086
      set -- $line
      [ -n "${1:-}" ] || continue
      if [ "$gl_name" = "$1" ]; then
        printf '%s\n' "${2:-$gl_name}"
        return 0
      fi
    done < "$MIRROR_MAP"
  fi
  printf '%s\n' "$gl_name"
}

gl_to_gh_visibility() { # public|internal|private
  case "$1" in
    public) printf 'public\n' ;;
    internal | private) printf 'private\n' ;;
    *) warn "unknown GitLab visibility '$1'; treating as private"; printf 'private\n' ;;
  esac
}

gh_to_gl_visibility() { # PUBLIC|PRIVATE|INTERNAL (case-insensitive)
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    public) printf 'public\n' ;;
    private) printf 'private\n' ;;
    internal) printf 'internal\n' ;;
    *) printf 'private\n' ;;
  esac
}

parse_args() {
  CMD=''
  DRY_RUN=0
  ASSUME_YES=0
  FORCE_ALIGN=0
  CONFLICT='lab'
  JSON_OUT=0
  EXIT_CODE=0
  VERBOSE=0
  ONLY_LIST=''
  EXCLUDE_LIST=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes | -y) ASSUME_YES=1 ;;
      --force-align) FORCE_ALIGN=1 ;;
      --conflict=*) CONFLICT=${1#--conflict=} ;;
      --conflict)
        shift
        [ "$#" -gt 0 ] || die "missing value for --conflict"
        CONFLICT=$1 ;;
      --json) JSON_OUT=1 ;;
      --exit-code) EXIT_CODE=1 ;;
      --verbose | -v) VERBOSE=1 ;;
      --help | -h) CMD=help ;;
      --only)
        shift
        [ "$#" -gt 0 ] || die "missing value for --only"
        ONLY_LIST="${ONLY_LIST}$1
" ;;
      --exclude)
        shift
        [ "$#" -gt 0 ] || die "missing value for --exclude"
        EXCLUDE_LIST="${EXCLUDE_LIST}$1
" ;;
      --*) die "unknown option: $1" ;;
      *) if [ -z "$CMD" ]; then CMD=$1; fi ;;
    esac
    shift
  done
}

# resolve_config: fill GH_USER, GL_USER, GH_TOKEN, CACHE_DIR, the URL bases and
# GIT. The token is resolved (and its absence fatal) before the cache directory
# is created, so a missing-token run touches no directories. Secrets are never
# printed.
resolve_config() {
  GH_USER=${MIRROR_GITHUB_USER:-}
  if [ -z "$GH_USER" ]; then
    GH_USER=$(gh api user -q .login 2>/dev/null || true)
    [ -n "$GH_USER" ] || die "could not determine GitHub user; set MIRROR_GITHUB_USER"
  fi

  GL_USER=${MIRROR_GITLAB_USER:-}
  if [ -z "$GL_USER" ]; then
    gl_user_json=$(glab api user 2>/dev/null || true)
    GL_USER=$(printf '%s\n' "$gl_user_json" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
    if [ -z "$GL_USER" ]; then
      GL_USER=$(printf '%s\n' "$gl_user_json" | sed -n 's/.*"username": *"\([^"]*\)".*/\1/p')
    fi
    [ -n "$GL_USER" ] || die "could not determine GitLab user; set MIRROR_GITLAB_USER"
  fi

  GH_TOKEN=${GITHUB_TOKEN:-}
  if [ -z "$GH_TOKEN" ]; then
    command -v gh >/dev/null 2>&1 || die "GitHub token required (set GITHUB_TOKEN)"
    GH_TOKEN=$(gh auth token 2>/dev/null || true)
    [ -n "$GH_TOKEN" ] || die "GitHub token not available; run 'gh auth login' or set GITHUB_TOKEN"
  fi

  CACHE_DIR=${MIRROR_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gitlab-github-mirror}
  mkdir -p "$CACHE_DIR" || die "cannot create cache dir: $CACHE_DIR"

  GITHUB_HOST=${MIRROR_GITHUB_HOST:-github.com}
  GITLAB_HOST=${MIRROR_GITLAB_HOST:-gitlab.com}
  # URL bases are part of the resolved-config interface; consumed by later tasks.
  # shellcheck disable=SC2034
  GITHUB_URL_BASE=${MIRROR_GITHUB_URL_BASE:-https://$GITHUB_HOST}
  # shellcheck disable=SC2034
  GITLAB_URL_BASE=${MIRROR_GITLAB_URL_BASE:-https://$GITLAB_HOST}
  GIT=${GIT:-git}
}

# repo_key <name>: lowercase key used for case-insensitive host matching.
repo_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# mirror_list <project_id>: print one line per push mirror configured on the
# GitLab project as id<TAB>url<TAB>enabled<TAB>last_error. GitLab returns
# compact NDJSON; fields are extracted with awk (no jq, POSIX only). The
# credentials in url are scrubbed by GitLab to https://*****:*****@host/..., so
# only the host/path fragment is ever used. Missing fields stay empty. Returns
# non-zero (after a warning) when the API call itself fails, so callers can tell
# "no mirrors" apart from "could not ask".
mirror_list() {
  if ! api_out=$(glab api "projects/$1/remote_mirrors" --output ndjson 2>/dev/null); then
    warn "could not query mirrors for project $1"
    return 1
  fi
  printf '%s\n' "$api_out" | awk '
    {
      id = ""; url = ""; en = ""; err = ""
      if (match($0, /"id":[0-9]+/))                 id  = substr($0, RSTART + 5,  RLENGTH - 5)
      if (match($0, /"url":"[^"]*"/))               url = substr($0, RSTART + 7,  RLENGTH - 8)
      if (match($0, /"enabled":(true|false)/))      en  = substr($0, RSTART + 10, RLENGTH - 10)
      if (match($0, /"last_error":("[^"]*"|null)/)) err = substr($0, RSTART + 13, RLENGTH - 13)
      if (id != "") printf "%s\t%s\t%s\t%s\n", id, url, en, err
    }
  '
}

# mirror_match <project_id> <gh_name>: print "<status><TAB><count>" for the push
# mirrors targeting @github.com/$GH_USER/<gh_name>.git, or return non-zero when
# the API could not be queried. The target is matched literally with awk index()
# (repo names may contain sed/glob metacharacters like . + [ *), never with a
# regex, case-insensitively (GitLab MyApp may mirror to GitHub myapp), and is
# anchored on "@github.com/" so a lookalike host such as "@mygithub.com" cannot
# match. When several mirrors match, the healthiest status wins:
# ok > error > disabled.
mirror_match() {
  target="@github.com/$GH_USER/$2.git"
  if ! mirrors=$(mirror_list "$1"); then
    return 1
  fi
  printf '%s\n' "$mirrors" | awk -F'\t' -v t="$target" '
    BEGIN { t = tolower(t); best = 0; n = 0 }
    index(tolower($2), t) {
      n++
      if ($3 == "true" && ($4 == "null" || $4 == "")) r = 3
      else if ($4 != "null" && $4 != "") r = 2
      else r = 1
      if (r > best) best = r
    }
    END {
      if (best == 3) s = "ok"
      else if (best == 2) s = "error"
      else if (best == 1) s = "disabled"
      else s = "missing"
      printf "%s\t%d\n", s, n
    }
  '
}

# mirror_status <project_id> <gh_name>: print ok|disabled|error|missing for the
# push mirror that targets @github.com/$GH_USER/<gh_name>.git. An API failure is
# reported as error, never as missing.
mirror_status() {
  if ! match=$(mirror_match "$1" "$2"); then
    printf 'error\n'
    return 0
  fi
  printf '%s\n' "${match%%"$(printf '\t')"*}"
}

# list_gitlab_projects: one line per project in the user namespace:
#   gl_name<TAB>project_id<TAB>visibility<TAB>default_branch
list_gitlab_projects() {
  glab repo list --mine --per-page 100 --output json \
    --jq '.[] | select(.namespace.kind == "user") | [.path, (.id|tostring), .visibility, (.default_branch // "")] | @tsv'
}

# list_github_repos: one line per repo: gh_name<TAB>lowercased-visibility
list_github_repos() {
  gh repo list "$GH_USER" --limit 1000 --json name,visibility \
    --jq '.[] | [.name, (.visibility|ascii_downcase)] | @tsv'
}

# cmd_audit: enumerate both hosts and print the drift buckets. Read-only.
# Matching is case-insensitive and literal (never regex).
cmd_audit() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  mkdir -p "$WORK_DIR" || die "cannot create work dir"
  gl_file=$WORK_DIR/gl.tsv
  gh_file=$WORK_DIR/gh.tsv
  gl_keys=$WORK_DIR/gl.keys
  gh_keys=$WORK_DIR/gh.keys

  list_gitlab_projects > "$gl_file" || die "failed to list GitLab projects"
  list_github_repos > "$gh_file" || die "failed to list GitHub repositories"

  # Lowercased key sets for case-insensitive membership tests. awk tolower keeps
  # this literal; no regex is involved.
  awk -F'\t' 'NF { print tolower($1) }' "$gl_file" > "$gl_keys"
  awk -F'\t' 'NF { print tolower($1) }' "$gh_file" > "$gh_keys"

  while IFS="$(printf '\t')" read -r name _ _ _; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    if ! grep -qxF -- "$key" "$gh_keys"; then
      info "GitLab only: $name"
    fi
  done < "$gl_file"

  while IFS="$(printf '\t')" read -r name _; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    if ! grep -qxF -- "$key" "$gl_keys"; then
      info "GitHub only: $name"
    fi
  done < "$gh_file"

  # Both-present repos: report push-mirror health and pre-existing duplicates.
  # Read-only; one API call per project. The target match is literal,
  # case-insensitive, and anchored on "@github.com/"; extra mirrors are reported
  # (never deleted).
  while IFS="$(printf '\t')" read -r name id _ _; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    grep -qxF -- "$key" "$gh_keys" || continue
    if matches=$(mirror_match "$id" "$(map_github_name "$name")"); then
      status=${matches%%"$(printf '\t')"*}
      count=${matches#*"$(printf '\t')"}
      case "$status" in
        missing)  info "no push mirror: $name" ;;
        disabled) info "push mirror disabled: $name" ;;
        error)    info "push mirror error: $name" ;;
      esac
      if [ "$count" -gt 1 ]; then
        info "duplicate push mirrors: $name ($count)"
      fi
    else
      # The API call failed and already warned; never claim there is no mirror.
      info "push mirror error: $name"
    fi
  done < "$gl_file"
}

# plan_setup: print the reconcile plan, one space-separated action per line
# (ruling 2; repo names contain no spaces):
#   create-github <gh_name> <visibility>
#   configure-mirror <name> <project_id>
#   create-gitlab <name> <visibility>
#   seed-gitlab <name>
# Pure: read-only API calls only, no mutations. An empty GitLab project (blank
# default_branch) still gets a mirror configured and is never an error.
plan_setup() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  mkdir -p "$WORK_DIR" || die "cannot create work dir"
  pgl_file=$WORK_DIR/setup.gl.tsv
  pgh_file=$WORK_DIR/setup.gh.tsv
  pgl_keys=$WORK_DIR/setup.gl.keys
  pgh_keys=$WORK_DIR/setup.gh.keys
  pmapped_keys=$WORK_DIR/setup.mapped.keys

  list_gitlab_projects > "$pgl_file" || die "failed to list GitLab projects"
  list_github_repos > "$pgh_file" || die "failed to list GitHub repositories"

  # Lowercased key sets; matching is literal (grep -F), never regex.
  awk -F'\t' 'NF { print tolower($1) }' "$pgl_file" > "$pgl_keys"
  awk -F'\t' 'NF { print tolower($1) }' "$pgh_file" > "$pgh_keys"
  # Every GitHub name a GitLab project already maps onto, so a mapped pair is
  # never misread as "GitHub only".
  while IFS="$(printf '\t')" read -r name _ _ _; do
    [ -n "$name" ] || continue
    map_github_name "$name" | tr '[:upper:]' '[:lower:]'
  done < "$pgl_file" > "$pmapped_keys"

  # GitLab projects: create the GitHub counterpart when absent, otherwise
  # ensure the push mirror is healthy.
  while IFS="$(printf '\t')" read -r name id vis _branch; do
    [ -n "$name" ] || continue
    gh_name=$(map_github_name "$name")
    if grep -qxF -- "$(repo_key "$gh_name")" "$pgh_keys"; then
      st=$(mirror_status "$id" "$gh_name")
      case "$st" in
        missing | disabled | error) printf 'configure-mirror %s %s\n' "$name" "$id" ;;
      esac
    else
      printf 'create-github %s %s\n' "$gh_name" "$(gl_to_gh_visibility "$vis")"
      printf 'configure-mirror %s %s\n' "$name" "$id"
    fi
  done < "$pgl_file"

  # GitHub-only repos: create on GitLab and seed once. A repo whose name (raw
  # or mapped) already has a GitLab counterpart is not "GitHub only".
  while IFS="$(printf '\t')" read -r name vis; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    if grep -qxF -- "$key" "$pgl_keys" || grep -qxF -- "$key" "$pmapped_keys"; then
      continue
    fi
    printf 'create-gitlab %s %s\n' "$name" "$(gh_to_gl_visibility "$vis")"
    printf 'seed-gitlab %s\n' "$name"
  done < "$pgh_file"
}

# cmd_setup: print the plan and, under --dry-run, stop without mutating. Apply
# is Task 6; until then a non-dry run fails loudly rather than silently doing
# nothing.
cmd_setup() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  plan=$(plan_setup)
  info "setup plan:"
  if [ -n "$plan" ]; then
    printf '%s\n' "$plan"
  else
    info "nothing to do"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    info "dry run; no changes"
    return 0
  fi
  die "setup apply not implemented"
}

cmd_sync()  { die "sync not implemented"; }

main() {
  parse_args "$@"
  case "$CMD" in
    audit | setup | sync)
      resolve_config
      WORK_DIR=$(mktemp -d) || die "cannot create temp dir"
      trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
      ;;
  esac
  case "$CMD" in
    help) usage ;;
    audit) cmd_audit ;;
    setup) cmd_setup ;;
    sync)  cmd_sync ;;
    *) printf 'mirror: unknown command: %s\n' "$CMD" >&2; usage >&2; exit 2 ;;
  esac
}

if [ "$MIRROR_NO_MAIN" != "1" ]; then
  main "$@"
fi

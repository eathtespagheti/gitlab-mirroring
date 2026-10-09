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
}

cmd_setup() { die "setup not implemented"; }
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

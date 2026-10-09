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
# Set once acquire_lock has claimed the per-cache sync lock, so release_lock
# never removes a lock this run did not create.
: "${LOCK_HELD:=0}"

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
  case "$CONFLICT" in
    lab | report) : ;;
    *) die "invalid --conflict: $CONFLICT" ;;
  esac
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

# mirror_match_in <mirror_lines> <gh_name>: same "<status><TAB><count>"
# computation as mirror_match, but over already-fetched mirror_list output.
# Callers that must distinguish "no matching mirror" from "the query failed"
# fetch once with mirror_list and use this, so there is no second (possibly
# inconsistent) query. The target is matched literally with awk index() (repo
# names may contain sed/glob metacharacters like . + [ *), never with a regex,
# case-insensitively (GitLab MyApp may mirror to GitHub myapp), and is anchored
# on "@$GITHUB_HOST/" so a lookalike host such as "@mygithub.com" cannot match.
# When several mirrors match, the healthiest status wins: ok > error > disabled.
mirror_match_in() {
  # GITHUB_HOST is always set by resolve_config; the default keeps unit tests
  # that source the script (and call this directly) working.
  target="@${GITHUB_HOST:-github.com}/$GH_USER/$2.git"
  printf '%s\n' "$1" | awk -F'\t' -v t="$target" '
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

# mirror_match <project_id> <gh_name>: print "<status><TAB><count>" for the push
# mirrors targeting @$GITHUB_HOST/$GH_USER/<gh_name>.git, or return non-zero when
# the API could not be queried.
mirror_match() {
  if ! mirrors=$(mirror_list "$1"); then
    return 1
  fi
  mirror_match_in "$mirrors" "$2"
}

# mirror_status <project_id> <gh_name>: print ok|disabled|error|missing for the
# push mirror that targets @$GITHUB_HOST/$GH_USER/<gh_name>.git. An API failure is
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
# Pages are read one at a time (100 per page) until a page returns fewer than
# 100 entries, so accounts with more than one page are fully enumerated. Each
# page's output is buffered and reprinted once; no line is duplicated or
# prefixed by the loop. A failed listing call returns non-zero so callers can
# tell "listing failed" apart from "no projects".
list_gitlab_projects() {
  _lgp_page=1
  while :; do
    if ! _lgp_out=$(glab repo list --mine --per-page 100 --page "$_lgp_page" --output json \
        --jq '.[] | select(.namespace.kind == "user") | [.path, (.id|tostring), .visibility, (.default_branch // "")] | @tsv'); then
      return 1
    fi
    if [ -n "$_lgp_out" ]; then
      printf '%s\n' "$_lgp_out"
    fi
    _lgp_count=$(printf '%s\n' "$_lgp_out" | grep -c .)
    [ "$_lgp_count" -ge 100 ] || break
    _lgp_page=$((_lgp_page + 1))
  done
  return 0
}

# list_github_repos: one line per repo: gh_name<TAB>lowercased-visibility
list_github_repos() {
  gh repo list "$GH_USER" --limit 1000 --json name,visibility \
    --jq '.[] | [.name, (.visibility|ascii_downcase)] | @tsv'
}

# audit_json_array <file>: print a JSON array of the newline-separated values in
# <file>. Repo names match [A-Za-z0-9._-]; a name containing a double quote or a
# backslash is skipped defensively rather than emitted unescaped.
audit_json_array() {
  _aja_first=1
  printf '['
  if [ -s "$1" ]; then
    while IFS= read -r _aja_name; do
      [ -n "$_aja_name" ] || continue
      case "$_aja_name" in
        *'"'*) continue ;;
        *\\*)  continue ;;
      esac
      [ "$_aja_first" = 1 ] || printf ','
      _aja_first=0
      printf '"%s"' "$_aja_name"
    done < "$1"
  fi
  printf ']'
}

# audit_print <file> <prefix>: emit the human-readable lines for one bucket.
audit_print() {
  [ -s "$1" ] || return 0
  while IFS= read -r _ap_line; do
    [ -n "$_ap_line" ] || continue
    info "$2$_ap_line"
  done < "$1"
}

# audit_divergent <name> <gh_name>: return 0 when the cached GitHub and GitLab
# branch heads for <name> truly diverge (neither side is an ancestor of the
# other). <gh_name> is the mapped GitHub repository name (MIRROR_MAP). Read-only
# with respect to remotes: it may populate the local cache and fetch into it, but
# never pushes. Any failure to establish the facts returns 1, so the caller never
# reports a repo it could not prove divergent.
audit_divergent() {
  _av_name=$1
  _av_gh=$2
  _av_d=$(cache_repo_dir "$_av_name")
  cache_ensure "$_av_name" "$_av_gh" || return 1
  "$GIT" -C "$_av_d" fetch --prune --quiet github \
    '+refs/heads/*:refs/remotes/github/*' >/dev/null 2>&1 || return 1
  "$GIT" -C "$_av_d" fetch --prune --quiet gitlab \
    '+refs/heads/*:refs/remotes/gitlab/*' >/dev/null 2>&1 || return 1
  _av_refs=$WORK_DIR/audit.refs
  "$GIT" -C "$_av_d" for-each-ref --format='%(refname)' refs/remotes/github/ \
    > "$_av_refs" 2>/dev/null || return 1
  while IFS= read -r _av_ref; do
    [ -n "$_av_ref" ] || continue
    _av_b=${_av_ref#refs/remotes/github/}
    [ "$_av_b" = "HEAD" ] && continue
    _av_gl="refs/remotes/gitlab/$_av_b"
    "$GIT" -C "$_av_d" rev-parse --verify -q "$_av_gl" >/dev/null 2>&1 || continue
    if "$GIT" -C "$_av_d" merge-base --is-ancestor "$_av_gl" "$_av_ref"; then
      continue
    fi
    if "$GIT" -C "$_av_d" merge-base --is-ancestor "$_av_ref" "$_av_gl"; then
      continue
    fi
    return 0
  done < "$_av_refs"
  return 1
}

# cmd_audit: enumerate both hosts and write the drift buckets. Read-only with
# respect to remotes (divergence detection may populate the local cache, but
# only ever fetches). Matching is case-insensitive and literal (never regex).
# Findings are collected per category, then rendered as the human report or
# folded into one JSON object under --json; --exit-code and --verbose consult the
# same categories.
cmd_audit() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  mkdir -p "$WORK_DIR" || die "cannot create work dir"
  gl_file=$WORK_DIR/gl.tsv
  gh_file=$WORK_DIR/gh.tsv
  gl_keys=$WORK_DIR/gl.keys
  gh_keys=$WORK_DIR/gh.keys
  gh_vis=$WORK_DIR/gh.vis

  list_gitlab_projects > "$gl_file" || die "failed to list GitLab projects"
  list_github_repos > "$gh_file" || die "failed to list GitHub repositories"

  # Lowercased key sets for case-insensitive membership tests. awk tolower keeps
  # this literal; no regex is involved.
  awk -F'\t' 'NF { print tolower($1) }' "$gl_file" > "$gl_keys"
  awk -F'\t' 'NF { print tolower($1) }' "$gh_file" > "$gh_keys"
  # Lowercased name -> GitHub visibility, for the mismatch bucket.
  awk -F'\t' 'NF { print tolower($1) "\t" $2 }' "$gh_file" > "$gh_vis"

  # One file per category, values newline-separated. These drive the human
  # report, --json, --exit-code and --verbose alike.
  f_gitlab_only=$WORK_DIR/af.gitlab_only
  f_github_only=$WORK_DIR/af.github_only
  f_no_mirror=$WORK_DIR/af.no_mirror
  f_disabled=$WORK_DIR/af.mirror_disabled
  f_error=$WORK_DIR/af.mirror_error
  f_dupes=$WORK_DIR/af.duplicate_mirrors
  f_vis=$WORK_DIR/af.visibility_mismatch
  f_div=$WORK_DIR/af.divergent
  f_empty=$WORK_DIR/af.empty
  : > "$f_gitlab_only"
  : > "$f_github_only"
  : > "$f_no_mirror"
  : > "$f_disabled"
  : > "$f_error"
  : > "$f_dupes"
  : > "$f_vis"
  : > "$f_div"
  : > "$f_empty"

  while IFS="$(printf '\t')" read -r name _ _ _; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    if ! grep -qxF -- "$key" "$gh_keys"; then
      printf '%s\n' "$name" >> "$f_gitlab_only"
    fi
  done < "$gl_file"

  while IFS="$(printf '\t')" read -r name _; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    if ! grep -qxF -- "$key" "$gl_keys"; then
      printf '%s\n' "$name" >> "$f_github_only"
    fi
  done < "$gh_file"

  # Both-present repos: push-mirror health, duplicates, visibility mismatch,
  # divergence and empty repos. Read-only; one API call per project. The target
  # match is literal, case-insensitive, and anchored on "@$GITHUB_HOST/".
  while IFS="$(printf '\t')" read -r name id vis branch; do
    [ -n "$name" ] || continue
    key=$(repo_key "$name")
    grep -qxF -- "$key" "$gh_keys" || continue

    # Empty repos (no commits) are reported and skipped: there is nothing to
    # mirror or compare yet.
    if [ -z "$branch" ]; then
      printf '%s\n' "$name" >> "$f_empty"
      continue
    fi

    gh_name=$(map_github_name "$name")
    if matches=$(mirror_match "$id" "$gh_name"); then
      status=${matches%%"$(printf '\t')"*}
      count=${matches#*"$(printf '\t')"}
      case "$status" in
        missing)  printf '%s\n' "$name" >> "$f_no_mirror" ;;
        disabled) printf '%s\n' "$name" >> "$f_disabled" ;;
        error)    printf '%s\n' "$name" >> "$f_error" ;;
      esac
      if [ "$count" -gt 1 ]; then
        printf '%s (%s)\n' "$name" "$count" >> "$f_dupes"
      fi
    else
      # The API call failed and already warned; never claim there is no mirror.
      printf '%s\n' "$name" >> "$f_error"
    fi

    # Visibility mismatch: GitLab visibility mapped to the GitHub convention
    # versus what GitHub actually reports (both lowercased).
    gh_v=$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$gh_vis")
    gl_v=$(gl_to_gh_visibility "$vis")
    if [ -n "$gh_v" ] && [ "$gl_v" != "$gh_v" ]; then
      printf '%s (%s vs %s)\n' "$name" "$gl_v" "$gh_v" >> "$f_vis"
    fi

    # True divergence: neither branch head is an ancestor of the other.
    if audit_divergent "$name" "$gh_name"; then
      printf '%s\n' "$name" >> "$f_div"
    fi
  done < "$gl_file"

  if [ "$JSON_OUT" = "1" ]; then
    printf '{"gitlab_only":';        audit_json_array "$f_gitlab_only"
    printf ',"github_only":';        audit_json_array "$f_github_only"
    printf ',"no_mirror":';          audit_json_array "$f_no_mirror"
    printf ',"mirror_disabled":';    audit_json_array "$f_disabled"
    printf ',"mirror_error":';       audit_json_array "$f_error"
    printf ',"duplicate_mirrors":';  audit_json_array "$f_dupes"
    printf ',"visibility_mismatch":'; audit_json_array "$f_vis"
    printf ',"divergent":';          audit_json_array "$f_div"
    printf ',"empty":';              audit_json_array "$f_empty"
    printf '}\n'
  else
    audit_print "$f_gitlab_only" "GitLab only: "
    audit_print "$f_github_only" "GitHub only: "
    audit_print "$f_no_mirror" "no push mirror: "
    audit_print "$f_disabled" "push mirror disabled: "
    audit_print "$f_error" "push mirror error: "
    audit_print "$f_dupes" "duplicate push mirrors: "
    audit_print "$f_vis" "visibility mismatch: "
    audit_print "$f_div" "divergent: "
    audit_print "$f_empty" "empty: "
  fi

  if [ "$VERBOSE" = "1" ]; then
    printf 'audit: gitlab_only=%s github_only=%s no_mirror=%s mirror_disabled=%s mirror_error=%s duplicate_mirrors=%s visibility_mismatch=%s divergent=%s empty=%s\n' \
      "$(awk 'END { print NR }' "$f_gitlab_only")" \
      "$(awk 'END { print NR }' "$f_github_only")" \
      "$(awk 'END { print NR }' "$f_no_mirror")" \
      "$(awk 'END { print NR }' "$f_disabled")" \
      "$(awk 'END { print NR }' "$f_error")" \
      "$(awk 'END { print NR }' "$f_dupes")" \
      "$(awk 'END { print NR }' "$f_vis")" \
      "$(awk 'END { print NR }' "$f_div")" \
      "$(awk 'END { print NR }' "$f_empty")" >&2
  fi

  # --exit-code: non-zero when any drift category is non-empty. Empty repos are
  # reported/skipped, not drift, so they never trigger the exit code.
  if [ "$EXIT_CODE" = "1" ]; then
    for _ac_f in "$f_gitlab_only" "$f_github_only" "$f_no_mirror" \
                 "$f_disabled" "$f_error" "$f_dupes" "$f_vis" \
                 "$f_div"; do
      if [ -s "$_ac_f" ]; then
        return 1
      fi
    done
  fi
  return 0
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

# run <cmd...>: print the command to stderr with any embedded credentials
# masked, then execute it unless DRY_RUN=1. Secrets are never passed on the
# argument list (the push-mirror body travels in a file via --input), so nothing
# sensitive is printed here.
run() {
  printf '+ %s\n' "$(printf '%s ' "$@" | sed 's#://[^/@]*@#://***@#g')" >&2
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}

# create_github_repo <name> <visibility>
create_github_repo() {
  case "$2" in
    public) v=--public ;;
    *) v=--private ;;
  esac
  run gh repo create "$GH_USER/$1" "$v"
}

# create_gitlab_project <name> <visibility>
create_gitlab_project() {
  case "$2" in
    public) v=--public ;;
    private) v=--private ;;
    internal) v=--internal ;;
    *) v=--private ;;
  esac
  run glab repo create "$1" "$v" --skipGitInit
}

# seed_gitlab_from_github <name>: clone the GitHub repo bare, then push every
# branch and tag to the freshly created (empty) GitLab project. Explicit
# refspecs are used instead of `--mirror` so seeding can only create/update refs
# and can never delete them. Both calls go through run, so they obey DRY_RUN and
# are observable via $GIT in tests.
#
# Defence in depth: seeding is only ever legitimate into an empty project. If the
# GitLab project already advertises any ref, refuse to seed (a push here would
# overwrite canonical GitLab history) and return success, since the repository
# already exists and is not a seeding target.
seed_gitlab_from_github() {
  dest_url="$GITLAB_URL_BASE/$GL_USER/$1.git"
  if "$GIT" ls-remote "$dest_url" 2>/dev/null | grep -q .; then
    warn "refusing to seed $1: GitLab project already has refs"
    return 0
  fi
  d="$WORK_DIR/$1.git"
  seed_url="$GITHUB_URL_BASE/$GH_USER/$1.git"
  run "$GIT" clone --bare --quiet "$seed_url" "$d"
  run "$GIT" -C "$d" push --force "$dest_url" \
    "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"
}

# mirror_body_file <gh_name>: write the push-mirror JSON body to a 0600 file and
# print its path. The GitHub token is embedded in the url, so the body is kept in
# a file handed to `glab api --input`; it is never an argument and never printed.
mirror_body_file() {
  f="$WORK_DIR/mirror-body-$1.json"
  ( umask 077; : > "$f" )
  cat > "$f" <<EOF
{"url":"https://$GH_USER:$GH_TOKEN@${GITHUB_HOST:-github.com}/$GH_USER/$1.git","enabled":true,"auth_method":"password","only_protected_branches":false,"keep_divergent_refs":true}
EOF
  printf '%s\n' "$f"
}

# ensure_push_mirror <project_id> <gh_name>: make the GitLab push mirror to the
# GitHub repo healthy and correctly configured. The mirror list is fetched exactly
# once so "query failed" and "no matching mirror" are distinguishable:
#   query failed (mirror_list non-zero) → never POST (a POST could duplicate an
#     unknown mirror); warn and return non-zero so the run fails.
#   ok                                  → no-op.
#   target present (disabled/error)     → PUT in place, reusing its id.
#   target confirmed absent             → POST a new mirror.
ensure_push_mirror() {
  pid=$1
  gh_name=$2
  body=$(mirror_body_file "$gh_name") || return 1
  if ! mirrors=$(mirror_list "$pid"); then
    warn "could not query mirrors for project $pid; refusing to guess, no mirror change"
    return 1
  fi
  st=$(mirror_match_in "$mirrors" "$gh_name")
  st=${st%%"$(printf '\t')"*}
  if [ "$st" = "ok" ]; then
    return 0
  fi
  # Case-insensitive, literal match (mirror_match_in lowercases its target).
  mid=$(printf '%s\n' "$mirrors" | awk -F'\t' -v t="@${GITHUB_HOST:-github.com}/$GH_USER/$gh_name.git" 'index(tolower($2), tolower(t)) { print $1; exit }')
  if [ -n "$mid" ]; then
    run glab api -X PUT "projects/$pid/remote_mirrors/$mid" --input "$body"
    return $?
  fi
  # The query succeeded and no target matched: safe to create.
  run glab api -X POST "projects/$pid/remote_mirrors" --input "$body"
}

# confirm_or_abort: proceed when ASSUME_YES=1; otherwise prompt only on a
# terminal. With no terminal (pipes, CI) it dies rather than hanging.
confirm_or_abort() {
  if [ "$ASSUME_YES" = "1" ]; then
    return 0
  fi
  if [ -t 0 ]; then
    printf 'Apply these changes? [y/N] ' >&2
    read -r reply || reply=
    case "$reply" in
      y | Y | yes | YES) return 0 ;;
      *) die "aborted" ;;
    esac
  fi
  die "refusing to apply without --yes (stdin is not a terminal)"
}

# listing_has <file> <name>: true when the lowercased first column of a listing
# file (written by plan_setup) matches name. Literal, never regex.
listing_has() {
  [ -s "$1" ] || return 1
  awk -F'\t' -v k="$(repo_key "$2")" 'tolower($1) == k { found = 1 } END { exit found ? 0 : 1 }' "$1"
}

# apply_setup: compute the plan, confirm, then execute each action. Each action
# is re-checked against the listings captured by plan_setup, so an already-present
# repo is skipped, and mirror work is delegated to ensure_push_mirror, which is
# itself idempotent (re-runs are safe).
apply_setup() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  plan_file=$WORK_DIR/setup.plan
  plan_setup > "$plan_file" || die "failed to compute setup plan"
  info "setup plan:"
  if [ -s "$plan_file" ]; then
    cat "$plan_file"
  else
    info "nothing to do"
    return 0
  fi
  confirm_or_abort
  command -v gh >/dev/null 2>&1 || die "gh CLI not found"
  gh api user >/dev/null 2>&1 || die "GitHub authentication failed; run 'gh auth login'"

  apply_rc=0
  created_gl=$WORK_DIR/setup.created
  : > "$created_gl"
  while IFS=' ' read -r action a b; do
    [ -n "$action" ] || continue
    case "$action" in
      create-github)
        if listing_has "$WORK_DIR/setup.gh.tsv" "$a"; then
          info "already exists, skipping: $a"
          continue
        fi
        create_github_repo "$a" "$b" || apply_rc=1 ;;
      configure-mirror)
        ensure_push_mirror "$b" "$(map_github_name "$a")" || apply_rc=1 ;;
      create-gitlab)
        if listing_has "$WORK_DIR/setup.gl.tsv" "$a"; then
          info "already exists, skipping: $a"
          continue
        fi
        if create_gitlab_project "$a" "$b"; then
          printf '%s\n' "$a" >> "$created_gl"
        else
          apply_rc=1
        fi ;;
      seed-gitlab)
        # Seeding is only valid for a project created by this run. If the
        # project already existed (create was skipped) or its creation failed,
        # do not seed: a forced push would clobber canonical GitLab history.
        if ! grep -qxF -- "$a" "$created_gl"; then
          info "skipping seed for $a: GitLab project was not created in this run"
          continue
        fi
        seed_gitlab_from_github "$a" || apply_rc=1 ;;
      *)
        warn "unknown setup action: $action"
        apply_rc=1 ;;
    esac
  done < "$plan_file"
  return "$apply_rc"
}

# cmd_setup: print the plan and, under --dry-run, stop without mutating.
# Otherwise apply it (create repos, seed, configure push mirrors).
cmd_setup() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  if [ "$DRY_RUN" = "1" ]; then
    # plan_setup runs in a command-substitution subshell; propagate its failure
    # instead of continuing as if the plan were merely empty (error masking).
    plan=$(plan_setup) || exit 1
    info "setup plan:"
    if [ -n "$plan" ]; then
      printf '%s\n' "$plan"
    else
      info "nothing to do"
    fi
    info "dry run; no changes"
    return 0
  fi
  apply_setup
}

# cache_repo_dir <name>: the bare cache repository backing `sync` for a repo.
cache_repo_dir() { printf '%s\n' "$CACHE_DIR/$1.git"; }

# cache_ensure <gl_name> <gh_name>: create the bare cache and its github/gitlab
# remotes when absent. The GitHub remote uses the mapped GitHub name (<gh_name>,
# from MIRROR_MAP) while the GitLab remote uses <gl_name>; the cache directory is
# keyed on the GitLab name. The GitHub URL is refreshed on every call so a cache
# built before a mapping existed does not keep fetching the wrong repository.
# Idempotent. Remote URLs are built from the configured URL bases and resolved
# users; git authentication is inherited from the environment (the tool never
# stores or echoes a GitLab token).
cache_ensure() {
  _ce_gl=$1
  _ce_gh=${2:-$1}
  _ce_d=$(cache_repo_dir "$_ce_gl")
  if [ ! -d "$_ce_d" ]; then
    "$GIT" init --bare -q "$_ce_d" || return 1
    "$GIT" -C "$_ce_d" remote add github "$GITHUB_URL_BASE/$GH_USER/$_ce_gh.git" || return 1
    "$GIT" -C "$_ce_d" remote add gitlab "$GITLAB_URL_BASE/$GL_USER/$_ce_gl.git" || return 1
  else
    if ! "$GIT" -C "$_ce_d" remote set-url github "$GITHUB_URL_BASE/$GH_USER/$_ce_gh.git" 2>/dev/null; then
      "$GIT" -C "$_ce_d" remote add github "$GITHUB_URL_BASE/$GH_USER/$_ce_gh.git" || return 1
    fi
  fi
  return 0
}

# mark_sync_failed <name>: append a repo to the per-run failure log. sync_repo
# can run ref enumeration in a subshell, so a shared file (not a shell variable)
# is what cmd_sync reads after every repo.
mark_sync_failed() { printf '%s\n' "$1" >> "$WORK_DIR/sync_failed"; }

# handle_conflict <name> <branch>: apply the sync conflict policy to a branch
# that truly diverged (neither side is an ancestor of the other). GitLab is
# canonical. `report` warns and changes nothing; `lab` (the default) force-
# updates only that specific GitHub ref from the cached GitLab ref; any other
# value is a configuration error. Never deletes and never uses --mirror.
handle_conflict() {
  case "$CONFLICT" in
    report) warn "conflict on $1/$2 (GitLab kept; GitHub not changed)"; return 0 ;;
    lab)
      warn "conflict on $1/$2: GitLab wins; force-updating GitHub"
      run "$GIT" -C "$(cache_repo_dir "$1")" push --force github \
        "refs/remotes/gitlab/$2:refs/heads/$2"
      ;;
    *) die "invalid --conflict: $CONFLICT" ;;
  esac
}

# force_align <name>: one-time GitLab -> GitHub force alignment for the refs of a
# repo that diverged (driven by --force-align). It force-updates ONLY the
# specific GitHub branches/tags that differ from GitLab; it never deletes a ref
# and never uses --mirror. Ref existence is established from the cache, which
# sync_repo has already fetched.
force_align() {
  _fa_name=$1
  _fa_d=$(cache_repo_dir "$_fa_name")
  [ -d "$_fa_d" ] || return 0
  _fa_rc=0

  _fa_branches=$WORK_DIR/fa.branches
  if ! "$GIT" -C "$_fa_d" for-each-ref --format='%(refname)' refs/remotes/github/ > "$_fa_branches"; then
    warn "could not enumerate GitHub branches for $_fa_name"
    return 1
  fi
  while IFS= read -r _fa_ref; do
    [ -n "$_fa_ref" ] || continue
    _fa_b=${_fa_ref#refs/remotes/github/}
    [ "$_fa_b" = "HEAD" ] && continue
    _fa_gl="refs/remotes/gitlab/$_fa_b"
    "$GIT" -C "$_fa_d" rev-parse --verify -q "$_fa_gl" >/dev/null || continue
    if "$GIT" -C "$_fa_d" merge-base --is-ancestor "$_fa_gl" "$_fa_ref"; then
      continue
    fi
    warn "force-align $_fa_name/$_fa_b: GitLab wins; force-updating GitHub"
    run "$GIT" -C "$_fa_d" push --force github "$_fa_gl:refs/heads/$_fa_b" || _fa_rc=1
  done < "$_fa_branches"

  _fa_tags=$WORK_DIR/fa.tags
  if ! "$GIT" -C "$_fa_d" for-each-ref --format='%(refname)' refs/gh-tags/ > "$_fa_tags"; then
    warn "could not enumerate GitHub tags for $_fa_name"
    return 1
  fi
  while IFS= read -r _fa_ref; do
    [ -n "$_fa_ref" ] || continue
    _fa_t=${_fa_ref#refs/gh-tags/}
    _fa_gl="refs/gl-tags/$_fa_t"
    "$GIT" -C "$_fa_d" rev-parse --verify -q "$_fa_gl" >/dev/null || continue
    _fa_glsha=$("$GIT" -C "$_fa_d" rev-parse "$_fa_gl")
    _fa_ghsha=$("$GIT" -C "$_fa_d" rev-parse "$_fa_ref")
    [ "$_fa_glsha" = "$_fa_ghsha" ] && continue
    warn "force-align $_fa_name/$_fa_t: GitLab wins; force-updating GitHub tag"
    run "$GIT" -C "$_fa_d" push --force github "$_fa_gl:refs/tags/$_fa_t" || _fa_rc=1
  done < "$_fa_tags"

  return "$_fa_rc"
}

# acquire_lock: atomically claim the per-cache sync lock with mkdir. A lock left
# behind by a crashed/other run makes this fail loudly rather than racing it.
acquire_lock() {
  mkdir "$CACHE_DIR/.sync.lock" 2>/dev/null || die "sync already running (lock: $CACHE_DIR/.sync.lock)"
  LOCK_HELD=1
}

# release_lock: idempotent cleanup registered in the EXIT/HUP/INT/TERM trap. Only
# removes the lock when this run actually acquired it, so a foreign lock survives.
release_lock() {
  [ "$LOCK_HELD" = "1" ] || return 0
  rmdir "$CACHE_DIR/.sync.lock" 2>/dev/null || :
  LOCK_HELD=0
}

# selected <name>: true when a managed repo passes --only/--exclude. Matching is
# literal and case-insensitive, consistent with the rest of the tool.
selected() {
  _sel_key=$(repo_key "$1")
  if [ -n "$ONLY_LIST" ]; then
    printf '%s\n' "$ONLY_LIST" | tr '[:upper:]' '[:lower:]' | grep -qxF -- "$_sel_key" || return 1
  fi
  if [ -n "$EXCLUDE_LIST" ]; then
    if printf '%s\n' "$EXCLUDE_LIST" | tr '[:upper:]' '[:lower:]' | grep -qxF -- "$_sel_key"; then
      return 1
    fi
  fi
  return 0
}

# sync_repo <name>: fetch both hosts into the cache and rescue GitHub-side refs
# onto GitLab. Branch pushes only create or fast-forward (GitLab is an ancestor
# of GitHub); divergent branches go to the conflict policy. Tags missing on
# GitLab are pushed; a same-named tag that differs is deferred to the conflict
# policy. Failures are recorded in $WORK_DIR/sync_failed and returned non-zero.
sync_repo() {
  _sr_name=$1
  _sr_gh=$(map_github_name "$_sr_name")
  _sr_d=$(cache_repo_dir "$_sr_name")
  if ! cache_ensure "$_sr_name" "$_sr_gh"; then
    warn "could not prepare cache for $_sr_name"
    mark_sync_failed "$_sr_name"
    return 1
  fi
  if ! run "$GIT" -C "$_sr_d" fetch --prune --quiet github \
        '+refs/heads/*:refs/remotes/github/*' '+refs/tags/*:refs/gh-tags/*'; then
    warn "fetch from GitHub failed for $_sr_name"
    mark_sync_failed "$_sr_name"
    return 1
  fi
  if ! run "$GIT" -C "$_sr_d" fetch --prune --quiet gitlab \
        '+refs/heads/*:refs/remotes/gitlab/*' '+refs/tags/*:refs/gl-tags/*'; then
    warn "fetch from GitLab failed for $_sr_name"
    mark_sync_failed "$_sr_name"
    return 1
  fi

  # Branches: create on GitLab when missing, fast-forward otherwise; anything
  # else is divergent and handled by the conflict policy.
  _sr_refs=$WORK_DIR/sync.refs
  if ! "$GIT" -C "$_sr_d" for-each-ref --format='%(refname)' refs/remotes/github/ > "$_sr_refs"; then
    warn "could not enumerate GitHub branches for $_sr_name"
    mark_sync_failed "$_sr_name"
    return 1
  fi
  while IFS= read -r _sr_ref; do
    [ -n "$_sr_ref" ] || continue
    _sr_b=${_sr_ref#refs/remotes/github/}
    [ "$_sr_b" = "HEAD" ] && continue
    if ! "$GIT" -C "$_sr_d" rev-parse --verify -q "refs/remotes/gitlab/$_sr_b" >/dev/null; then
      if ! run "$GIT" -C "$_sr_d" push --quiet gitlab "$_sr_ref:refs/heads/$_sr_b"; then
        warn "could not create $_sr_name/$_sr_b on GitLab"
        mark_sync_failed "$_sr_name"
      fi
    elif "$GIT" -C "$_sr_d" merge-base --is-ancestor "refs/remotes/gitlab/$_sr_b" "$_sr_ref"; then
      if ! run "$GIT" -C "$_sr_d" push --quiet gitlab "$_sr_ref:refs/heads/$_sr_b"; then
        warn "could not fast-forward $_sr_name/$_sr_b on GitLab"
        mark_sync_failed "$_sr_name"
      fi
    elif "$GIT" -C "$_sr_d" merge-base --is-ancestor "$_sr_ref" "refs/remotes/gitlab/$_sr_b"; then
      # GitLab is ahead (GitHub is an ancestor of GitLab). This is the normal
      # state between push-mirror updates: there is nothing to rescue and no
      # conflict, so do not warn and do not force-push. Simply leave it.
      :
    else
      handle_conflict "$_sr_name" "$_sr_b" || mark_sync_failed "$_sr_name"
    fi
  done < "$_sr_refs"

  # Tags: rescue GitHub tags that GitLab lacks. A same-named tag pointing
  # elsewhere is divergent; the conflict policy owns that (deferred here).
  _sr_tags=$WORK_DIR/sync.gh-tags
  if ! "$GIT" -C "$_sr_d" for-each-ref --format='%(refname)' refs/gh-tags/ > "$_sr_tags"; then
    warn "could not enumerate GitHub tags for $_sr_name"
    mark_sync_failed "$_sr_name"
    return 1
  fi
  while IFS= read -r _sr_ref; do
    [ -n "$_sr_ref" ] || continue
    _sr_t=${_sr_ref#refs/gh-tags/}
    if ! "$GIT" -C "$_sr_d" rev-parse --verify -q "refs/gl-tags/$_sr_t" >/dev/null; then
      if ! run "$GIT" -C "$_sr_d" push --quiet gitlab "$_sr_ref:refs/tags/$_sr_t"; then
        warn "could not create tag $_sr_name/$_sr_t on GitLab"
        mark_sync_failed "$_sr_name"
      fi
    else
      _sr_gl=$("$GIT" -C "$_sr_d" rev-parse "refs/gl-tags/$_sr_t")
      _sr_gh=$("$GIT" -C "$_sr_d" rev-parse "$_sr_ref")
      if [ "$_sr_gl" != "$_sr_gh" ]; then
        case "$CONFLICT" in
          report) warn "tag conflict on $_sr_name/$_sr_t (GitLab kept; GitHub not changed)" ;;
          lab)
            warn "tag conflict on $_sr_name/$_sr_t: GitLab wins; force-updating GitHub"
            run "$GIT" -C "$_sr_d" push --force github "refs/gl-tags/$_sr_t:refs/tags/$_sr_t" ||
              mark_sync_failed "$_sr_name" ;;
          *) die "invalid --conflict: $CONFLICT" ;;
        esac
      fi
    fi
  done < "$_sr_tags"

  if grep -qxF -- "$_sr_name" "$WORK_DIR/sync_failed" 2>/dev/null; then
    return 1
  fi
  return 0
}

# cmd_sync: iterate managed GitLab projects (filtered by --only/--exclude) and
# rescue each from GitHub. Returns non-zero if any repo failed to sync.
cmd_sync() {
  [ -n "${WORK_DIR:-}" ] || die "internal: WORK_DIR not set"
  acquire_lock
  mkdir -p "$WORK_DIR" || die "cannot create work dir"
  : > "$WORK_DIR/sync_failed"
  _cs_list=$WORK_DIR/sync.gl.tsv
  list_gitlab_projects > "$_cs_list" || die "failed to list GitLab projects"
  _cs_rc=0
  while IFS="$(printf '\t')" read -r _cs_name _cs_rest; do
    [ -n "$_cs_name" ] || continue
    selected "$_cs_name" || continue
    sync_repo "$_cs_name" || _cs_rc=1
    if [ "$FORCE_ALIGN" = "1" ]; then
      force_align "$_cs_name" || _cs_rc=1
    fi
  done < "$_cs_list"
  if [ -s "$WORK_DIR/sync_failed" ]; then
    _cs_rc=1
  fi
  return "$_cs_rc"
}

main() {
  parse_args "$@"
  case "$CMD" in
    audit | setup | sync)
      resolve_config
      WORK_DIR=$(mktemp -d) || die "cannot create temp dir"
      trap 'release_lock; rm -rf "$WORK_DIR"' EXIT HUP INT TERM
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

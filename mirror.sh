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

# Minimal command dispatch. Full option parsing (--dry-run, --only, ...) is
# added in Task 2; an empty CMD means no command was given, which main treats
# as a usage error.
parse_args() { CMD="${1:-}"; }              # replaced in Task 2
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

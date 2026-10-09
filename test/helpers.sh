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

assert_not_contains() { # desc needle haystack
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$3" in
    *"$2"*) TESTS_FAILED=$((TESTS_FAILED + 1))
            printf 'FAIL: %s\n  unexpected: [%s]\n  in:         [%s]\n' "$1" "$2" "$3" >&2 ;;
    *) : ;;
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

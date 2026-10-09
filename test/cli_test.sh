#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/test/helpers.sh"

out=$("$ROOT/mirror.sh" help 2>&1); assert_contains "help lists audit" "audit" "$out"
out=$("$ROOT/mirror.sh" bogus 2>&1); rc=$?; assert_eq "unknown rc" 2 "$rc"
assert_contains "unknown msg" "unknown command" "$out"
"$ROOT/mirror.sh" >/dev/null 2>&1; assert_eq "no args rc" 2 $?
out=$(MIRROR_NO_MAIN=1 sh -c '. "$1"; map_github_name Foo' sh "$ROOT/mirror.sh")
assert_eq "source guard + stub map" "Foo" "$out"
report

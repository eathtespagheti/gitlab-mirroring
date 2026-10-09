#!/bin/sh
set -u
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail=0
for t in "$dir"/*_test.sh; do
  printf '== %s ==\n' "$t"
  sh "$t" || fail=1
done
exit $fail

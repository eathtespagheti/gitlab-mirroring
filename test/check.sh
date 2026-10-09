#!/bin/sh
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rc=0
sh -n "$root/mirror.sh" || rc=1
if command -v dash >/dev/null 2>&1; then dash -n "$root/mirror.sh" || rc=1; fi
if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh "$root/mirror.sh" || rc=1; fi
if command -v checkbashisms >/dev/null 2>&1; then checkbashisms -f "$root/mirror.sh" || rc=1; fi
exit $rc

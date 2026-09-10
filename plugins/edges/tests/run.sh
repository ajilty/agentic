#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export HERE
. "$HERE/lib.sh"
for t in "$HERE"/test_*.sh; do [ -e "$t" ] || continue; echo "== $t"; . "$t"; done
printf 'PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]

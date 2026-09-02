#!/bin/sh
# Runs every plugin's test suite. From the repo root: sh test/run_all.sh
cd "$(dirname "$0")" || exit 1
status=0
for t in test_*.lua; do
    printf '%-28s ' "$t"
    out=$(lua "$t" 2>&1) || status=1
    echo "$out" | tail -1
    echo "$out" | grep -E "^FAIL" && status=1
done
exit $status

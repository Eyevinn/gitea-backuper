#!/bin/bash
# Run every tests/*.test.sh; exit non-zero if any fails.
cd "$(dirname "$0")" || exit 1
fail=0
for t in ./*.test.sh; do
  echo "### $t"
  bash "$t" || fail=1
done
if [ "$fail" -ne 0 ]; then echo "SOME TEST FILES FAILED"; exit 1; fi
echo "ALL TEST FILES PASSED"

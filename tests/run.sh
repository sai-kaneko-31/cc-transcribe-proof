#!/usr/bin/env bash
# Run every tests/test_*.sh. Exit 1 if any of them fails.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
status=0
for t in "$here"/test_*.sh; do
  echo "== $(basename "$t")"
  bash "$t" || status=1
done
exit "$status"

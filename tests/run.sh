#!/usr/bin/env bash
# Run every tests/test_*.sh under the bash on PATH and, when it is a different
# version, under /bin/bash too (the macOS default is 3.2, which the wrapper must
# support). Exit 1 if any of them fails.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
status=0

shells=(bash)
if [ -x /bin/bash ]; then
  first=$(bash -c 'echo "$BASH_VERSION"')
  second=$(/bin/bash -c 'echo "$BASH_VERSION"')
  [ "$first" != "$second" ] && shells+=(/bin/bash)
fi

for sh in "${shells[@]}"; do
  echo "#### $sh ($("$sh" -c 'echo "$BASH_VERSION"'))"
  for t in "$here"/test_*.sh; do
    echo "== $(basename "$t")"
    "$sh" "$t" || status=1
  done
done
exit "$status"

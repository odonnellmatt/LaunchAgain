#!/bin/bash
#
# Repeatedly exercises the shipping SwiftUI dashboard against isolated temporary roots.
# The XCTest harness hosts RootView directly and never opens the user's registry.

set -euo pipefail

cd "$(dirname "$0")/.."

REPEATS="${1:-3}"
case "$REPEATS" in
  ''|*[!0-9]*|0) echo "usage: $0 [positive-repeat-count]" >&2; exit 2 ;;
esac

for ((run = 1; run <= REPEATS; run++)); do
  echo "==> Dashboard UI regression run $run of $REPEATS"
  swift test --filter DashboardUIRegressionTests
done

echo "Dashboard UI regression passed $REPEATS consecutive run(s)."

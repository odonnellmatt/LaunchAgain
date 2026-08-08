#!/bin/bash
#
# Refreshes the committed screen renders in docs/evidence/.
#
#   ./Scripts/render-evidence.sh
#
# The rendering tests run as part of `swift test` and always write to
# .build/screen-renders/, which is not in the working tree. Copying into docs/evidence/
# happens only when MAL_WRITE_EVIDENCE=1, which this script sets — so an ordinary test
# run leaves `git status` clean, and updating the evidence is a decision rather than a
# side effect.
#
# The renders are byte-stable: every identifier the screens display is fixed, so running
# this twice with no code change produces no diff.

set -euo pipefail

cd "$(dirname "$0")/.."

echo ""
echo "==> Rendering the C1–C4 screens into docs/evidence/"
echo ""

MAL_WRITE_EVIDENCE=1 swift test --filter ScreenRenderingTests

echo ""
git status --short docs/evidence/ || true
echo ""
echo 'Done. No output from git status above means the committed renders were already current.'

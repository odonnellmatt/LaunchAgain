#!/bin/bash
#
# Packages LaunchAgain into a distributable DMG.
#
#   ./Scripts/package-dmg.sh
#
# Ad-hoc signing is the default, which produces a DMG that works on this machine and on
# any machine where the user is willing to right-click → Open. For real distribution set
# the three environment variables below and the script will sign with your Developer ID,
# notarise with Apple, and staple the ticket:
#
#   MAL_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   MAL_NOTARY_PROFILE  a notarytool keychain profile name, created once with:
#                         xcrun notarytool store-credentials <name> \
#                           --apple-id you@example.com --team-id TEAMID \
#                           --password <app-specific-password>
#
# Nothing here is required to *use* the launcher — building and running it locally needs
# no Apple Developer account at all.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="LaunchAgain"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="$( { sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md 2>/dev/null || true; } | head -1)"
VERSION="${VERSION:-1.0}"
DMG="$BUILD_DIR/LaunchAgain-$VERSION.dmg"
CHECKSUM="$DMG.sha256"
STAGE="$BUILD_DIR/dmg-stage"

echo "==> Building the application (release, universal)"
"$ROOT/Scripts/build-app.sh"

[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
rm -f "$CHECKSUM"
mkdir -p "$STAGE"
cp -Rp "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Ship the documents that state what this thing does and does not do. Someone who mounts
# a DMG should be able to read the limitations without cloning a repository.
mkdir -p "$STAGE/Documentation"
for doc in README.md LIMITATIONS.md SECURITY.md PRIVACY.md NOTICE LICENSE CHANGELOG.md; do
  [ -f "$ROOT/$doc" ] && cp "$ROOT/$doc" "$STAGE/Documentation/$doc"
done

echo "==> Building the disk image"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

rm -rf "$STAGE"

IDENTITY="${MAL_SIGN_IDENTITY:--}"
echo "==> Signing the disk image with: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp"$([ "$IDENTITY" = "-" ] && echo "=none")" "$DMG"

if [ "$IDENTITY" = "-" ]; then
  cat <<'NOTE'

==> Ad-hoc signed.

    This DMG is not notarised, so Gatekeeper will warn on another Mac. That is honest:
    an ad-hoc signature says "built locally", and pretending otherwise is not something
    this project does. To notarise, set MAL_SIGN_IDENTITY and MAL_NOTARY_PROFILE and
    run this script again.
NOTE
elif [ -n "${MAL_NOTARY_PROFILE:-}" ]; then
  echo "==> Submitting to Apple for notarisation (this can take a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$MAL_NOTARY_PROFILE" --wait
  echo "==> Stapling the ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> Verifying the result"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || true
else
  echo "==> Signed with a Developer ID but MAL_NOTARY_PROFILE is not set, so this was not"
  echo "    notarised. Gatekeeper will still warn on another Mac."
fi

echo "==> Writing SHA-256 checksum"
(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUM")")

echo ""
echo "Built: $DMG"
ls -lh "$DMG" | awk '{print "    " $5}'
echo "Checksum: $CHECKSUM"
sed 's/^/    /' "$CHECKSUM"
echo ""
echo "Verify what a user will get:"
echo "    hdiutil attach \"$DMG\""
echo "    codesign --verify --deep --strict --verbose=2 \"/Volumes/$APP_NAME/$APP_NAME.app\""
echo "    spctl -a -vv \"/Volumes/$APP_NAME/$APP_NAME.app\""

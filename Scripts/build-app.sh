#!/bin/bash
#
# Builds LaunchAgain and assembles it into a runnable .app bundle.
#
#   ./Scripts/build-app.sh              release, universal (arm64 + x86_64)
#   ./Scripts/build-app.sh --debug      debug, native arch only — much faster
#   ./Scripts/build-app.sh --run        build, then launch the result
#
# The bundle it produces contains:
#   Contents/MacOS/LaunchAgainGUI         the SwiftUI app
#   Contents/MacOS/launchagain            the headless CLI
#   Contents/Resources/mal-shim           the launcher stub planted in every instance
#   Contents/Resources/launchagain        compatibility symlink to the CLI
#   Contents/Resources/*.md               the docs the Help menu opens
#
# Signing: ad-hoc by default. Set MAL_SIGN_IDENTITY to a Developer ID Application
# identity to sign for distribution (Scripts/package-dmg.sh does this for the DMG).

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="release"
ARCH_ARGS=(--arch arm64 --arch x86_64)
RUN_AFTER=0
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --debug)  CONFIG="debug"; ARCH_ARGS=() ;;
    --native) ARCH_ARGS=() ;;
    --run)    RUN_AFTER=1 ;;
    --install) INSTALL=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="LaunchAgain"
BUNDLE_ID="com.launchagain.app"
# Version comes from the top entry in CHANGELOG.md when there is one.
VERSION="$( { sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md 2>/dev/null || true; } | head -1)"
VERSION="${VERSION:-1.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building ($CONFIG${ARCH_ARGS:+, universal})"
swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"

BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/LaunchAgainApp" "$APP/Contents/MacOS/LaunchAgainGUI"
cp "$BIN_DIR/launchagain"          "$APP/Contents/MacOS/launchagain"
cp "$BIN_DIR/mal-shim"             "$APP/Contents/Resources/mal-shim"
chmod 755 "$APP/Contents/MacOS/LaunchAgainGUI" \
          "$APP/Contents/MacOS/launchagain" \
          "$APP/Contents/Resources/mal-shim"
ln -s ../MacOS/launchagain "$APP/Contents/Resources/launchagain"

# Default macOS volumes are case-insensitive. Keep this guard beside assembly so a
# future executable rename cannot silently make the GUI and CLI overwrite each other.
if [ "$APP/Contents/MacOS/LaunchAgainGUI" -ef "$APP/Contents/MacOS/launchagain" ]; then
  echo "GUI and CLI resolve to the same bundle executable" >&2
  exit 1
fi

for doc in README.md LIMITATIONS.md SECURITY.md PRIVACY.md NOTICE LICENSE; do
  [ -f "$ROOT/$doc" ] && cp "$ROOT/$doc" "$APP/Contents/Resources/$doc"
done

echo "==> Rendering the application icon"
"$BIN_DIR/launchagain" icon "$APP/Contents/Resources/AppIcon.icns" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>LaunchAgainGUI</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Local-only utility. No telemetry, no network access.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# The app needs no entitlements of its own beyond the defaults: it takes no privileges,
# installs no helper and makes no network requests. Hardened Runtime is enabled because
# there is no reason not to.
ENTITLEMENTS="$BUILD_DIR/launcher.entitlements"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><false/>
</dict>
</plist>
ENT

IDENTITY="${MAL_SIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
# Inside out: the two helper executables in Resources first, then the bundle.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
         "$APP/Contents/Resources/mal-shim"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
         "$APP/Contents/MacOS/launchagain"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
         --entitlements "$ENTITLEMENTS" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo ""
echo "Built: $APP"
du -sh "$APP" | sed 's/^/    /'
echo ""
echo "Run it:            open \"$APP\""
echo "Use the CLI:       \"$APP/Contents/MacOS/launchagain\" scan"
echo "Package a DMG:     ./Scripts/package-dmg.sh"

if [ "$INSTALL" = "1" ]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST"
  # /Applications is group-writable by admin users, so this usually needs no password.
  if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" "$DEST" 2>/dev/null; then
    echo "    installed"
    APP="$DEST"
  else
    echo "    could not write to /Applications — drag the app there yourself, or run:" >&2
    echo "    sudo cp -R \"$APP\" \"$DEST\"" >&2
  fi
fi

if [ "$RUN_AFTER" = "1" ]; then
  open "$APP"
fi

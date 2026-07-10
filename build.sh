#!/bin/bash
# Builds WindowSnap, packages it as WindowSnap.app, and creates WindowSnap.dmg.
# Run on a Mac with the Swift toolchain (Xcode or Command Line Tools).
set -e

APP_NAME="WindowSnap"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"

echo "==> Generating Icon.icns (AppKit renderer, no external deps)..."
chmod +x make-icon.sh
rm -f Icon.icns
./make-icon.sh || echo "    WARNING: icon generation failed; app will use the default icon."

echo "==> Building release binary..."
swift build -c release

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
[ -f "Icon.icns" ] && cp "Icon.icns" "${APP_BUNDLE}/Contents/Resources/Icon.icns"

CERT_NAME="WindowSnap Self-Signed"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "==> Code signing with stable identity: $CERT_NAME"
  echo "    (Accessibility grant will persist across versions.)"
  codesign --force --deep --options runtime --entitlements WindowSnap.entitlements --sign "$CERT_NAME" "${APP_BUNDLE}"
else
  echo "==> WARNING: No stable signing certificate found."
  echo "    Falling back to ad-hoc signing — macOS will RESET the Accessibility"
  echo "    grant on every update. To fix this permanently, run:  ./make-cert.sh"
  codesign --force --deep --entitlements WindowSnap.entitlements --sign - "${APP_BUNDLE}"
fi

# Nudge macOS to refresh the cached bundle icon so Finder shows the new one.
touch "${APP_BUNDLE}"
echo "==> (If Finder still shows a stale icon after install, run:"
echo "     touch /Applications/WindowSnap.app && killall Finder Dock )"

echo "==> Creating ${DMG_NAME}..."
rm -f "${DMG_NAME}"
STAGING="dmg_staging"; rm -rf "${STAGING}"; mkdir -p "${STAGING}"
cp -R "${APP_BUNDLE}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
# Bundle the one-click installer into the DMG.
cp "install.sh" "${STAGING}/install.command"
chmod +x "${STAGING}/install.command"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG_NAME}"
rm -rf "${STAGING}"

echo ""
echo "==> Done. Created ${DMG_NAME}"
echo "    Open it, then double-click install.command to install or update WindowSnap."

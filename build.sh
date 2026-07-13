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

# WhisperKit / swift-transformers ship SPM resource bundles the executable loads
# via Bundle.module at runtime. They must travel with the app (in Resources).
for b in "${BUILD_DIR}"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "${APP_BUNDLE}/Contents/Resources/"
done

CERT_NAME="WindowSnap Self-Signed"

# Prefer the stable self-signed identity so the Accessibility grant persists
# across updates. If it isn't present yet, create it now (once) via make-cert.sh
# rather than silently falling back to ad-hoc signing — ad-hoc changes the
# signature every build, which makes macOS reset the Accessibility grant on
# every update.
if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1 && [ -f make-cert.sh ]; then
  echo "==> No stable signing identity yet — creating \"$CERT_NAME\" (one time)..."
  chmod +x make-cert.sh
  ./make-cert.sh || echo "    WARNING: make-cert.sh failed; will fall back to ad-hoc signing."
fi

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  SIGN_ID="$CERT_NAME"
  RUNTIME_OPTS=(--options runtime)
  echo "==> Code signing with stable identity: $CERT_NAME"
  echo "    (Accessibility grant will persist across versions.)"
else
  SIGN_ID="-"
  RUNTIME_OPTS=()
  echo "==> WARNING: Falling back to ad-hoc signing — macOS will RESET the"
  echo "    Accessibility grant on every update. To fix this permanently, run:"
  echo "    ./make-cert.sh   then rebuild."
fi

# Embed + sign Sparkle.framework (dynamic, with nested XPC services) inside-out
# before sealing the app. The SPM resource bundles (WhisperKit / swift-transformers)
# are resource-only and need no separate signature.
chmod +x embed-sparkle.sh
RUNTIME=""; [ "$SIGN_ID" != "-" ] && RUNTIME="runtime"
./embed-sparkle.sh "${APP_BUNDLE}" "${BUILD_DIR}" "$SIGN_ID" "$RUNTIME"

# Seal the app bundle. Apple has deprecated `codesign --deep`; the framework was
# already signed inside-out above, so this single app-level signature seals it.
codesign --force "${RUNTIME_OPTS[@]}" --entitlements WindowSnap.entitlements \
  --sign "$SIGN_ID" "${APP_BUNDLE}"

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

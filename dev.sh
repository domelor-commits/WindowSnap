#!/bin/bash
# Quick dev iteration: build WindowSnap, wrap it in a signed .app, and relaunch.
# Much faster than build.sh — no icon regeneration, no DMG. Signs with the stable
# "WindowSnap Self-Signed" cert when present so the Accessibility grant persists
# across rebuilds (falls back to ad-hoc signing otherwise).
#
# Usage:
#   ./dev.sh            # debug build (fastest)
#   ./dev.sh release    # optimized build
set -e

APP_NAME="WindowSnap"
CONFIG="${1:-debug}"                 # "debug" (default) or "release"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Building (${CONFIG})..."
if [ "$CONFIG" = "release" ]; then
  swift build -c release
else
  swift build
fi

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
[ -f "Icon.icns" ] && cp "Icon.icns" "${APP_BUNDLE}/Contents/Resources/Icon.icns"
# SPM resource bundles (WhisperKit / swift-transformers) load via Bundle.module at
# runtime, so they must sit next to the executable in Resources.
for b in "${BUILD_DIR}"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "${APP_BUNDLE}/Contents/Resources/"
done

CERT_NAME="WindowSnap Self-Signed"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  SIGN_ID="$CERT_NAME"; RUNTIME="runtime"
  echo "==> Signing with stable identity: $CERT_NAME"
else
  SIGN_ID="-"; RUNTIME=""
  echo "==> Signing ad-hoc (run ./make-cert.sh once to keep the Accessibility grant)"
fi

# Embed + sign Sparkle.framework (inside-out) before sealing the app.
chmod +x embed-sparkle.sh
./embed-sparkle.sh "${APP_BUNDLE}" "${BUILD_DIR}" "$SIGN_ID" "$RUNTIME"

RUNTIME_OPTS=(); [ "$RUNTIME" = "runtime" ] && RUNTIME_OPTS=(--options runtime)
codesign --force "${RUNTIME_OPTS[@]}" --entitlements WindowSnap.entitlements \
  --sign "$SIGN_ID" "${APP_BUNDLE}"

echo "==> Relaunching ${APP_NAME}..."
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1
open "${APP_BUNDLE}"
echo "==> Launched ${APP_BUNDLE} (${CONFIG})."

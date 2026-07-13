#!/bin/bash
# Embeds Sparkle.framework into the app bundle, adds the framework rpath, and
# signs the framework inside-out (nested XPC services / helper app / Autoupdate,
# then the framework itself). Called by build.sh and dev.sh before the app-level
# signature is applied. No-op if Sparkle isn't in the build output.
#
# Usage: ./embed-sparkle.sh <APP_BUNDLE> <BUILD_DIR> <SIGN_ID> [runtime]
set -e

APP_BUNDLE="$1"
BUILD_DIR="$2"
SIGN_ID="$3"
RUNTIME="$4"

SRC="${BUILD_DIR}/Sparkle.framework"
if [ ! -d "$SRC" ]; then
  echo "    (Sparkle.framework not in ${BUILD_DIR} — skipping embed)"
  exit 0
fi

RUNTIME_OPTS=()
[ "$RUNTIME" = "runtime" ] && RUNTIME_OPTS=(--options runtime)

FW_DIR="${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "$FW_DIR"
rm -rf "${FW_DIR}/Sparkle.framework"
cp -R "$SRC" "${FW_DIR}/"

# The executable links @rpath/Sparkle.framework; make Contents/Frameworks an rpath.
EXE="${APP_BUNDLE}/Contents/MacOS/WindowSnap"
if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
fi

# Sign inside-out: deepest nested code first, then the framework bundle. (The
# app-level codesign that runs afterward seals — but does not re-sign — this.)
V="${FW_DIR}/Sparkle.framework/Versions/B"
for nested in \
  "$V/XPCServices/Downloader.xpc" \
  "$V/XPCServices/Installer.xpc" \
  "$V/Updater.app" \
  "$V/Autoupdate"; do
  [ -e "$nested" ] && codesign --force "${RUNTIME_OPTS[@]}" --sign "$SIGN_ID" "$nested"
done
codesign --force "${RUNTIME_OPTS[@]}" --sign "$SIGN_ID" "${FW_DIR}/Sparkle.framework"
echo "    embedded + signed Sparkle.framework"

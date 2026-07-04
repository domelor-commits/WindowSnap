#!/bin/bash
# WindowSnap installer — double-click this to install or update.
#
# It copies WindowSnap.app (sitting next to this script, e.g. on the mounted
# DMG) into /Applications, replacing any existing version, then clears the
# stale Accessibility entry and opens the right settings pane so you can enable
# the new build. Because every build is signed with the same stable
# "WindowSnap Self-Signed" certificate, you only have to approve Accessibility
# once; future updates keep the grant.
set -e

APP_NAME="WindowSnap"
BUNDLE_ID="com.local.windowsnap"
DEST="/Applications/${APP_NAME}.app"
STABLE_CERT="WindowSnap Self-Signed"

# Resolve the folder this script lives in (works when double-clicked).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/${APP_NAME}.app"

echo "==> WindowSnap installer"

if [ ! -d "$SRC" ]; then
  echo "    ERROR: Could not find ${APP_NAME}.app next to this installer."
  echo "    Make sure you're running install.command from the same folder/DMG"
  echo "    that contains ${APP_NAME}.app."
  echo ""
  read -n 1 -s -r -p "Press any key to close."
  exit 1
fi

# Quit any running copy so the bundle isn't in use during replacement.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Quitting the running copy of ${APP_NAME}..."
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  sleep 1
  pkill -x "$APP_NAME" 2>/dev/null || true
fi

# Decide whether the Accessibility grant needs resetting. macOS keeps the grant
# across updates as long as the code signature is unchanged, so resetting it
# every install would needlessly force re-approval. Only reset when MIGRATING
# from an old build whose signature differs — i.e. the currently installed copy
# is NOT already signed with the stable "$STABLE_CERT" identity (ad-hoc,
# unsigned, or a foreign signature). A fresh install has nothing to clear.
NEEDS_TCC_RESET=0
GRANT_KEPT=0
if [ -d "$DEST" ]; then
  if codesign -dvv "$DEST" 2>&1 | grep -q "Authority=${STABLE_CERT}"; then
    echo "==> Existing install already uses the stable signature — keeping its Accessibility grant."
    GRANT_KEPT=1
  else
    echo "==> Existing install has a different signature — will refresh the Accessibility grant."
    NEEDS_TCC_RESET=1
  fi
fi

# Remove the old version, if present, then copy the new one in.
if [ -d "$DEST" ]; then
  echo "==> Removing the existing version at ${DEST}..."
  rm -rf "$DEST"
fi

echo "==> Installing to ${DEST}..."
cp -R "$SRC" "$DEST"

# Strip the quarantine flag so Gatekeeper doesn't nag on first launch.
echo "==> Clearing the quarantine flag..."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Refresh Finder's cached icon for the bundle.
touch "$DEST" 2>/dev/null || true

if [ "$NEEDS_TCC_RESET" -eq 1 ]; then
  echo "==> Clearing the stale Accessibility entry from the previous signature..."
  tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null \
    && echo "    Stale entry cleared." \
    || echo "    Nothing to clear (or already clean)."
else
  echo "==> Leaving the existing Accessibility grant in place (no signature change)."
fi

echo "==> Launching ${APP_NAME}..."
open "$DEST" || true
sleep 1

if [ "$GRANT_KEPT" -eq 1 ]; then
  # Same signature as the previous install: macOS keeps the existing grant, so
  # there's nothing for the user to do.
  cat <<'NOTE'

==> Done. This update kept your existing Accessibility grant (the signature is
    unchanged), so there's no manual step. WindowSnap is ready to use.
NOTE
else
  echo "==> Opening System Settings → Privacy & Security → Accessibility..."
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

  cat <<'NOTE'

==> Almost done. One manual step (required by macOS, can't be automated):
    In the Accessibility list that just opened, enable WindowSnap.
    If an OLD WindowSnap row won't toggle, select it, click minus (–), then
    add the freshly installed app with plus (+).

    You only need to do this once. Future updates keep the grant because every
    build is signed with the same stable certificate.
NOTE
fi

echo ""
read -n 1 -s -r -p "Installation complete. Press any key to close."
echo ""

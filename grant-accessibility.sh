#!/bin/bash
# Run this AFTER copying WindowSnap.app to /Applications (or wherever you keep
# it). macOS does not allow any app or script to grant Accessibility access on
# its own — that's a hard security boundary. What this script CAN do is remove
# any stale WindowSnap entry left behind by a previous version and open the
# exact settings pane so approving the new build is a single click.
set -e

BUNDLE_ID="com.local.windowsnap"
APP_PATH="${1:-/Applications/WindowSnap.app}"

echo "==> Clearing any stale Accessibility entry for $BUNDLE_ID..."
# Removes only WindowSnap's TCC record; every other app is untouched.
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null \
  && echo "    Stale entry cleared." \
  || echo "    Nothing to clear (or already clean)."

if [ -d "$APP_PATH" ]; then
  echo "==> Launching WindowSnap so macOS registers the new version..."
  open "$APP_PATH" || true
  sleep 1
fi

echo "==> Opening System Settings → Privacy & Security → Accessibility..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<'NOTE'

==> Final manual step (required by macOS — cannot be automated):
    In the Accessibility list that just opened, enable WindowSnap.
    If you see an OLD WindowSnap entry that won't toggle, select it and click
    the minus (–) button, then add the new one with the plus (+) button and
    pick the app you just installed.

    Because this build is signed with the stable "WindowSnap Self-Signed"
    certificate, you should only have to do this ONCE. Future updates keep the
    grant automatically.
NOTE

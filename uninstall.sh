#!/bin/bash
# WindowSnap uninstaller.
#
# IMPORTANT: macOS does not allow an app to remove its OWN Accessibility grant
# after it's deleted (a deleted app can't run code), and it forbids any app from
# editing another app's privacy entry. So the only reliable way to clear the
# Accessibility toggle on removal is to delete the app AND reset its TCC entry
# together, here, while you still have permission to do so.
#
# Run this INSTEAD of dragging WindowSnap to the Trash.
set -e

BUNDLE_ID="com.local.windowsnap"
APP_PATH="${1:-/Applications/WindowSnap.app}"

echo "==> Quitting WindowSnap if it's running..."
osascript -e 'quit app "WindowSnap"' 2>/dev/null || true
sleep 1
# Force-kill any lingering process.
pkill -x WindowSnap 2>/dev/null || true

echo "==> Removing the Accessibility (and any other TCC) grant for $BUNDLE_ID..."
# This clears WindowSnap's entry from the privacy database. Other apps untouched.
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null \
  && echo "    Accessibility entry cleared." \
  || echo "    No Accessibility entry to clear (or already gone)."
# Belt-and-suspenders: clear all categories for this bundle id.
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true

echo "==> Deleting the app bundle..."
if [ -d "$APP_PATH" ]; then
  rm -rf "$APP_PATH"
  echo "    Removed $APP_PATH"
else
  echo "    $APP_PATH not found — skipping."
fi

echo "==> Removing WindowSnap support files..."
rm -rf "$HOME/Library/Application Support/WindowSnap" 2>/dev/null || true
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults delete WindowSnapSettings 2>/dev/null || true

echo ""
echo "==> WindowSnap fully uninstalled, including its Accessibility entry."
echo "    The toggle should no longer appear in System Settings → Privacy &"
echo "    Security → Accessibility. If a greyed-out 'WindowSnap' row still shows,"
echo "    open that pane, select it, and click the minus (–) button."

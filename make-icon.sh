#!/bin/bash
# Generates Icon.icns using ONLY tools built into macOS (swift + iconutil).
# No librsvg or Homebrew dependency. The icon is rendered by render-icon.swift.
set -e

ICONSET="WindowSnap.iconset"
rm -rf "$ICONSET"

echo "==> Rendering icon PNGs with AppKit (render-icon.swift)..."
swift render-icon.swift "$ICONSET"

echo "==> Building Icon.icns with iconutil..."
iconutil -c icns "$ICONSET" -o Icon.icns
rm -rf "$ICONSET"
echo "==> Created Icon.icns"

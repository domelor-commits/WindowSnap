#!/bin/bash
# One-command release prep for WindowSnap's Sparkle auto-updates.
#
#   ./release.sh            build the DMG, sign it, and (re)generate appcast.xml
#   ./release.sh --publish  ...then create the GitHub Release and upload assets
#                           (requires the `gh` CLI, authenticated)
#
# Version comes from Info.plist (CFBundleShortVersionString / CFBundleVersion), so
# bump those before running. Release notes are read from release-notes/<ver>.html
# if present, else a link to the GitHub release is used.
set -e

OWNER="domelor-commits"
REPO="WindowSnap"
APP_NAME="WindowSnap"
DMG="${APP_NAME}.dmg"
APPCAST="appcast.xml"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

SHORT_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILD_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
TAG="v${SHORT_VER}"

echo "==> Preparing ${APP_NAME} ${SHORT_VER} (build ${BUILD_VER}) — tag ${TAG}"

# 1. Build the signed DMG.
./build.sh

# 2. EdDSA-sign the DMG (prints: sparkle:edSignature="…" length="…").
if [ ! -x "$SIGN_UPDATE" ]; then
  echo "ERROR: sign_update not found at $SIGN_UPDATE — run 'swift build' once first." >&2
  exit 1
fi
SIG_ATTRS=$("$SIGN_UPDATE" "$DMG")
echo "    $SIG_ATTRS"

# 3. Assemble appcast.xml (single latest item — the feed URL always points at the
#    latest release's asset, and Sparkle offers the newest item it finds).
URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/${DMG}"
PUBDATE=$(LC_ALL=en_US TZ=UTC date "+%a, %d %b %Y %H:%M:%S +0000")
NOTES_FILE="release-notes/${SHORT_VER}.html"
if [ -f "$NOTES_FILE" ]; then
  DESC=$(cat "$NOTES_FILE")
else
  DESC="<h2>${APP_NAME} ${SHORT_VER}</h2><p>See the <a href=\"https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}\">release notes on GitHub</a>.</p>"
fi

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://github.com/${OWNER}/${REPO}</link>
    <description>Latest ${APP_NAME} updates</description>
    <language>en</language>
    <item>
      <title>Version ${SHORT_VER}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_VER}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VER}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
${DESC}
      ]]></description>
      <enclosure url="${URL}" ${SIG_ATTRS} type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML
echo "==> Wrote ${APPCAST} (enclosure → ${URL})"

# 4. Optionally publish to GitHub Releases.
if [ "$1" = "--publish" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: --publish needs the GitHub CLI (gh), authenticated with 'gh auth login'." >&2
    exit 1
  fi
  echo "==> Creating GitHub Release ${TAG} and uploading ${DMG} + ${APPCAST}..."
  NOTES_ARG=(--generate-notes)
  [ -f "$NOTES_FILE" ] && NOTES_ARG=(--notes-file "$NOTES_FILE")
  gh release create "$TAG" "$DMG" "$APPCAST" \
    --repo "${OWNER}/${REPO}" --title "${APP_NAME} ${SHORT_VER}" "${NOTES_ARG[@]}"
  echo "==> Published. Existing users will be offered ${SHORT_VER} on their next check."
else
  cat <<NEXT

==> Artifacts ready: ${DMG} and ${APPCAST}
    To publish, either re-run with --publish (needs gh), or manually:
      1. Create a GitHub Release on ${OWNER}/${REPO} with tag ${TAG}
      2. Upload BOTH ${DMG} and ${APPCAST} as release assets
    The feed URL (releases/latest/download/appcast.xml) then serves this update.
NEXT
fi

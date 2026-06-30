#!/usr/bin/env bash
# Sign a release zip with Sparkle's EdDSA key and (re)generate appcast.xml.
#
# Run this AFTER ./build.sh release has produced the .app and you've packaged it
# into GitSync-vX.Y.Z.zip. It:
#   1. signs the zip with sign_update (private key from your Keychain)
#   2. writes a new <item> to the TOP of appcast.xml pointing at the GitHub
#      release download URL for that tag
#
# The appcast is served from the repo's main branch via raw.githubusercontent
# (see SUFeedURL in Info.plist), so committing + pushing appcast.xml is what
# actually publishes the update to existing installs.
#
# Usage:
#   Tools/sparkle-release.sh <version> <zip-path> [release-notes-url]
#   e.g. Tools/sparkle-release.sh 1.2.0 GitSync-v1.2.0.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: sparkle-release.sh <version> <zip-path> [notes-url]}"
ZIP="${2:?usage: sparkle-release.sh <version> <zip-path> [notes-url]}"
NOTES_URL="${3:-https://github.com/uPaymeiFixit/git-sync/releases/tag/v${VERSION}}"
APPCAST="appcast.xml"
REPO="uPaymeiFixit/git-sync"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/$(basename "${ZIP}")"

if [[ ! -f "${ZIP}" ]]; then echo "zip not found: ${ZIP}" >&2; exit 1; fi

# Locate sign_update from the resolved SPM artifact.
SIGN_TOOL="$(find .build -path '*Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
if [[ -z "${SIGN_TOOL}" ]]; then
    echo "sign_update not found — run 'swift build' first to resolve Sparkle." >&2
    exit 1
fi

# CFBundleVersion (the build number) — Sparkle compares updates by this. Pull it
# from the freshly built app so it always matches what shipped.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' \
    .build/release/GitSync.app/Contents/Info.plist 2>/dev/null || echo "0")"

# Sign → outputs: sparkle:edSignature="…" length="…"
echo "» signing ${ZIP}"
SIG_ATTRS="$("${SIGN_TOOL}" "${ZIP}")"
echo "  ${SIG_ATTRS}"

# RFC-822 pubDate (Sparkle wants this format).
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

ITEM="        <item>
            <title>Version ${VERSION}</title>
            <link>https://github.com/${REPO}</link>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <pubDate>${PUBDATE}</pubDate>
            <enclosure url=\"${DOWNLOAD_URL}\" type=\"application/octet-stream\" ${SIG_ATTRS} />
        </item>"

if [[ -f "${APPCAST}" ]]; then
    # Insert the new <item> right after the opening <channel> intro (before the
    # first existing <item>, or before </channel> if there are none).
    echo "» inserting item into existing ${APPCAST}"
    tmp="$(mktemp)"
    awk -v item="${ITEM}" '
        !done && /<item>/    { print item; print; done=1; next }
        !done && /<\/channel>/ { print item; print; done=1; next }
        { print }
    ' "${APPCAST}" > "${tmp}"
    mv "${tmp}" "${APPCAST}"
else
    echo "» creating ${APPCAST}"
    cat > "${APPCAST}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>GitSync</title>
        <link>https://raw.githubusercontent.com/${REPO}/main/appcast.xml</link>
        <description>GitSync software updates</description>
        <language>en</language>
${ITEM}
    </channel>
</rss>
EOF
fi

echo
echo "✓ ${APPCAST} updated for v${VERSION} (build ${BUILD_NUMBER})"
echo "  Enclosure: ${DOWNLOAD_URL}"
echo
echo "Next: attach ${ZIP} to the GitHub release, then commit + push ${APPCAST}"
echo "      so existing installs see the update via the raw.githubusercontent feed."

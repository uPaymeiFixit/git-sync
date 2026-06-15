#!/usr/bin/env bash
# Build the menu-bar app and wrap the SPM executable in a .app bundle.
#
# SPM produces a plain Mach-O binary; macOS needs a bundle (Contents/MacOS,
# Contents/Info.plist) to recognize it as an application and honor things
# like LSUIElement (no Dock icon) and CFBundleIdentifier (Launch at Login).
#
# Usage: ./build.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
TARGET_NAME="GitSync"
APP_NAME="GitSync"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo "» swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${TARGET_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "build did not produce ${BIN_PATH}" >&2
    exit 1
fi

echo "» assemble ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
# App icon — regenerate with Tools/make-icns.sh after design changes.
cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# Bundle the Python sync scripts under Resources/scripts so the app is
# self-contained — users don't need to clone the repo to run syncs.
# Live-editing for development: rebuild with ./build.sh after script edits.
echo "» bundle scripts/"
cp -R ../scripts "${APP_BUNDLE}/Contents/Resources/scripts"
# Belt-and-suspenders: strip __pycache__ to keep the bundle small.
find "${APP_BUNDLE}/Contents/Resources/scripts" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# Bundle the glab CLI so users don't need to install it separately. The
# Python scripts hardcode `glab` as the executable, so SyncRunner prepends
# this directory to the child PATH and glab resolves to the bundled copy.
# Auth happens via the GITLAB_TOKEN env var (Settings → Platforms) or a
# pre-existing user-installed glab config, whichever the user prefers.
echo "» bundle glab"
mkdir -p "${APP_BUNDLE}/Contents/Resources/bin"
cp Vendor/glab "${APP_BUNDLE}/Contents/Resources/bin/glab"
chmod +x "${APP_BUNDLE}/Contents/Resources/bin/glab"

# Codesign with a STABLE identity. macOS keychain items remember which signing
# identity may read them; an ad-hoc signature (codesign --sign -) has no stable
# identity — its code hash changes every build — so the keychain ACL never
# matches twice and you're re-prompted for your password for every stored
# secret on every relaunch. Signing with a persistent self-signed identity
# means you grant "Always Allow" once.
#
# Identity resolution:
#   - SIGN_IDENTITY env var wins (set it to a "Developer ID Application: …"
#     identity when you're ready to distribute + notarize for other Macs).
#   - else the local self-signed "GitSync Self-Signed" (run
#     Tools/make-signing-cert.sh once to create it).
#   - else fall back to ad-hoc with a warning (builds still run locally, but
#     the password prompts come back).
SELF_SIGNED_CN="GitSync Self-Signed"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="${SIGN_IDENTITY}"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "${SELF_SIGNED_CN}"; then
    IDENTITY="${SELF_SIGNED_CN}"
else
    IDENTITY="-"
    echo "⚠️  No stable signing identity found — falling back to ad-hoc."
    echo "    Run ./Tools/make-signing-cert.sh once to stop the repeated keychain"
    echo "    password prompts on relaunch."
fi
echo "» codesign --sign \"${IDENTITY}\""
codesign --sign "${IDENTITY}" --force --timestamp=none --options=runtime "${APP_BUNDLE}"

echo
echo "✓ Built ${APP_BUNDLE}"
echo
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
echo "First launch may require: xattr -d com.apple.quarantine /Applications/${APP_NAME}.app"

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

# Bundle the Python sync scripts under Resources/scripts so the app is
# self-contained — users don't need to clone the repo to run syncs.
# Live-editing for development: rebuild with ./build.sh after script edits.
echo "» bundle scripts/"
cp -R ../scripts "${APP_BUNDLE}/Contents/Resources/scripts"
# Belt-and-suspenders: strip __pycache__ to keep the bundle small.
find "${APP_BUNDLE}/Contents/Resources/scripts" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# Codesign with an ad-hoc signature so macOS will load the bundle. Without
# this, Gatekeeper still allows launch (the user gets the "developer cannot
# be verified" dialog) but spawning the app loses Keychain access on macOS
# 15+. Ad-hoc sig is enough for personal builds; replace with a Developer
# ID Application identity for sharing.
echo "» codesign --sign -"
codesign --sign - --force --timestamp=none --options=runtime "${APP_BUNDLE}"

echo
echo "✓ Built ${APP_BUNDLE}"
echo
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
echo "First launch may require: xattr -d com.apple.quarantine /Applications/${APP_NAME}.app"

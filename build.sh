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

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "» assemble ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
# App icon — regenerate with Tools/make-icns.sh after design changes.
cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# (The sync engine is now pure Swift — no bundled Python scripts or glab CLI.)

# ---- Sparkle (auto-update) ----------------------------------------------
# SPM only LINKS Sparkle.framework (copies it next to the binary); it does NOT
# embed it in a bundle. So we copy it into Contents/Frameworks ourselves. The
# binary loads it via @rpath/Sparkle.framework/… — add an rpath that resolves
# Contents/Frameworks from Contents/MacOS.
SPARKLE_SRC="${BIN_DIR}/Sparkle.framework"
if [[ -d "${SPARKLE_SRC}" ]]; then
    echo "» embed Sparkle.framework"
    # -R preserves the Versions/B symlink farm a framework relies on.
    cp -R "${SPARKLE_SRC}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    # The binary already has an @loader_path rpath (→ Contents/MacOS); add the
    # Frameworks dir so @rpath/Sparkle.framework resolves. Idempotent-ish:
    # install_name_tool errors if it's already present, so ignore that.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
else
    echo "⚠️  Sparkle.framework not found at ${SPARKLE_SRC} — auto-update will be disabled."
fi

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
# Sign INSIDE-OUT. A nested bundle must be signed before its container, or the
# container's signature seals a then-modified child and codesign --verify fails.
# Sparkle ships its own helper executables/XPC services/nested app, each of which
# must carry a valid signature under OUR identity so Library Validation lets the
# framework load into our (same-identity) process.
#
# NOTE: no --options=runtime here. The hardened runtime's Library Validation
# only trusts code from the SAME Team ID (or Apple). A self-signed identity has
# NO Team ID, so a hardened-runtime app would refuse to load the (same self-
# signed) Sparkle framework and crash on first updater use. Dropping the
# hardened runtime for self-signed builds is the correct trade; a real
# distribution build (SIGN_IDENTITY=Developer ID + notarization) should add it
# back along with proper Team-ID-based validation.
sign() {
    codesign --sign "${IDENTITY}" --force --timestamp=none "$@"
}

# Sign one path if it exists (no short-circuit `&&`, which trips `set -e` when
# the test is false).
sign_if() { if [[ -e "$1" ]]; then sign "$1"; fi; }

FW="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${FW}" ]]; then
    echo "» codesign Sparkle helpers (inside-out)"
    V="${FW}/Versions/B"
    # XPC services first (deepest), then the nested updater app + its embedded
    # binary, then the Autoupdate CLI, then the dylib itself.
    sign_if "${V}/XPCServices/Downloader.xpc"
    sign_if "${V}/XPCServices/Installer.xpc"
    if [[ -d "${V}/Updater.app" ]]; then
        # Sign the nested updater app's executable first, then the app wrapper.
        sign_if "${V}/Updater.app/Contents/MacOS/Updater"
        sign "${V}/Updater.app"
    fi
    sign_if "${V}/Autoupdate"
    sign "${V}/Sparkle"
    # Seal the framework (versioned bundle — sign the version dir).
    sign "${FW}"
fi

echo "» codesign ${APP_NAME}.app"
# Sign the app last so it seals the now-signed framework. Deep so any
# straggler is covered.
codesign --sign "${IDENTITY}" --force --timestamp=none --deep "${APP_BUNDLE}"

# Fail the build if the result doesn't verify — a broken signature would only
# surface as a crash on first updater use, far from here.
echo "» codesign --verify"
codesign --verify --strict "${APP_BUNDLE}" \
    && echo "  signature OK" \
    || { echo "  signature verification FAILED" >&2; exit 1; }

echo
echo "✓ Built ${APP_BUNDLE}"
echo
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
echo "First launch may require: xattr -d com.apple.quarantine /Applications/${APP_NAME}.app"

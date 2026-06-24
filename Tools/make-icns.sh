#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from the Swift icon renderer.
# Usage: Tools/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "» render 1024px master"
swift Tools/make-icon.swift "${WORK}/master.png"

ICONSET="${WORK}/GitSync.iconset"
mkdir -p "${ICONSET}"

# iconutil wants the full classic size ladder; everything downsamples
# from the 1024 master.
for entry in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
             128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
             512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    px="${entry%%:*}"; name="${entry##*:}"
    sips -z "${px}" "${px}" "${WORK}/master.png" \
        --out "${ICONSET}/${name}.png" >/dev/null
done

echo "» iconutil -c icns"
iconutil -c icns "${ICONSET}" -o Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns"

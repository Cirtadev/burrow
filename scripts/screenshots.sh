#!/bin/bash
# Renders the screenshots with sample data from the latest development build (scripts/build-app.sh; it works while
# the VPN is up), as lossless WebP: docs/screenshots at 1x for the README and the guide, site/img at 2x for the
# website. Needs cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DerivedData/Build/Products/Release/Burrow.app
[ -x "$APP/Contents/MacOS/Burrow" ] || { echo "no build in $APP: run scripts/build-app.sh first" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "needs cwebp: brew install webp" >&2; exit 1; }

SHOTS=$(mktemp -d)
trap 'rm -rf "$SHOTS"' EXIT
mkdir "$SHOTS/1x" "$SHOTS/2x"
"$APP/Contents/MacOS/Burrow" --snapshot "$SHOTS/1x" >/dev/null
"$APP/Contents/MacOS/Burrow" --snapshot "$SHOTS/2x" --scale 2 >/dev/null

for png in "$SHOTS"/1x/*.png; do
    cwebp -quiet -lossless -z 9 "$png" -o "docs/screenshots/$(basename "$png" .png).webp"
done
# snapshot name:site name
for pair in panel-menubar:panel settings:settings sign-in:sign-in sign-in-challenge:challenge routing:routing \
            panel-web-sign-in:web-sign-in; do
    for theme in dark light; do
        cwebp -quiet -lossless -z 9 "$SHOTS/2x/${pair%%:*}-$theme.png" -o "site/img/${pair##*:}-$theme.webp"
    done
done
echo "Updated docs/screenshots and site/img"

#!/bin/bash
# Renders the website's screenshots (site/img) at 2x with sample data, from the latest development build
# (scripts/build-app.sh; it works while the VPN is up). Needs cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DerivedData/Build/Products/Release/Burrow.app
[ -x "$APP/Contents/MacOS/Burrow" ] || { echo "no build in $APP: run scripts/build-app.sh first" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "needs cwebp: brew install webp" >&2; exit 1; }

SHOTS=$(mktemp -d)
trap 'rm -rf "$SHOTS"' EXIT
"$APP/Contents/MacOS/Burrow" --snapshot "$SHOTS" --scale 2 >/dev/null
# snapshot name:site name
for pair in panel-menubar:panel settings:settings sign-in:sign-in sign-in-challenge:challenge routing:routing \
            panel-web-sign-in:web-sign-in; do
    for theme in dark light; do
        cwebp -quiet -lossless -z 9 "$SHOTS/${pair%%:*}-$theme.png" -o "site/img/${pair##*:}-$theme.webp"
    done
done
echo "Updated site/img"

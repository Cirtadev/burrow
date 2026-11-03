#!/bin/bash
# Publishes the release in build/release as a GitHub release of Cirtadev/burrow: the DMG, ZIP, AGPL source,
# SHA256SUMS and release/appcast.xml (Sparkle reads the newest release's appcast.xml). Uses the `gh` CLI.
# Run it yourself when you want the release public; it refuses if the source archive still holds private data.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=Cirtadev/burrow
OUT=build/release
APP=$OUT/notarized/Burrow.app
APPCAST=release/appcast.xml
die() { echo "error: $*" >&2; exit 1; }

[ -d "$APP" ] || die "no notarized app in $APP: run scripts/release.sh and scripts/notarize.sh first"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
for file in "$OUT/Burrow-$VERSION.dmg" "$OUT/Burrow-$VERSION.zip" "$OUT/Burrow-$VERSION-source.tar.gz" "$OUT/SHA256SUMS" "$APPCAST"; do
    [ -f "$file" ] || die "missing $file"
done
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" \
    || die "$APPCAST has no entry for $VERSION"

# The owner's own VPN details must never ship in the public source (see README › Release). They are listed, one
# extended regex per line, in scripts/private-patterns.local, which stays out of git.
PATTERNS=scripts/private-patterns.local
if [ -s "$PATTERNS" ]; then
    PRIVATE=$(grep -v '^#' "$PATTERNS" | grep . | paste -sd '|' -)
    CHECK=$(mktemp -d)
    trap 'rm -rf "$CHECK"' EXIT
    tar -xzf "$OUT/Burrow-$VERSION-source.tar.gz" -C "$CHECK"
    if LEAKS=$(grep -rIl -i -E "$PRIVATE" "$CHECK" --exclude-dir=third_party); then
        echo "$LEAKS" | sed "s|$CHECK/||" >&2
        die "the source archive still contains private details (files above); scrub them and rebuild before publishing"
    fi
else
    echo "note: no $PATTERNS, so the source archive isn't checked for private details"
fi

gh repo view "$REPO" >/dev/null 2>&1 || die "github.com/$REPO doesn't exist yet (create it public; Sparkle can't read private releases)"
[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = "PUBLIC" ] || die "$REPO must be public for Sparkle to download updates"

echo "About to publish Burrow $VERSION to https://github.com/$REPO/releases/tag/v$VERSION"
read -r -p "Type yes to continue: " answer
[ "$answer" = "yes" ] || die "cancelled"

gh release create "v$VERSION" --repo "$REPO" --title "Burrow $VERSION" \
    --notes "Download Burrow-$VERSION.dmg, open it and drag Burrow to Applications (macOS 15 or later). Source code: Burrow-$VERSION-source.tar.gz (AGPL-3.0)." \
    "$OUT/Burrow-$VERSION.dmg" "$OUT/Burrow-$VERSION.zip" "$OUT/Burrow-$VERSION-source.tar.gz" "$OUT/SHA256SUMS" "$APPCAST"
echo "Published. Burrow's update feed: https://github.com/$REPO/releases/latest/download/appcast.xml"

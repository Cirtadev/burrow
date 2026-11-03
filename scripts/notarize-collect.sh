#!/bin/bash
# Waits for the notarization that scripts/notarize.sh uploaded (never uploads itself), then packages the
# notarized, stapled app: Burrow-<version>.dmg and .zip, the Sparkle entry in release/appcast.xml, checksums.
# notarize.sh runs it; run it yourself when that gave up waiting. Run it in Terminal.app.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/release
ARCHIVE=$OUT/Burrow.xcarchive
SPARKLE_BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
step() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }

[ -d "$ARCHIVE" ] || die "no $ARCHIVE: run scripts/release.sh and scripts/notarize.sh first"

step "Waiting for Apple to finish the notarization already uploaded"
APP=$OUT/notarized/Burrow.app
APPCAST=release/appcast.xml
for attempt in $(seq 1 240); do
    rm -rf "$OUT/notarized"
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" > "$OUT/notarized.log" 2>&1; then
        break
    fi
    if ! grep -q "is processing" "$OUT/notarized.log"; then
        echo
        grep -v -E '^\s*$|IDEDistributionLogging' "$OUT/notarized.log" | tail -5
        die "not processing any more but not notarized either (see above, or Xcode › Window › Organizer)"
    fi
    printf '.'
    sleep 30
done
[ -d "$APP" ] || die "still processing after 2 hours; Apple's queue is slow today, run this again later"
echo

step "Checking the notarized app"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

VERSION=$(plist CFBundleShortVersionString "$APP/Contents/Info.plist")
BUILD=$(plist CFBundleVersion "$APP/Contents/Info.plist")
FEED_URL=$(plist SUFeedURL "$APP/Contents/Info.plist")
MIN_OS=$(plist LSMinimumSystemVersion "$APP/Contents/Info.plist")
DMG_NAME=Burrow-$VERSION.dmg
DMG=$OUT/$DMG_NAME
# GitHub serves the newest release's appcast.xml at .../releases/latest/download/; each DMG stays at its own
# release (.../releases/download/v<version>/) so older appcast entries keep working.
case "$FEED_URL" in
    https://github.com/*/releases/latest/download/*) DOWNLOAD_BASE="${FEED_URL%%/releases/*}/releases/download/v$VERSION" ;;
    *) DOWNLOAD_BASE=${FEED_URL%/*} ;;
esac

step "Making $DMG_NAME and Burrow-$VERSION.zip around the notarized app"
# The disk image stays UNSIGNED: Gatekeeper rejects a signed disk image that isn't notarized itself, but
# doesn't assess an unsigned one, and the app inside carries its own stapled notarization.
rm -rf "$OUT/dmg" "$DMG" "$OUT/Burrow-$VERSION.zip"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Burrow.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Burrow $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$OUT/dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Burrow-$VERSION.zip"

step "Signing the update for Sparkle"
if SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG"); then
    {
        echo "        <item>"
        echo "            <title>Burrow $VERSION</title>"
        echo "            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
        echo "            <sparkle:version>$BUILD</sparkle:version>"
        echo "            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
        echo "            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>"
        echo "            <enclosure url=\"$DOWNLOAD_BASE/$DMG_NAME\" $SIGNATURE type=\"application/x-apple-diskimage\"/>"
        echo "        </item>"
    } > "$OUT/appcast-item.xml"
    mkdir -p "$(dirname "$APPCAST")"
    [ -f "$APPCAST" ] || cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Burrow</title>
        <link>$FEED_URL</link>
        <description>Burrow updates</description>
        <language>en</language>
        <!-- releases: scripts/release.sh adds the newest below this line -->
    </channel>
</rss>
XML
    if grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"; then
        echo "$APPCAST already lists build $BUILD; left it unchanged ($OUT/appcast-item.xml has the new entry)"
    else
        awk -v item="$OUT/appcast-item.xml" \
            '{ print } /<!-- releases:/ { while ((getline line < item) > 0) print line }' "$APPCAST" > "$OUT/appcast.xml"
        mv "$OUT/appcast.xml" "$APPCAST"
        echo "Added Burrow $VERSION ($BUILD) to $APPCAST"
    fi
else
    echo "warning: sign_update failed; $OUT/appcast-item.xml is stale"
fi

step "SHA-256"
(cd "$OUT" && shasum -a 256 "$DMG_NAME" "Burrow-$VERSION.zip" Burrow-*-source.tar.gz 2>/dev/null | tee SHA256SUMS)

step "Done"
echo "Distribute: $DMG (or $OUT/Burrow-$VERSION.zip): notarized app, opens without warnings on macOS $MIN_OS+."
echo "Publish (after checking everything): scripts/publish.sh"

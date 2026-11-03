#!/bin/bash
# Release build for distribution outside the Mac App Store, all in build/release/:
#   Burrow-<version>.dmg            Developer ID-signed app; notarized and stapled when the "burrow-notary"
#                                   notarytool profile exists, otherwise signed only (and the script says so)
#   appcast-item.xml                the Sparkle entry for it (merged into release/appcast.xml when notarized)
#   Burrow-<version>-source.tar.gz  the corresponding source, with OpenVPNAdapter and Sparkle (AGPL)
#   SHA256SUMS
# Uploads and publishes nothing. README › Release has the one-time setup and the upload steps.
# Run it in Terminal.app, not from a sandboxed tool: it uses your Xcode account (-allowProvisioningUpdates),
# and an xcodebuild that cannot read that account's keychain token drops it from Xcode › Settings › Accounts.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=GXHYVQ677L
IDENTITY="Developer ID Application: Cirtadev GmbH ($TEAM)"
NOTARY_PROFILE=${NOTARY_PROFILE:-burrow-notary}
OUT=build/release
DERIVED=build/DerivedData
SPARKLE_BIN=$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin
APPCAST=release/appcast.xml
SYSEX_PATH=Contents/Library/SystemExtensions/dev.cirta.burrow.tunnel.systemextension

step() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }

IDENTITIES=$(security find-identity -v -p codesigning)
grep -q "\"$IDENTITY\"" <<< "$IDENTITIES" || die "no valid \"$IDENTITY\" identity in the keychain"
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
if [ -f "$APPCAST" ] && grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"; then
    die "build $BUILD is already in $APPCAST: raise CURRENT_PROJECT_VERSION (and MARKETING_VERSION) in project.yml"
fi

NOTARIZE=1
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=0
    echo "No notarytool profile \"$NOTARY_PROFILE\": building a signed, NOT notarized disk image (README › Release)."
fi

# Keep earlier releases: move the previous build/release aside instead of deleting its DMGs and archive.
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
    previous=unknown
    if [ -f "$OUT/Burrow.xcarchive/Info.plist" ]; then
        previous=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" \
            "$OUT/Burrow.xcarchive/Info.plist" 2>/dev/null | tr -cd '[:alnum:]._-')
        previous=${previous:-unknown}
    fi
    mkdir -p build/releases
    mv "$OUT" "build/releases/$previous-$(date +%Y%m%d-%H%M%S)"
    echo "Moved the previous release ($previous) to build/releases/."
fi
mkdir -p "$OUT"

step "Archiving (log: $OUT/archive.log)"
xcodegen generate --quiet
xcodebuild -project Burrow.xcodeproj -scheme Burrow -configuration Release -derivedDataPath "$DERIVED" \
    -archivePath "$OUT/Burrow.xcarchive" -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive.log" | sort -u | head -20; die "archive failed"; }

step "Exporting with Developer ID (log: $OUT/export.log)"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF
# Automatic signing creates the Developer ID provisioning profiles (with the Network Extension and System
# Extension capabilities) for dev.cirta.burrow and dev.cirta.burrow.tunnel when they don't exist yet.
# Apple's timestamp server sometimes doesn't answer: try again before giving up.
for attempt in 1 2 3; do
    rm -rf "$OUT/export"
    xcodebuild -exportArchive -archivePath "$OUT/Burrow.xcarchive" -exportPath "$OUT/export" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 && break
    grep -iE "error" "$OUT/export.log" | sort -u | head -20
    grep -qiE "timestamp (service is not available|was expected)" "$OUT/export.log" && [ "$attempt" -lt 3 ] || die "export failed"
    echo "The timestamp service did not answer; trying again in 30 s."
    sleep 30
done

APP=$OUT/export/Burrow.app
SYSEX=$APP/$SYSEX_PATH
[ -d "$SYSEX" ] || die "the exported app has no $SYSEX_PATH"
VERSION=$(plist CFBundleShortVersionString "$APP/Contents/Info.plist")
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
[ "$(plist CFBundleVersion "$APP/Contents/Info.plist")" = "$BUILD" ] || die "unexpected CFBundleVersion"
[ "$(plist SUPublicEDKey "$APP/Contents/Info.plist")" != "SPARKLE_PUBLIC_KEY_PLACEHOLDER" ] || die "SUPublicEDKey is not set"

step "Checking signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
for code in "$APP" "$SYSEX"; do
    # Capture first: with pipefail, `codesign … | grep -q` fails when grep stops reading early.
    name=$(basename "$code")
    signature=$(codesign -dvv "$code" 2>&1)
    entitlements=$(codesign -d --entitlements - --xml "$code" 2>/dev/null)
    profile=$(security cms -D -i "$code/Contents/embedded.provisionprofile" 2>/dev/null)
    grep -q "^Authority=$IDENTITY" <<< "$signature" || die "$name is not signed with $IDENTITY"
    grep -q '^Timestamp=' <<< "$signature" || die "$name has no secure timestamp"
    grep -q '^CodeDirectory.*flags=.*runtime' <<< "$signature" || die "$name lacks the hardened runtime"
    # Developer ID needs the -systemextension variant of the Network Extension entitlement, in app and extension.
    grep -q '<string>packet-tunnel-provider-systemextension</string>' <<< "$entitlements" \
        || die "$name lacks packet-tunnel-provider-systemextension (see README › Release)"
    [ "$(plutil -extract ProvisionsAllDevices raw -o - - <<< "$profile" 2>/dev/null)" = true ] \
        || die "$name does not embed a Developer ID provisioning profile"
    echo "$name: Developer ID ($(plutil -extract Name raw -o - - <<< "$profile")), hardened runtime, timestamp, packet-tunnel-provider-systemextension"
done
# Until it is notarized, Gatekeeper answers "rejected, source=Unnotarized Developer ID".
spctl -a -vv -t exec "$APP" 2>&1 || true

notarize() {
    local file=$1 result=$OUT/notary-$(basename "$1").json
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result" || true
    local status id
    status=$(plutil -extract status raw -o - "$result" 2>/dev/null || echo "no answer")
    id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
    if [ "$status" != "Accepted" ]; then
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-log-$(basename "$file").json" || true
        die "notarizing $(basename "$file"): $status (details in $OUT/notary-log-$(basename "$file").json)"
    fi
    echo "$(basename "$file"): notarized ($id)"
}

if [ "$NOTARIZE" -eq 1 ]; then
    # Notarize and staple the app before it goes into the disk image, so the copy in /Applications carries its
    # ticket; then the disk image itself.
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/Burrow-notarize.zip"
    notarize "$OUT/Burrow-notarize.zip"
    rm "$OUT/Burrow-notarize.zip"
    xcrun stapler staple "$APP"
fi

step "Making $DMG_NAME"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Burrow.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Burrow $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$OUT/dmg"
codesign --sign "$IDENTITY" --timestamp "$DMG" || { sleep 30; codesign --sign "$IDENTITY" --timestamp "$DMG"; }
codesign --verify --strict "$DMG"

if [ "$NOTARIZE" -eq 1 ]; then
    step "Notarizing $DMG_NAME"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG"
    spctl -a -vv -t exec "$APP"
fi

step "Signing the update for Sparkle"
# The EdDSA private key is in the login keychain (Sparkle's generate_keys); macOS may ask to allow sign_update.
if SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG"); then
    NOTES=release/notes/$VERSION.html
    {
        echo "        <item>"
        echo "            <title>Burrow $VERSION</title>"
        echo "            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
        echo "            <sparkle:version>$BUILD</sparkle:version>"
        echo "            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
        echo "            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>"
        [ -f "$NOTES" ] && echo "            <description><![CDATA[$(cat "$NOTES")]]></description>"
        echo "            <enclosure url=\"$DOWNLOAD_BASE/$DMG_NAME\" $SIGNATURE type=\"application/x-apple-diskimage\"/>"
        echo "        </item>"
    } > "$OUT/appcast-item.xml"
    if [ "$NOTARIZE" -eq 1 ]; then
        mkdir -p "$(dirname "$APPCAST")"
        [ -f "$APPCAST" ] || cat > "$APPCAST" <<EOF
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
EOF
        awk -v item="$OUT/appcast-item.xml" \
            '{ print } /<!-- releases:/ { while ((getline line < item) > 0) print line }' "$APPCAST" > "$OUT/appcast.xml"
        mv "$OUT/appcast.xml" "$APPCAST"
        echo "Added Burrow $VERSION ($BUILD) to $APPCAST"
    else
        echo "Not notarized: the entry is in $OUT/appcast-item.xml only, not in $APPCAST."
    fi
else
    echo "warning: sign_update failed, so there is no appcast entry (README › Release › Sparkle key)."
fi

step "Packing the corresponding source (AGPL)"
SRC_NAME=Burrow-$VERSION-source
mkdir -p "$OUT/$SRC_NAME/third_party"
# re/ holds third-party binaries and their analysis: never part of a release; private-patterns.local lists the
# owner's private details for publish.sh's check, so it must not ship either.
rsync -a --exclude /build --exclude /re --exclude /scripts/private-patterns.local --exclude .build --exclude .swiftpm --exclude '*.xcodeproj' \
    --exclude DerivedData --exclude .DS_Store --exclude 'build-*.log' --exclude .git ./ "$OUT/$SRC_NAME/"
# OpenVPNAdapter (with OpenVPN 3 Core) is already in ThirdParty/, with Burrow's change listed in BURROW-CHANGES.md.
for package in Sparkle; do
    checkout=$DERIVED/SourcePackages/checkouts/$package
    rsync -a --exclude .git "$checkout/" "$OUT/$SRC_NAME/third_party/$package/"
    echo "$package $(git -C "$checkout" rev-parse HEAD)" >> "$OUT/$SRC_NAME/third_party/REVISIONS"
done
tar -C "$OUT" -czf "$OUT/$SRC_NAME.tar.gz" "$SRC_NAME"
rm -rf "$OUT/$SRC_NAME"

step "SHA-256"
(cd "$OUT" && shasum -a 256 "$DMG_NAME" "$SRC_NAME.tar.gz" | tee SHA256SUMS)

step "Done"
if [ "$NOTARIZE" -eq 1 ]; then
    echo "Notarized and stapled: $DMG"
    echo "To publish, upload to ${DOWNLOAD_BASE}/: $DMG_NAME, $SRC_NAME.tar.gz and $APPCAST (as appcast.xml)."
else
    echo "Signed with Developer ID but NOT notarized: $DMG"
    echo "Gatekeeper blocks it on other Macs. Store the notary credentials once (README › Release):"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --key <AuthKey_XXXXXXXXXX.p8> --key-id <key ID> --issuer <issuer ID>"
    echo "then run scripts/release.sh again."
fi

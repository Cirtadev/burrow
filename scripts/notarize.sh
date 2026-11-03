#!/bin/bash
# Notarizes the archive made by scripts/release.sh with the Apple ID signed in to Xcode
# (Xcode › Settings › Accounts) — no notarytool credentials needed — then hands over to
# scripts/notarize-collect.sh, which waits for Apple and packages the notarized app (DMG, ZIP, appcast).
# Run it in Terminal: xcodebuild needs your logged-in Xcode account, which sandboxed tools can't reach.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=GXHYVQ677L
OUT=build/release
ARCHIVE=$OUT/Burrow.xcarchive
step() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -d "$ARCHIVE" ] || die "no $ARCHIVE: run scripts/release.sh first"

cat > "$OUT/ExportOptions-notarize.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>destination</key><string>upload</string>
</dict>
</plist>
EOF

step "Uploading to Apple's notary service with your Xcode account"
rm -rf "$OUT/notary-upload"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/notary-upload" \
    -exportOptionsPlist "$OUT/ExportOptions-notarize.plist" -allowProvisioningUpdates > "$OUT/notary-upload.log" 2>&1 \
    || { tail -20 "$OUT/notary-upload.log"; die "upload failed (sign in under Xcode › Settings › Accounts?)"; }

# Waiting, packaging (unsigned DMG + ZIP) and the Sparkle entry live in one place.
exec "$(dirname "$0")/notarize-collect.sh"

#!/bin/bash
# Development build: build/Burrow.app (app + BurrowTunnel system extension) and build/burrowctl.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy it to /Applications/Burrow.app and open it there
#   scripts/build-app.sh --update-profiles  let Xcode create/refresh provisioning profiles (new capabilities,
#                                   new Mac). Needs your Xcode account: run that one in Terminal.app.
# Signed by Xcode's automatic signing with the Cirtadev GmbH team (GXHYVQ677L) and an Apple Development
# certificate: the Network Extension entitlement needs a provisioning profile, so ad-hoc signing is not an option.
# Never sign with the old personal-team certificates in this keychain: they are revoked, and macOS treats
# anything signed with them as malware. Releases are built by scripts/release.sh (Developer ID).
#
# macOS only installs the system extension from an app in /Applications (or anywhere after
# `systemextensionsctl developer on`, which needs SIP off), so test connections with --install.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
PROVISIONING=()
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        # Off by default: an xcodebuild that can't read the Xcode account's keychain token (e.g. from a
        # sandboxed tool) drops the account from Xcode › Settings › Accounts. Everyday builds use the
        # profiles already in ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
        --update-profiles) PROVISIONING=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration) ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

vpn_is_up() {
    scutil --nc list 2>/dev/null | grep 'dev.cirta.burrow' | grep -q -E '\((Connected|Connecting|Reasserting|Disconnecting)\)'
}

# macOS only replaces an activated system extension when its version changes: give every build its own number.
BASE_BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
BUILD_NUMBER="$BASE_BUILD.$(date +%Y%m%d).$(date +%H%M%S | sed 's/^0*//; s/^$/0/')"

mkdir -p build
xcodegen generate --quiet
set +e
xcodebuild -project Burrow.xcodeproj -scheme Burrow -configuration Release \
    -derivedDataPath build/DerivedData \
    ${PROVISIONING[@]+"${PROVISIONING[@]}"} \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > build/xcodebuild.log 2>&1
STATUS=$?
set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/xcodebuild.log | sort -u | head -20
[ "$STATUS" -eq 0 ] || { echo "build failed (full log: build/xcodebuild.log)"; exit 1; }

PRODUCT=build/DerivedData/Build/Products/Release/Burrow.app
# Never swap the app under a live tunnel (an app-extension tunnel dies when its files change; a system
# extension is replaced when the new app activates it).
if vpn_is_up; then
    echo "Burrow's VPN is up: the new build is in $PRODUCT. Disconnect, then run this script again."
    exit 2
fi
rm -rf build/Burrow.app
cp -R "$PRODUCT" build/Burrow.app
codesign --verify --deep --strict build/Burrow.app

(cd BurrowKit && swift build -c release --product burrowctl >/dev/null)
rm -f build/burrowctl && cp "BurrowKit/.build/release/burrowctl" build/burrowctl
codesign --force --sign - build/burrowctl
echo "Built build/Burrow.app ($BUILD_NUMBER) and build/burrowctl"

if [ "$INSTALL" -eq 1 ]; then
    vpn_is_up && { echo "Burrow's VPN is up: not installing. Disconnect, then run this script again."; exit 2; }
    if pgrep -xq Burrow; then
        osascript -e 'tell application id "dev.cirta.burrow" to quit' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Burrow || break; sleep 0.5; done
        pgrep -xq Burrow && { echo "Burrow is still running: quit it, then run this script again."; exit 2; }
    fi
    rm -rf /Applications/Burrow.app
    ditto build/Burrow.app /Applications/Burrow.app
    open /Applications/Burrow.app
    echo "Installed /Applications/Burrow.app. The first time, allow its VPN in System Settings › General ›"
    echo "Login Items & Extensions › Network Extensions."
fi

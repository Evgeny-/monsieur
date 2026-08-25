#!/usr/bin/env bash
# Builds Sources/ into a proper dist/Monsieur.app bundle and signs it.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Monsieur"
CERT_NAME="${CERT_NAME:-Monsieur Dev}"
KEYCHAIN="$HOME/Library/Keychains/monsieur-signing.keychain-db"
KEYCHAIN_PASS="monsieur"
APP="dist/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# The certificate is self-signed and deliberately not added to the system trust
# store, so `find-identity -v` will not list it -- codesign accepts it anyway.
#
# Sign by SHA-1 hash rather than by name. A certificate name is only unique
# within one keychain, and codesign refuses an ambiguous name ("matches ... in
# login.keychain-db and ... in ...") by falling back to whichever it finds
# first, which may be one with a restrictive ACL that blocks the build on a
# password dialog. The hash is unambiguous.
IDENTITY=""
if [ -f "$KEYCHAIN" ]; then
    IDENTITY=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
        | awk '/SHA-1 hash:/ { print $3; exit }')
fi

if [ -n "$IDENTITY" ]; then
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    echo "==> Signing with '$CERT_NAME' ($IDENTITY)"
    codesign --force --deep \
        --keychain "$KEYCHAIN" \
        --entitlements Resources/Monsieur.entitlements \
        -s "$IDENTITY" "$APP"
else
    echo "==> WARNING: no '$CERT_NAME' certificate, falling back to ad-hoc signing."
    echo "    macOS will drop your Accessibility grant on every rebuild."
    echo "    Run 'make cert' once to fix this."
    codesign --force --deep \
        --entitlements Resources/Monsieur.entitlements \
        -s - "$APP"
fi

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "==> Designated requirement:"
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/    /'
echo "==> Built $APP"

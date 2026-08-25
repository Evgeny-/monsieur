#!/usr/bin/env bash
# Creates a self-signed code-signing certificate so macOS TCC keeps the
# Accessibility and Microphone grants across rebuilds.
#
# Why this matters: TCC binds a permission to the app's designated requirement.
# Ad-hoc signing produces `cdhash H"..."`, which changes on every single build,
# so macOS treats each rebuild as a different app and drops the grant. Signing
# with a certificate produces `certificate leaf = H"..."` instead, which is
# stable for the life of the certificate.
#
# The key lives in its own keychain rather than your login keychain, with a
# known password and an open ACL. That is deliberate: it keeps a throwaway dev
# key out of your real keychain, and it means `make install` never stops to pop
# a SecurityAgent dialog at you mid-build.
#
# To undo everything this script does:
#   security delete-keychain ~/Library/Keychains/monsieur-signing.keychain-db
set -euo pipefail

CERT_NAME="${CERT_NAME:-Monsieur Dev}"
KEYCHAIN="$HOME/Library/Keychains/monsieur-signing.keychain-db"
KEYCHAIN_PASS="monsieur"

# Apple's Security framework cannot read the PKCS#12 format OpenSSL 3 writes by
# default (AES-256 + SHA-256 MAC), so use the system LibreSSL, which still emits
# the legacy format `security import` understands.
OPENSSL=/usr/bin/openssl
P12_PASS=monsieur-dev

if [ ! -f "$KEYCHAIN" ]; then
    echo "==> Creating keychain $KEYCHAIN"
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    # No arguments means: never lock on idle, never lock on sleep.
    security set-keychain-settings "$KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Certificate '$CERT_NAME' already present."
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo "==> Generating self-signed code-signing certificate '$CERT_NAME'"
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -subj "/CN=$CERT_NAME" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

    "$OPENSSL" pkcs12 -export -out "$TMP/cert.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$P12_PASS"

    echo "==> Importing"
    # -A: any tool may use this key without a confirmation dialog. That is the
    # whole point -- without it every build after a keychain lock blocks on a
    # SecurityAgent prompt, which makes unattended builds impossible.
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A
fi

# -A alone is not enough on modern macOS. The key also has a *partition list*,
# introduced in Sierra, which gates access independently of the ACL; a freshly
# imported key has none, so codesign blocks on a SecurityAgent password dialog.
# Because this keychain's password is ours, this can be set without any prompt.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1

# Put the keychain on the search list so codesign can find the identity,
# keeping whatever was already there. `list-keychains` prints indented, quoted
# paths, and -s replaces the whole list -- so the existing entries have to be
# unwrapped and passed back verbatim, or the login keychain drops off the list.
EXISTING=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
    line="${line%\"}"; line="${line#\"}"      # strip the surrounding quotes
    [ -n "$line" ] && EXISTING+=("$line")
done < <(security list-keychains -d user)

case " ${EXISTING[*]} " in
    *monsieur-signing*) ;;
    *)
        echo "==> Adding it to the keychain search list"
        security list-keychains -d user -s "${EXISTING[@]}" "$KEYCHAIN" >/dev/null
        ;;
esac

echo
security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" | grep "SHA-1 hash"
echo "Ready. 'make install' will sign with '$CERT_NAME' and will not prompt."

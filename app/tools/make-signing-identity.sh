#!/bin/sh
# Create the self-signed code-signing identity "Yaku Signing" that make-app.sh
# signs with, in a keychain of its own.
#
#   app/tools/make-signing-identity.sh
#
# macOS remembers Accessibility and Screen Recording grants by the app's
# signature. With this identity every rebuild keeps them; without it
# make-app.sh signs ad hoc and macOS asks again after each build.
#
# The identity lives in ~/Library/Keychains/yaku-dev.keychain-db, not the login
# keychain: a key in the login keychain made codesign wait on an authorization
# prompt that never appeared. The keychain password is random and stored in
# ~/Library/Application Support/Yaku/dev-signing/pass (mode 600).
#
# Running it again changes nothing if the identity already exists.
set -eu

NAME="Yaku Signing"
KEYCHAIN="$HOME/Library/Keychains/yaku-dev.keychain-db"
PASS_DIR="$HOME/Library/Application Support/Yaku/dev-signing"
PASS_FILE="$PASS_DIR/pass"

if [ -f "$KEYCHAIN" ] && [ -f "$PASS_FILE" ] \
    && security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists in $KEYCHAIN. Nothing to do."
    exit 0
fi
if [ -f "$KEYCHAIN" ]; then
    echo "error: $KEYCHAIN exists but has no usable \"$NAME\" identity or password file." >&2
    echo "Delete it with: security delete-keychain \"$KEYCHAIN\"  and run this again." >&2
    exit 1
fi

mkdir -p "$PASS_DIR"
chmod 700 "$PASS_DIR"
umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

openssl rand -base64 24 | tr -d '/+=\n' > "$PASS_FILE"
chmod 600 "$PASS_FILE"
KEYCHAIN_PASSWORD=$(cat "$PASS_FILE")
P12_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n')

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# Old-style PKCS12 encryption: the macOS `security` tool cannot read the OpenSSL 3 default.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$P12_PASSWORD" -out "$WORK/identity.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created identity \"$NAME\" in $KEYCHAIN."
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\"" || true
echo "It may show as not trusted; codesign still signs with it by name."

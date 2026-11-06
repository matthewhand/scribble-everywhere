#!/bin/bash
#
# Creates a stable, self-signed code-signing identity ("Palimpsest Ink") so
# macOS TCC keeps Screen Recording / Accessibility grants across rebuilds.
#
# Ad-hoc signing (-) produces a new cdhash on every build, and TCC keys
# permissions on the signature — so each rebuild silently invalidates the
# permission the user just granted. A real certificate has a designated
# requirement (identifier + issuer CN) that survives rebuilds.
#
# Idempotent: exits early if the identity already exists.
#
set -euo pipefail

CN="Palimpsest Ink"
DIR="$(cd "$(dirname "$0")/.." && pwd)/build/signing"
VALID="$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Palimpsest Ink" || true)"
if [ "$VALID" -gt 0 ]; then
    echo "==> Identity \"$CN\" already exists"
    security find-identity -v -p codesigning | grep "$CN"
    exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

echo "==> Generating CA + signing certificate ($DIR)"
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -sha256 -days 3650 -out ca.cer -subj "/CN=$CN CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl genrsa -out signing.key 2048 2>/dev/null
openssl req -new -key signing.key -out signing.csr -subj "/CN=$CN"

cat > codesign.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectAltName=DNS:dev.matthewhand.palimpsest
EOF

openssl x509 -req -in signing.csr -CA ca.cer -CAkey ca.key -CAcreateserial \
    -out signing.cer -days 3650 -sha256 -extfile codesign.ext 2>/dev/null

echo "==> Importing into the login keychain"
openssl rsa -in signing.key -out signing.key.pem 2>/dev/null
security import signing.key.pem -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import signing.cer -k ~/Library/Keychains/login.keychain-db
security import ca.cer -k ~/Library/Keychains/login.keychain-db

echo "==> Trusting the certificate for code signing (user domain, no admin needed)"
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db signing.cer 2>/dev/null || true

echo "==> Done"
security find-identity -v -p codesigning | grep "$CN" || {
    echo "warning: identity not visible yet; open Keychain Access once if codesign can't see it" >&2
    exit 1
}

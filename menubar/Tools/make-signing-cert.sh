#!/usr/bin/env bash
# One-time setup: create a persistent self-signed code-signing identity so
# every GitSync build is signed with the SAME identity. macOS keychain items
# remember which signing identity may read them; with a stable identity you
# grant "Always Allow" ONCE and never get re-prompted on rebuild/relaunch.
#
# Ad-hoc signing (codesign --sign -) has NO stable identity — its code hash
# changes every build, so the keychain ACL never matches twice and you're
# re-prompted for every secret on every relaunch. This fixes that.
#
# This is LOCAL-ONLY. To ship to other Macs you still need an Apple Developer
# ID Application cert ($99/yr) + notarization; build.sh's SIGN_IDENTITY env
# var lets you swap this for that later with no other changes.
#
# Idempotent: re-running detects the existing identity and does nothing.
set -euo pipefail

CERT_CN="GitSync Self-Signed"          # the identity name build.sh looks for
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    echo "✓ Code-signing identity \"$CERT_CN\" already exists. Nothing to do."
    exit 0
fi

echo "» creating self-signed code-signing certificate \"$CERT_CN\""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# OpenSSL config: a self-signed cert with the codeSigning extended key usage.
# codesign REQUIRES the EKU 1.3.6.1.5.5.7.3.3 (code signing) or it rejects the
# identity with "no identity found".
cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# Bundle key+cert into a PKCS#12 for import. macOS's SecKeychainItemImport
# rejects the modern AES/SHA-256 PKCS#12 encoding that newer OpenSSL/LibreSSL
# default to ("MAC verification failed"), so force the legacy SHA1/3DES PBE
# algorithms it understands. A passphrase is REQUIRED for the legacy MAC to
# verify on import (empty-pass p12 trips the same failure), so use a throwaway
# one and pass it to `security import`.
P12PASS="gitsync"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_CN" -out "$TMP/identity.p12" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$P12PASS"

# Import into the login keychain. -T /usr/bin/codesign lets codesign use the
# private key without a per-use password prompt.
echo "» importing into login keychain (you may be asked for your login password once)"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust the cert for code signing. This is what lets the keychain treat builds
# signed by it as a consistent, TRUSTED local identity — without it the
# signature is stable but untrusted, so macOS still re-prompts for every secret
# on each launch (a stable identity alone is necessary but not sufficient).
#
# Use the USER trust domain (no -d): it doesn't need admin and only prompts for
# the login password once via a GUI dialog. The admin/system domain (-d) needs
# sudo and silently no-ops without it — which is why earlier builds stayed
# untrusted. Try user trust first; fall back to admin only if user trust fails.
echo "» trusting the certificate for code signing (you may get one GUI password prompt)"
if security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1; then
    echo "  ✓ trusted in the user domain"
elif security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1; then
    echo "  ✓ trusted in the admin domain"
else
    echo "  ⚠️  could not set trust — signing still works, but you may keep getting"
    echo "      keychain password prompts on launch. See README for the manual fix."
fi

# Allow codesign to use the key non-interactively going forward.
security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$(security default-keychain | tr -d ' \"')" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    echo "✓ Created code-signing identity \"$CERT_CN\"."
    echo "  build.sh will now sign with it automatically."
    echo "  On the next launch, click \"Always Allow\" on each keychain prompt ONE"
    echo "  more time — they won't come back as long as you keep this identity."
else
    echo "✗ Identity not found after import. See errors above." >&2
    exit 1
fi

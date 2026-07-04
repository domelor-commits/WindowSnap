#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain that
# you can reuse for EVERY WindowSnap build. Because the signing identity stays
# constant across versions, macOS keeps your Accessibility grant instead of
# treating each new build as a brand-new app.
#
# Run this ONCE. After that, build.sh will sign with it automatically.
set -e

CERT_NAME="WindowSnap Self-Signed"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "Certificate \"$CERT_NAME\" already exists. Nothing to do."
  echo "build.sh will use it automatically."
  exit 0
fi

echo "==> Creating self-signed code-signing certificate: $CERT_NAME"

# Build a temporary OpenSSL config for a code-signing cert.
TMPDIR_CERT="$(mktemp -d)"
CONF="$TMPDIR_CERT/cert.conf"
cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

KEY="$TMPDIR_CERT/key.pem"
CRT="$TMPDIR_CERT/cert.pem"
P12="$TMPDIR_CERT/cert.p12"

openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CRT" \
  -days 3650 -nodes -config "$CONF" >/dev/null 2>&1

# Bundle into a PKCS#12. Two OpenSSL-3 quirks bite here:
#   1. OpenSSL 3 (e.g. Homebrew's) defaults to a PKCS#12 MAC/encryption scheme
#      that Apple's `security` tool cannot verify — the import fails with
#      "MAC verification failed during PKCS12 import". The legacy SHA1/3DES
#      scheme (-legacy, only present on OpenSSL 3) is compatible; LibreSSL and
#      older OpenSSL produce a compatible file without it.
#   2. `security import` also rejects an EMPTY-password PKCS#12 MAC, so use a
#      throwaway password and pass it through to the import with -P.
P12_PW="windowsnap-selfsigned"
P12_ARGS=(-export -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES)
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  P12_ARGS+=(-legacy)
fi
openssl pkcs12 "${P12_ARGS[@]}" -inkey "$KEY" -in "$CRT" -out "$P12" \
  -passout pass:"$P12_PW" >/dev/null 2>&1

# Import into the login keychain.
security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -T /usr/bin/codesign -P "$P12_PW" >/dev/null 2>&1 \
  || security import "$P12" -k "$HOME/Library/Keychains/login.keychain" \
       -T /usr/bin/codesign -P "$P12_PW" >/dev/null 2>&1

# Trust it for code signing so codesign will use it without prompting.
# (You may be asked for your login password once.)
echo "==> Granting codesign access to the key (you may be prompted once)..."
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

# Verify the identity actually landed — the steps above suppress their output,
# so without this check a failed import would look like success.
if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "ERROR: certificate import failed — \"$CERT_NAME\" is not in the keychain." >&2
  echo "       (Common cause: an OpenSSL that produced an incompatible PKCS#12.)" >&2
  exit 1
fi

rm -rf "$TMPDIR_CERT"

echo ""
echo "==> Done. Created \"$CERT_NAME\"."
echo "    Now run ./build.sh — it will sign with this identity every time,"
echo "    so the Accessibility grant survives version updates."
echo ""
echo "    First launch of the FIRST signed build still needs you to add"
echo "    WindowSnap to Accessibility once. After that, updates keep the grant"
echo "    as long as you don't change the certificate or bundle identifier."

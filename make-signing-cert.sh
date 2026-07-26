#!/bin/bash
set -e

# Creates a self-signed code-signing certificate in the login keychain so
# bundle.sh can give the app a stable code identity. TCC keys Accessibility and
# Microphone grants to that identity, so without it every rebuild looks like a
# new app and the permission has to be granted again.

IDENTITY="${SIGN_IDENTITY:-kbdcmd-dev}"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "Signing identity '${IDENTITY}' already exists."
  exit 0
fi

TMPDIR_CERT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_CERT}"' EXIT

cat >"${TMPDIR_CERT}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = ${IDENTITY}

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "Generating self-signed code-signing certificate '${IDENTITY}'..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "${TMPDIR_CERT}/openssl.cnf" \
  -keyout "${TMPDIR_CERT}/key.pem" \
  -out "${TMPDIR_CERT}/cert.pem" 2>/dev/null

openssl pkcs12 -export \
  -inkey "${TMPDIR_CERT}/key.pem" \
  -in "${TMPDIR_CERT}/cert.pem" \
  -name "${IDENTITY}" \
  -passout pass: \
  -out "${TMPDIR_CERT}/bundle.p12"

security import "${TMPDIR_CERT}/bundle.p12" \
  -k "${HOME}/Library/Keychains/login.keychain-db" \
  -P "" -T /usr/bin/codesign

# Let codesign use the key without an interactive keychain prompt on each build.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -k "" "${HOME}/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

echo "Trusting the certificate for code signing (may prompt for your password)..."
sudo security add-trusted-cert -d -r trustAsRoot \
  -p codeSign -k /Library/Keychains/System.keychain \
  "${TMPDIR_CERT}/cert.pem"

echo "Done. '${IDENTITY}' is ready; run 'make build'."

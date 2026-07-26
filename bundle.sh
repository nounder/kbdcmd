#!/bin/bash
set -e

APP_NAME="Kbdcmd"
BUNDLE_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
TARGET=${TARGET:-release}

echo "Building kbdcmd-app..."
swift build -c $TARGET --product kbdcmd-app

echo "Creating app bundle..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy executable
cp .build/$TARGET/kbdcmd-app "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
cp Sources/Desktop/Resources/Info.plist "${CONTENTS_DIR}/Info.plist"

# Copy icon
cp Sources/Desktop/Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" >"${CONTENTS_DIR}/PkgInfo"

# Sign with a certificate so TCC (Accessibility, Microphone) keeps the
# permission grant across rebuilds. Ad-hoc signing has no certificate to anchor
# to, so its designated requirement is a hash of the executable and every
# rebuild reads as a new app. SIGN_IDENTITY=- opts back into that.
SIGN_IDENTITY="${SIGN_IDENTITY:-kbdcmd-dev}"
if [ "$SIGN_IDENTITY" != "-" ] &&
  ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "Signing identity '${SIGN_IDENTITY}' not found; run ./make-signing-cert.sh" >&2
  echo "Falling back to ad-hoc signing (permissions will reset each rebuild)." >&2
  SIGN_IDENTITY="-"
fi

echo "Signing app bundle with '${SIGN_IDENTITY}'..."
codesign --force --sign "$SIGN_IDENTITY" \
  --identifier "org.libred.kbdcmd" \
  --entitlements Sources/Desktop/Resources/Kbdcmd.entitlements \
  --options runtime \
  --timestamp=none \
  "${BUNDLE_DIR}"

codesign --verify --strict "${BUNDLE_DIR}"

echo "App bundle created at: ${BUNDLE_DIR}"

#!/bin/bash
set -e

APP_NAME="Kbdcmd"
BUNDLE_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building kbdcmd-app..."
swift build -c release --product kbdcmd-app

echo "Creating app bundle..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy executable
cp .build/release/kbdcmd-app "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
cp Sources/Desktop/Resources/Info.plist "${CONTENTS_DIR}/Info.plist"

# Copy icon
cp Sources/Desktop/Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" >"${CONTENTS_DIR}/PkgInfo"

echo "App bundle created at: ${BUNDLE_DIR}"

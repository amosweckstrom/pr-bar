#!/usr/bin/env bash
#
# Builds PRBar as a release binary, assembles a proper .app bundle around it,
# and ad-hoc code-signs it. Pass --install to also copy it into /Applications.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PR Bar"
EXECUTABLE="PRBar"
BUNDLE_ID="com.amosweckstrom.pr-bar"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

echo "==> swift build -c release"
swift build -c release

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${BUILD_DIR}/${EXECUTABLE}" "${CONTENTS}/MacOS/${EXECUTABLE}"
cp "bundle/Info.plist" "${CONTENTS}/Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

echo "==> Ad-hoc code signing"
codesign --force --options runtime \
    --entitlements "bundle/PRBar.entitlements" \
    --sign - \
    "${APP_DIR}"

echo "==> Verifying signature"
codesign --verify --verbose "${APP_DIR}"

echo "Built ${APP_DIR}"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${DEST}"
    rm -rf "${DEST}"
    cp -R "${APP_DIR}" "${DEST}"
    echo "Installed. Launch from /Applications or Spotlight."
fi

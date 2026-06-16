#!/usr/bin/env bash
#
# Builds LGTM as a release binary, assembles a proper .app bundle around it,
# and ad-hoc code-signs it. Pass --install to also copy it into /Applications.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LGTM"
EXECUTABLE="LGTM"
BUNDLE_ID="com.amosweckstrom.lgtm"
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

# The editor window's web panes (vendored, offline @pierre/trees + @pierre/diffs
# bundles + HTML/CSS) ship as a plain folder in Contents/Resources. The app
# loads them via Bundle.main.resourceURL; SwiftPM's Bundle.module is only used
# for `swift run` during development. Keep this in sync with EditorAssets.swift.
echo "==> Copying WebAssets"
cp -R "Sources/LGTM/WebAssets" "${CONTENTS}/Resources/WebAssets"

# Stamp the release version into the bundle when VERSION is provided
# (e.g. from CI: VERSION=1.2.3). VERSION_BUILD defaults to 1.
if [[ -n "${VERSION:-}" ]]; then
    echo "==> Stamping version ${VERSION} (build ${VERSION_BUILD:-1})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION_BUILD:-1}" "${CONTENTS}/Info.plist"
fi

echo "==> Ad-hoc code signing"
codesign --force --options runtime \
    --entitlements "bundle/LGTM.entitlements" \
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

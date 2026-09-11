#!/bin/bash
# Builds PiperStitch.app as a normal double-clickable macOS app bundle
# from the Swift Package Manager build products — no Xcode.app/.xcodeproj
# required (see ARCHITECTURE.md "Distribution"). End users only ever see
# the resulting .app; they never see this script, Terminal, or Swift Package
# Manager. The underlying SPM product/binary is still named "StitchPilot"
# (an internal implementation detail, not user-facing — renaming it would
# touch every source file's imports for zero visible benefit); the bundle
# wrapper, display name, bundle identifier, and icon are what the user
# actually sees, and those all say PiperStitch.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
PRODUCT_NAME="StitchPilot"
APP_NAME="PiperStitch.app"
BUILD_DIR=".build/apple/Products/${CONFIG}"

echo "==> Building PiperStitch (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH=".build/release/${PRODUCT_NAME}"
if [ ! -f "$BIN_PATH" ]; then
  echo "error: expected binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_DIR="dist/${APP_NAME}"
rm -rf "dist"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/PiperStitch.icns" "${APP_DIR}/Contents/Resources/PiperStitch.icns"

echo "==> Built ${APP_DIR}"
echo "Run with: open \"${APP_DIR}\""

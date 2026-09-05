#!/bin/bash
# Builds StitchPilot.app as a normal double-clickable macOS app bundle from
# the Swift Package Manager build products — no Xcode.app/.xcodeproj
# required (see ARCHITECTURE.md "Distribution"). End users only ever see
# the resulting .app; they never see this script, Terminal, or Swift Package
# Manager.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
PRODUCT_NAME="StitchPilot"
APP_NAME="StitchPilot.app"
BUILD_DIR=".build/apple/Products/${CONFIG}"

echo "==> Building ${PRODUCT_NAME} (${CONFIG})"
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
cp "Resources/StitchPilot.icns" "${APP_DIR}/Contents/Resources/StitchPilot.icns"

echo "==> Built ${APP_DIR}"
echo "Run with: open \"${APP_DIR}\""

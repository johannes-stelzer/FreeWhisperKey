#!/usr/bin/env bash
set -euo pipefail

# Simple packager: builds the FreeWhisperKey binary with SwiftPM
# and wraps it into a minimal macOS .app bundle, then zips it.
#
# Usage:
#   scripts/package_app.sh [version]
# Example:
#   scripts/package_app.sh 0.1.0
#
# The resulting artifacts are written to:
#   dist/FreeWhisperKey.app
#   dist/FreeWhisperKey-<version>.zip

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

APP_NAME="FreeWhisperKey"
PRODUCT_NAME="FreeWhisperKey"
VERSION="${1:-0.1.0}"

BUILD_DIR="${ROOT_DIR}/.build/release"
BIN_PATH="${BUILD_DIR}/${PRODUCT_NAME}"

DIST_DIR="${ROOT_DIR}/dist"
BUNDLE_SOURCE="${DIST_DIR}/whisper-bundle"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"

ICON_SOURCE="${ROOT_DIR}/assets/icon_1024.png"
ICONSET_DIR="${DIST_DIR}/AppIcon.iconset"
ICNS_PATH="${DIST_DIR}/AppIcon.icns"
ICON_NAME="AppIcon"

echo "==> Building ${PRODUCT_NAME} (Release) with SwiftPM"
swift build -c release --product "${PRODUCT_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "error: built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"

echo "==> Preparing fresh whisper bundle template"
rm -rf "${BUNDLE_SOURCE}"
"${ROOT_DIR}/scripts/package_whisper_bundle.sh"

if [[ ! -d "${BUNDLE_SOURCE}" ]]; then
  echo "error: whisper bundle missing at ${BUNDLE_SOURCE}" >&2
  exit 1
fi

echo "==> Preparing app bundle at ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_CONTENTS}/MacOS"
mkdir -p "${APP_CONTENTS}/Resources"

echo "==> Generating app icon"
if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "error: icon source missing at ${ICON_SOURCE}" >&2
  exit 1
fi
if ! command -v sips >/dev/null 2>&1; then
  echo "error: 'sips' tool not found (needed to resize icons)" >&2
  exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: 'iconutil' tool not found (needed to build .icns)" >&2
  exit 1
fi
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"
declare -a ICON_SPECS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)
for spec in "${ICON_SPECS[@]}"; do
  size="${spec%%:*}"
  name="${spec##*:}"
  sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET_DIR}/${name}" >/dev/null
done
iconutil --convert icns "${ICONSET_DIR}" --output "${ICNS_PATH}"
cp "${ICNS_PATH}" "${APP_CONTENTS}/Resources/${ICON_NAME}.icns"
rm -rf "${ICONSET_DIR}"

echo "==> Copying executable into bundle"
cp "${BIN_PATH}" "${APP_CONTENTS}/MacOS/${APP_NAME}"

INFO_PLIST="${APP_CONTENTS}/Info.plist"
echo "==> Writing Info.plist"
cat > "${INFO_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.freewhisperkey.${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_NAME}</string>
  <key>CFBundleIconName</key>
  <string>${ICON_NAME}</string>
  <!-- Menu-bar only (no Dock icon) -->
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>FreeWhisperKey captures audio from your microphone to transcribe speech when you hold the Fn key.</string>
</dict>
</plist>
EOF

echo "==> App bundle created at ${APP_BUNDLE}"

echo "==> Copying whisper bundle into Resources"
cp -R "${BUNDLE_SOURCE}" "${APP_CONTENTS}/Resources/whisper-bundle"

ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_STAGING="${DIST_DIR}/dmg_root"

echo "==> Creating zip at ${ZIP_PATH}"
rm -f "${ZIP_PATH}"
(
  cd "${DIST_DIR}"
  zip -r -q "$(basename "${ZIP_PATH}")" "$(basename "${APP_BUNDLE}")"
)

echo "==> Creating DMG at ${DMG_PATH}"
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "error: 'hdiutil' tool not found (needed to build DMG)" >&2
  exit 1
fi
rm -f "${DMG_PATH}"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -format UDZO \
  -quiet \
  "${DMG_PATH}"
rm -rf "${DMG_STAGING}"

echo "==> Done."
echo "App bundle : ${APP_BUNDLE}"
echo "Zip archive: ${ZIP_PATH}"
echo "DMG image : ${DMG_PATH}"

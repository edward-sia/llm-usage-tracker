#!/usr/bin/env bash
# Builds the release binary and wraps it in a minimal .app bundle at build/LLMUsageBar.app.
# The bundle is what makes "Launch at login" work and keeps the app out of the Dock (LSUIElement).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LLMUsageBar"
DISPLAY_NAME="LLM Usage Bar"
BUNDLE_ID="${BUNDLE_ID:-dev.llm-usage-tracker.LLMUsageBar}"
# The bundle version follows the nearest release tag, so it cannot drift the way a
# hardcoded default did: it sat at 0.1.0 through both the v0.1.1 and v0.2.0 releases.
# FALLBACK_VERSION only covers a checkout with no tags to read - a source tarball, or
# a clone that never fetched them. Set VERSION in the environment to override both.
FALLBACK_VERSION="0.2.0"
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  VERSION="${VERSION:-$FALLBACK_VERSION}"
fi
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/${APP_NAME}.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for a locally built app and for SMAppService login items.
codesign --force --sign - "$APP"

echo "Built $APP"

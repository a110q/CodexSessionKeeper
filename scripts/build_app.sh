#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex_会话管理"
APP_VERSION="${APP_VERSION:-1.0.14}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-$(printf '%s' "$APP_VERSION" | tr -d '.')}"
APP_BUNDLE_ID="local.codex.session-manager"
MAC_CODESIGN_IDENTITY="${MAC_CODESIGN_IDENTITY:--}"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
  echo "Invalid APP_VERSION: $APP_VERSION" >&2
  exit 1
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid APP_BUILD_NUMBER: $APP_BUILD_NUMBER" >&2
  exit 1
fi

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/CodexSessionVault" "$APP_DIR/Contents/MacOS/CodexSessionVault"
if [[ -f "$ROOT_DIR/Assets/CodexSessionVault.icns" ]]; then
  cp "$ROOT_DIR/Assets/CodexSessionVault.icns" "$APP_DIR/Contents/Resources/CodexSessionVault.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>codex_会话管理</string>
  <key>CFBundleDisplayName</key>
  <string>codex_会话管理</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleExecutable</key>
  <string>CodexSessionVault</string>
  <key>CFBundleIconFile</key>
  <string>CodexSessionVault</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$APP_DIR/Contents/MacOS/CodexSessionVault"
codesign --force --deep --sign "$MAC_CODESIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"

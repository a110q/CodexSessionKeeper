#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex_会话管理"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/CodexSessionVault" "$APP_DIR/Contents/MacOS/CodexSessionVault"
if [[ -f "$ROOT_DIR/Assets/CodexSessionVault.icns" ]]; then
  cp "$ROOT_DIR/Assets/CodexSessionVault.icns" "$APP_DIR/Contents/Resources/CodexSessionVault.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>codex_会话管理</string>
  <key>CFBundleDisplayName</key>
  <string>codex_会话管理</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.session-manager</string>
  <key>CFBundleVersion</key>
  <string>1.0.10</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.10</string>
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
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"

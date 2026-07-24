#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex_会话管理"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"

if [[ ! -d "$APP_PATH" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BINARY="$APP_PATH/Contents/MacOS/CodexSessionVault"
DMG_PATH="$ROOT_DIR/dist/codex_session_keeper_macos_v${APP_VERSION}_internal-test-unsigned.dmg"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/.codex-session-keeper-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

codesign --verify --deep --strict "$APP_PATH"
if ! otool -L "$BINARY" | grep -q 'ServiceManagement.framework'; then
  echo "Built app is not linked with ServiceManagement." >&2
  exit 1
fi

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create \
  -volname "${APP_NAME}（内部测试）" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo "$DMG_PATH"
echo "$DMG_PATH.sha256"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="$ROOT_DIR/windows/codex_session_manager_electron"
DIST_ROOT="$ROOT_DIR/dist/win10-exe"
APP_DIR="$DIST_ROOT/codex_session_manager-win32-x64"
DOWNLOADS_DIR="$HOME/Downloads"
DOWNLOADS_APP_DIR="$DOWNLOADS_DIR/codex_session_manager_win10_portable"
ZIP_PATH="$DOWNLOADS_DIR/codex_session_manager_win10_portable.zip"

cd "$APP_SOURCE"
if [[ ! -d node_modules ]]; then
  ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}" npm ci
fi
ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}" npm run package:win

cp "$APP_SOURCE/README_WIN10_EXE.md" "$APP_DIR/README_WIN10_EXE.md"

rm -rf "$DOWNLOADS_APP_DIR"
cp -R "$APP_DIR" "$DOWNLOADS_APP_DIR"

rm -f "$ZIP_PATH"
(
  cd "$DOWNLOADS_DIR"
  zip -qr "$ZIP_PATH" "$(basename "$DOWNLOADS_APP_DIR")"
)

echo "$DOWNLOADS_APP_DIR"
echo "$ZIP_PATH"

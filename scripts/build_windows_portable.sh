#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex_session_manager_win10"
SOURCE_DIR="$ROOT_DIR/windows/$APP_NAME"
DIST_DIR="$ROOT_DIR/dist"
OUT_DIR="$DIST_DIR/$APP_NAME"
DOWNLOADS_DIR="$HOME/Downloads"
ZIP_PATH="$DOWNLOADS_DIR/${APP_NAME}_portable.zip"

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Missing Windows source directory: $SOURCE_DIR" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$DIST_DIR"
cp -R "$SOURCE_DIR" "$OUT_DIR"

rm -f "$ZIP_PATH"
(
  cd "$DIST_DIR"
  zip -qr "$ZIP_PATH" "$APP_NAME"
)

rm -rf "$DOWNLOADS_DIR/$APP_NAME"
cp -R "$OUT_DIR" "$DOWNLOADS_DIR/$APP_NAME"

echo "$DOWNLOADS_DIR/$APP_NAME"
echo "$ZIP_PATH"

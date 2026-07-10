#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE_VERSION="3530300"
SQLITE_ARCHIVE="sqlite-tools-win-x64-${SQLITE_VERSION}.zip"
SQLITE_URL="https://www.sqlite.org/2026/${SQLITE_ARCHIVE}"
SQLITE_SHA3_256="b943f8ec7ab77433df44520a27ea65744a792e68a25c05b48823168496b3ccdb"
CACHE_DIR="$ROOT_DIR/dist/vendor-cache"
ARCHIVE_PATH="$CACHE_DIR/$SQLITE_ARCHIVE"
VENDOR_DIR="$ROOT_DIR/windows/codex_session_manager_electron/vendor"
SQLITE_EXE="$VENDOR_DIR/sqlite3.exe"

mkdir -p "$CACHE_DIR" "$VENDOR_DIR"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  rm -f "$ARCHIVE_PATH.tmp"
  curl --fail --location --retry 3 --output "$ARCHIVE_PATH.tmp" "$SQLITE_URL"
  mv "$ARCHIVE_PATH.tmp" "$ARCHIVE_PATH"
fi

actual_hash="$({ python3 - "$ARCHIVE_PATH" <<'PY'
import hashlib
import sys

digest = hashlib.sha3_256()
with open(sys.argv[1], "rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
} | tr -d '[:space:]')"

if [[ "$actual_hash" != "$SQLITE_SHA3_256" ]]; then
  echo "SQLite archive SHA3-256 mismatch: $actual_hash" >&2
  exit 1
fi

sqlite_entry="$(unzip -Z1 "$ARCHIVE_PATH" | awk '/(^|\/)sqlite3\.exe$/ { print; exit }')"
if [[ -z "$sqlite_entry" ]]; then
  echo "sqlite3.exe was not found in $ARCHIVE_PATH" >&2
  exit 1
fi

unzip -p "$ARCHIVE_PATH" "$sqlite_entry" > "$SQLITE_EXE.tmp"
mv "$SQLITE_EXE.tmp" "$SQLITE_EXE"
echo "$SQLITE_EXE"

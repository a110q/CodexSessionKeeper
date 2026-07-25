#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${1:-}"
if [[ -z "$APP_DIR" ]]; then
  echo "usage: $0 /path/to/App.app" >&2
  exit 2
fi

EXECUTABLE="$APP_DIR/Contents/MacOS/CodexSessionVault"
SPARKLE_BINARY="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
EXPECTED_RPATH="@executable_path/../Frameworks"

[[ -f "$EXECUTABLE" ]] || {
  echo "missing application executable: $EXECUTABLE" >&2
  exit 2
}
[[ -f "$SPARKLE_BINARY" ]] || {
  echo "missing embedded Sparkle binary: $SPARKLE_BINARY" >&2
  exit 2
}

if ! /usr/bin/otool -l "$EXECUTABLE" | /usr/bin/awk -v expected="$EXPECTED_RPATH" '
  $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
  in_rpath && $1 == "path" {
    if ($2 == expected) {
      found = 1
    }
    in_rpath = 0
  }
  END { exit(found ? 0 : 1) }
'; then
  echo "application executable is missing LC_RPATH $EXPECTED_RPATH" >&2
  exit 2
fi

echo "macOS runtime layout verified"

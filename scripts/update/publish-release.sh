#!/usr/bin/env bash
set -euo pipefail

PUBLISH_PAGE=1
if [[ "${1:-}" == "--candidate" ]]; then
  PUBLISH_PAGE=0
  shift
fi

[[ $# -eq 2 && "$1" = /* && "$2" = /* ]] || {
  echo "usage: $0 [--candidate] /absolute/verified/release/root /absolute/site/codex-session-keeper/{stable|testing}" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGING_INPUT="$1"
DESTINATION_INPUT="$2"
[[ -d "$STAGING_INPUT" && -d "$DESTINATION_INPUT" ]] || {
  echo "staging and destination must already exist as directories" >&2
  exit 2
}

STAGING_ROOT="$(realpath "$STAGING_INPUT")"
DESTINATION_ROOT="$(realpath "$DESTINATION_INPUT")"
for unsafe in / "$HOME" "$REPOSITORY_ROOT"; do
  [[ "$STAGING_ROOT" != "$unsafe" && "$DESTINATION_ROOT" != "$unsafe" ]] || {
    echo "refusing unsafe publication root: $unsafe" >&2
    exit 2
  }
done
[[ "$STAGING_ROOT" != "$DESTINATION_ROOT" ]] || {
  echo "staging and destination must differ" >&2
  exit 2
}

check_no_symlink_chain() {
  local target="$1"
  local current="/"
  local component
  local -a components
  IFS='/' read -r -a components <<< "${target#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current%/}/$component"
    [[ ! -L "$current" ]] || {
      echo "destination chain contains a symlink: $current" >&2
      exit 2
    }
  done
}
check_no_symlink_chain "$DESTINATION_INPUT"

MARKER_DIRECTORY=""
marker_candidate="$DESTINATION_ROOT"
for _ in 1 2 3 4; do
  if [[ -f "$marker_candidate/.codex-update-root" ]]; then
    MARKER_DIRECTORY="$marker_candidate"
    break
  fi
  [[ "$marker_candidate" != "/" ]] || break
  marker_candidate="$(dirname "$marker_candidate")"
done
[[ -n "$MARKER_DIRECTORY" ]] || {
  echo "destination is not below a marked Codex update root" >&2
  exit 2
}
[[ "$(<"$MARKER_DIRECTORY/.codex-update-root")" == "codex-session-keeper-update-root-v1" ]] || {
  echo "invalid .codex-update-root marker" >&2
  exit 2
}

device_id() {
  if stat -f '%d' "$1" >/dev/null 2>&1; then
    stat -f '%d' "$1"
  else
    stat -c '%d' "$1"
  fi
}
[[ "$(device_id "$STAGING_ROOT")" == "$(device_id "$DESTINATION_ROOT")" ]] || {
  echo "staging and destination must be on the same filesystem for atomic publication" >&2
  exit 2
}

"$SCRIPT_DIR/verify-release-directory.mjs" --root "$STAGING_ROOT"
VERSION="$(node -e 'const fs=require("fs");const p=process.argv[1];process.stdout.write(JSON.parse(fs.readFileSync(p,"utf8")).version)' "$STAGING_ROOT/release.json")"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "verified manifest returned an invalid version" >&2
  exit 2
}

INCOMING_ROOT="$(dirname "$DESTINATION_ROOT")/.incoming-$VERSION-$$"
[[ ! -e "$INCOMING_ROOT" ]] || {
  echo "incoming publication directory already exists: $INCOMING_ROOT" >&2
  exit 2
}

cleanup_incoming() {
  if [[ -n "${INCOMING_ROOT:-}" && -d "$INCOMING_ROOT" && "$(basename "$INCOMING_ROOT")" == ".incoming-$VERSION-$$" ]]; then
    rm -rf -- "$INCOMING_ROOT"
  fi
}
trap cleanup_incoming EXIT

mkdir -p "$INCOMING_ROOT/macos" "$INCOMING_ROOT/windows" "$DESTINATION_ROOT/macos" "$DESTINATION_ROOT/windows"
cp "$STAGING_ROOT/macos/CodexSessionKeeper-$VERSION-macos-arm64.zip" "$INCOMING_ROOT/macos/"
cp "$STAGING_ROOT/windows/CodexSessionKeeper-$VERSION-windows-x64-Setup.exe" "$INCOMING_ROOT/windows/"
cp "$STAGING_ROOT/macos/appcast.xml" "$INCOMING_ROOT/macos/appcast.xml"
cp "$STAGING_ROOT/windows/latest.yml" "$INCOMING_ROOT/windows/latest.yml"
cp "$STAGING_ROOT/release.json.sig" "$INCOMING_ROOT/release.json.sig"
cp "$STAGING_ROOT/release.json" "$INCOMING_ROOT/release.json"

fsync_file() {
  node -e 'const fs=require("fs");const fd=fs.openSync(process.argv[1],"r");try{fs.fsyncSync(fd)}finally{fs.closeSync(fd)}' "$1"
}
for staged_file in \
  "$INCOMING_ROOT/macos/CodexSessionKeeper-$VERSION-macos-arm64.zip" \
  "$INCOMING_ROOT/windows/CodexSessionKeeper-$VERSION-windows-x64-Setup.exe" \
  "$INCOMING_ROOT/macos/appcast.xml" \
  "$INCOMING_ROOT/windows/latest.yml" \
  "$INCOMING_ROOT/release.json.sig" \
  "$INCOMING_ROOT/release.json"; do
  fsync_file "$staged_file"
done

file_sha256() {
  node -e 'const fs=require("fs"),c=require("crypto");const h=c.createHash("sha256");h.update(fs.readFileSync(process.argv[1]));process.stdout.write(h.digest("hex"))' "$1"
}
publish_versioned_artifact() {
  local source="$1"
  local destination="$2"
  if [[ -e "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || {
      echo "existing artifact is not a regular file: $destination" >&2
      exit 2
    }
    [[ "$(file_sha256 "$source")" == "$(file_sha256 "$destination")" ]] || {
      echo "refusing to overwrite a different versioned artifact: $destination" >&2
      exit 2
    }
    return
  fi
  mv "$source" "$destination"
}

publish_versioned_artifact \
  "$INCOMING_ROOT/macos/CodexSessionKeeper-$VERSION-macos-arm64.zip" \
  "$DESTINATION_ROOT/macos/CodexSessionKeeper-$VERSION-macos-arm64.zip"
publish_versioned_artifact \
  "$INCOMING_ROOT/windows/CodexSessionKeeper-$VERSION-windows-x64-Setup.exe" \
  "$DESTINATION_ROOT/windows/CodexSessionKeeper-$VERSION-windows-x64-Setup.exe"

publish_metadata() {
  local source="$1"
  local destination="$2"
  local temporary="$(dirname "$destination")/.$(basename "$destination").incoming-$$"
  [[ ! -L "$destination" ]] || {
    echo "refusing to replace symlinked metadata: $destination" >&2
    exit 2
  }
  [[ ! -e "$temporary" ]] || {
    echo "metadata temporary path already exists: $temporary" >&2
    exit 2
  }
  mv "$source" "$temporary"
  fsync_file "$temporary"
  mv -f "$temporary" "$destination"
}

publish_metadata "$INCOMING_ROOT/macos/appcast.xml" "$DESTINATION_ROOT/macos/appcast.xml"
publish_metadata "$INCOMING_ROOT/windows/latest.yml" "$DESTINATION_ROOT/windows/latest.yml"
publish_metadata "$INCOMING_ROOT/release.json.sig" "$DESTINATION_ROOT/release.json.sig"
publish_metadata "$INCOMING_ROOT/release.json" "$DESTINATION_ROOT/release.json"
if [[ "$PUBLISH_PAGE" == 1 ]]; then
  SITE_ROOT="$(dirname "$DESTINATION_ROOT")"
  DOWNLOAD_PAGE="$INCOMING_ROOT/index.html"
  node "$SCRIPT_DIR/build-download-page.mjs" \
    --stable-root "$DESTINATION_ROOT" \
    --output "$DOWNLOAD_PAGE"
  fsync_file "$DOWNLOAD_PAGE"
  publish_metadata "$DOWNLOAD_PAGE" "$SITE_ROOT/index.html"
fi
sync

echo "published $VERSION"
echo "versioned artifacts eligible for manual retention review:"
find "$DESTINATION_ROOT/macos" "$DESTINATION_ROOT/windows" -maxdepth 1 -type f \
  \( -name 'CodexSessionKeeper-*-macos-arm64.zip' -o -name 'CodexSessionKeeper-*-windows-x64-Setup.exe' \) \
  -print | sort

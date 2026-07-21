#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "usage: $0 /absolute/output.tar.enc" >&2
  exit 2
fi

OUTPUT_PATH="$1"
OUTPUT_PARENT="$(dirname "$OUTPUT_PATH")"
if [[ ! -d "$OUTPUT_PARENT" || -L "$OUTPUT_PARENT" ]]; then
  echo "output parent must be an existing non-symlink directory: $OUTPUT_PARENT" >&2
  exit 2
fi
if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
  echo "output already exists: $OUTPUT_PATH" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SPARKLE_KEY_TOOL="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$SPARKLE_KEY_TOOL" ]]; then
  echo "Sparkle generate_keys was not found; run swift package resolve first." >&2
  exit 2
fi

KEY_BACKUP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-update-keys.XXXXXX")"
ENCRYPTED_TMP="$OUTPUT_PATH.tmp-$$"
cleanup() {
  if [[ -d "$KEY_BACKUP_TMP" && "$KEY_BACKUP_TMP" == *"/codex-update-keys."* ]]; then
    rm -rf "$KEY_BACKUP_TMP"
  fi
  if [[ -f "$ENCRYPTED_TMP" ]]; then
    rm -f "$ENCRYPTED_TMP"
  fi
}
trap cleanup EXIT

/usr/bin/security find-generic-password \
  -a release \
  -s "CodexSessionKeeper Update Manifest Ed25519" \
  -w > "$KEY_BACKUP_TMP/manifest-private.pem"
"$SPARKLE_KEY_TOOL" \
  --account local.codex.session-manager \
  -x "$KEY_BACKUP_TMP/sparkle-private.key"

tar -C "$KEY_BACKUP_TMP" -cf - manifest-private.pem sparkle-private.key \
  | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$ENCRYPTED_TMP"
chmod 600 "$ENCRYPTED_TMP"
mv "$ENCRYPTED_TMP" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"


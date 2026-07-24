#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex_会话管理"
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD="${APP_BUILD:-10100}"
UPDATE_SCOPE="${UPDATE_SCOPE:-stable}"
case "$UPDATE_SCOPE" in
  stable)
    UPDATE_SERVER_CONFIG="$ROOT_DIR/Config/UpdateServer.json"
    EXPECTED_UPDATE_BASE_URL="http://192.168.10.54:18080/codex-session-keeper/stable/"
    ;;
  testing)
    UPDATE_SERVER_CONFIG="$ROOT_DIR/Config/UpdateServer.testing.json"
    EXPECTED_UPDATE_BASE_URL="http://192.168.10.54:18080/codex-session-keeper/testing/"
    ;;
  *)
    echo "UPDATE_SCOPE must be stable or testing" >&2
    exit 2
    ;;
esac
UPDATE_KEYS="$ROOT_DIR/Config/UpdateKeys.json"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
MACOS_DIST_DIR="$DIST_DIR/macos"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ARCHIVE_PATH="$MACOS_DIST_DIR/CodexSessionKeeper-$APP_VERSION-macos-arm64.zip"
SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

[[ -f "$UPDATE_SERVER_CONFIG" ]] || { echo "missing update server config: $UPDATE_SERVER_CONFIG" >&2; exit 2; }
[[ -f "$UPDATE_KEYS" ]] || { echo "missing update keys: $UPDATE_KEYS" >&2; exit 2; }

SERVER_PLIST="$(mktemp "${TMPDIR:-/tmp}/codex-update-server.XXXXXX.plist")"
KEYS_PLIST="$(mktemp "${TMPDIR:-/tmp}/codex-update-keys.XXXXXX.plist")"
trap 'rm -f "$SERVER_PLIST" "$KEYS_PLIST"' EXIT
/usr/bin/plutil -convert xml1 -o "$SERVER_PLIST" "$UPDATE_SERVER_CONFIG"
/usr/bin/plutil -convert xml1 -o "$KEYS_PLIST" "$UPDATE_KEYS"
UPDATE_BASE_URL="$(/usr/libexec/PlistBuddy -c 'Print :releaseBaseURL' "$SERVER_PLIST")"
[[ "$UPDATE_BASE_URL" == "$EXPECTED_UPDATE_BASE_URL" ]] || {
  echo "unexpected fixed update server for $UPDATE_SCOPE: $UPDATE_BASE_URL" >&2
  exit 2
}
MANIFEST_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :manifestPublicKey' "$KEYS_PLIST")"
SPARKLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :sparklePublicEDKey' "$KEYS_PLIST")"
[[ -n "$MANIFEST_PUBLIC_KEY" && -n "$SPARKLE_PUBLIC_KEY" ]] || {
  echo "update public keys are incomplete" >&2
  exit 2
}

cd "$ROOT_DIR"
swift build -c release

[[ -d "$SPARKLE_FRAMEWORK_SOURCE" ]] || {
  echo "missing resolved Sparkle framework: $SPARKLE_FRAMEWORK_SOURCE" >&2
  exit 2
}

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks" "$MACOS_DIST_DIR"
cp "$BUILD_DIR/CodexSessionVault" "$APP_DIR/Contents/MacOS/CodexSessionVault"
/usr/bin/ditto "$SPARKLE_FRAMEWORK_SOURCE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
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
  <string>local.codex.session-manager</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
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
  <key>CSKUpdateBaseURL</key>
  <string>$UPDATE_BASE_URL</string>
  <key>CSKManifestPublicKey</key>
  <string>$MANIFEST_PUBLIC_KEY</string>
  <key>SUFeedURL</key>
  <string>${UPDATE_BASE_URL}macos/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAllowsAutomaticUpdates</key>
  <false/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

chmod +x "$APP_DIR/Contents/MacOS/CodexSessionVault"
if ! /usr/bin/otool -l "$APP_DIR/Contents/MacOS/CodexSessionVault" | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_DIR/Contents/MacOS/CodexSessionVault"
fi

SPARKLE_VERSION_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested_bundle in \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/Updater.app"; do
  /usr/bin/codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$nested_bundle"
done
/usr/bin/codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$SPARKLE_VERSION_DIR/Autoupdate"
/usr/bin/codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP_DIR/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign --force --sign - "$APP_DIR"

rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
echo "$ARCHIVE_PATH"

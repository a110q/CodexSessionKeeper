#!/usr/bin/env bash
set -euo pipefail

EXPECTED_IP="192.168.10.54"
LABEL="com.company.codex-update-server"
SITE_ROOT="/Users/Shared/codex-update-site"
CONFIG_DEST="/usr/local/etc/codex-update-nginx.conf"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

/sbin/ifconfig | /usr/bin/awk '/inet / { print $2 }' | /usr/bin/grep -Fxq "$EXPECTED_IP" || {
  echo "refusing deployment: this Mac does not own $EXPECTED_IP" >&2
  exit 2
}

BREW_BIN=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [[ -x "$candidate" ]]; then
    BREW_BIN="$candidate"
    break
  fi
done
[[ -n "$BREW_BIN" ]] || {
  echo "Homebrew is required; install it from the company-approved source first" >&2
  exit 2
}

if ! "$BREW_BIN" list --versions nginx >/dev/null 2>&1; then
  "$BREW_BIN" install nginx
fi
NGINX_BIN="$("$BREW_BIN" --prefix nginx)/bin/nginx"
[[ -x "$NGINX_BIN" ]] || { echo "nginx binary is missing" >&2; exit 2; }

if /usr/sbin/lsof -nP -iTCP@"$EXPECTED_IP":18080 -sTCP:LISTEN | /usr/bin/grep -q .; then
  if ! sudo /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "port 18080 is already owned by another process" >&2
    exit 2
  fi
fi

sudo /usr/bin/install -d -o root -g admin -m 0775 \
  "$SITE_ROOT" \
  "$SITE_ROOT/codex-session-keeper" \
  "$SITE_ROOT/codex-session-keeper/stable" \
  "$SITE_ROOT/codex-session-keeper/stable/macos" \
  "$SITE_ROOT/codex-session-keeper/stable/windows"

MARKER_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-root.XXXXXX")"
PLIST_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-launchd.XXXXXX.plist")"
cleanup() { /bin/rm -f "$MARKER_TEMP" "$PLIST_TEMP"; }
trap cleanup EXIT
/usr/bin/printf '%s\n' 'codex-session-keeper-update-root-v1' > "$MARKER_TEMP"
sudo /usr/bin/install -o root -g admin -m 0664 "$MARKER_TEMP" "$SITE_ROOT/.codex-update-root"
sudo /usr/bin/install -d -o root -g wheel -m 0755 /usr/local/etc
sudo /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/nginx.conf" "$CONFIG_DEST"

/usr/bin/plutil -create xml1 "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :UserName string root" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $NGINX_BIN" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string -c" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $CONFIG_DEST" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string -g" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string daemon off;" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string /var/log/codex-update-launchd.log" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string /var/log/codex-update-launchd-error.log" "$PLIST_TEMP"

sudo "$NGINX_BIN" -t -c "$CONFIG_DEST"
if sudo /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  sudo /bin/launchctl bootout "system/$LABEL"
fi
sudo /usr/bin/install -o root -g wheel -m 0644 "$PLIST_TEMP" "$PLIST_DEST"
sudo /bin/launchctl bootstrap system "$PLIST_DEST"
sudo /bin/launchctl enable "system/$LABEL"
sudo /bin/launchctl kickstart -k "system/$LABEL"
/usr/bin/curl --fail --silent --show-error --head \
  "http://192.168.10.54:18080/codex-session-keeper/" >/dev/null || true
echo "installed $LABEL on http://192.168.10.54:18080/"

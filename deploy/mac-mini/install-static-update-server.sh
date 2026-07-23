#!/usr/bin/env bash
set -euo pipefail

EXPECTED_IP="192.168.10.54"
LABEL="com.company.codex-update-server"
SITE_ROOT="/Users/Shared/codex-update-site"
CONFIG_DEST="/usr/local/etc/codex-update-nginx.conf"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_PATH="/codex-session-keeper/health.txt"
BREW_BIN="/opt/homebrew/bin/brew"
ARCH="$(/usr/bin/uname -m)"

BACKUP_CONFIG="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-config.XXXXXX")"
BACKUP_PLIST="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-plist.XXXXXX")"
MARKER_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-root.XXXXXX")"
HEALTH_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-health.XXXXXX")"
PLIST_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-launchd.XXXXXX.plist")"
HAD_CONFIG=0
HAD_PLIST=0
HAD_JOB=0
DEPLOYING=0
ROLLING_BACK=0

cleanup() {
  /bin/rm -f "$BACKUP_CONFIG" "$BACKUP_PLIST" "$MARKER_TEMP" "$HEALTH_TEMP" "$PLIST_TEMP"
}

rollback() {
  [[ "$DEPLOYING" -eq 1 && "$ROLLING_BACK" -eq 0 ]] || return 0
  ROLLING_BACK=1
  set +e

  sudo /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1
  if [[ "$HAD_CONFIG" -eq 1 ]]; then
    sudo /usr/bin/install -o root -g wheel -m 0644 "$BACKUP_CONFIG" "$CONFIG_DEST"
  else
    sudo /bin/rm -f "$CONFIG_DEST"
  fi
  if [[ "$HAD_PLIST" -eq 1 ]]; then
    sudo /usr/bin/install -o root -g wheel -m 0644 "$BACKUP_PLIST" "$PLIST_DEST"
  else
    sudo /bin/rm -f "$PLIST_DEST"
  fi
  if [[ "$HAD_JOB" -eq 1 ]]; then
    sudo /bin/launchctl bootstrap system "$PLIST_DEST"
    sudo /bin/launchctl enable "system/$LABEL"
    sudo /bin/launchctl kickstart -k "system/$LABEL"
  fi
}

on_error() {
  local status="$1"
  trap - ERR
  rollback
  exit "$status"
}

trap cleanup EXIT
trap 'on_error $?' ERR

die() {
  echo "$*" >&2
  exit 2
}

listener_pids() {
  local pids status
  if pids="$(sudo /usr/sbin/lsof -nP -t -iTCP@"$EXPECTED_IP":18080 -sTCP:LISTEN)"; then
    /usr/bin/printf '%s\n' "$pids"
    return 0
  fi
  status=$?
  if [[ "$status" -eq 1 ]]; then
    return 0
  fi
  echo "unable to inspect listeners on $EXPECTED_IP:18080" >&2
  return "$status"
}

assert_listener_owned_by_service() {
  local pids pid command job
  pids="$(listener_pids)" || return 1
  [[ -n "$pids" ]] || return 0

  if ! job="$(sudo /bin/launchctl print "system/$LABEL")"; then
    echo "port 18080 is already owned: existing service does not own 192.168.10.54:18080" >&2
    return 1
  fi
  if ! /usr/bin/grep -Eq '^[[:space:]]*pid = [0-9]+' <<<"$job"; then
    echo "port 18080 is already owned: existing service does not own 192.168.10.54:18080" >&2
    return 1
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! command="$(sudo /bin/ps -p "$pid" -o command=)"; then
      echo "port 18080 is already owned: existing service does not own 192.168.10.54:18080" >&2
      return 1
    fi
    if [[ "$command" != *"$NGINX_BIN"* || "$command" != *"$CONFIG_DEST"* ]]; then
      echo "port 18080 is already owned: existing service does not own 192.168.10.54:18080" >&2
      return 1
    fi
  done <<<"$pids"
}

wait_for_listener_to_stop() {
  local attempt pids
  for attempt in {1..50}; do
    pids="$(listener_pids)" || return 1
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.1
  done
  echo "existing update service did not release $EXPECTED_IP:18080" >&2
  return 1
}

verify_service() {
  local pids pid command health_status post_status
  if ! sudo /bin/launchctl print "system/$LABEL" >/dev/null; then
    echo "launchd job $LABEL is not active" >&2
    return 1
  fi
  pids="$(listener_pids)" || return 1
  if [[ -z "$pids" ]]; then
    echo "nginx is not listening on $EXPECTED_IP:18080" >&2
    return 1
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! command="$(sudo /bin/ps -p "$pid" -o command=)"; then
      echo "could not inspect listener PID $pid" >&2
      return 1
    fi
    if [[ "$command" != *"$NGINX_BIN"* || "$command" != *"$CONFIG_DEST"* ]]; then
      echo "listener PID $pid is not this update service" >&2
      return 1
    fi
  done <<<"$pids"
  if ! health_status="$(/usr/bin/curl --fail --silent --show-error --output /dev/null --write-out '%{http_code}' "http://$EXPECTED_IP:18080$HEALTH_PATH")"; then
    echo "health file is not readable through nginx" >&2
    return 1
  fi
  if [[ "$health_status" != "200" ]]; then
    echo "health file returned HTTP $health_status instead of 200" >&2
    return 1
  fi
  if ! post_status="$(/usr/bin/curl --silent --show-error --output /dev/null --write-out '%{http_code}' -X POST "http://$EXPECTED_IP:18080$HEALTH_PATH")"; then
    echo "POST verification request failed" >&2
    return 1
  fi
  if [[ "$post_status" != "405" ]]; then
    echo "POST returned HTTP $post_status instead of 405" >&2
    return 1
  fi
}

wait_for_service() {
  local attempt
  for attempt in {1..50}; do
    if verify_service; then
      return 0
    fi
    /bin/sleep 0.1
  done
  echo "update service failed verification" >&2
  return 1
}

/sbin/ifconfig | /usr/bin/awk '/inet / { print $2 }' | /usr/bin/grep -Fxq "$EXPECTED_IP" || {
  die "refusing deployment: this Mac does not own $EXPECTED_IP"
}
[[ "$ARCH" == "arm64" ]] || die "refusing deployment: Apple Silicon (arm64) is required"
[[ -x "$BREW_BIN" ]] || die "Homebrew is required at $BREW_BIN; install it from the company-approved source first"

if ! "$BREW_BIN" list --versions nginx >/dev/null 2>&1; then
  "$BREW_BIN" install nginx
fi
NGINX_BIN="$("$BREW_BIN" --prefix nginx)/bin/nginx"
[[ -x "$NGINX_BIN" ]] || die "nginx binary is missing"

assert_listener_owned_by_service

if [[ -f "$CONFIG_DEST" ]]; then
  sudo /bin/cp "$CONFIG_DEST" "$BACKUP_CONFIG"
  HAD_CONFIG=1
fi
if [[ -f "$PLIST_DEST" ]]; then
  sudo /bin/cp "$PLIST_DEST" "$BACKUP_PLIST"
  HAD_PLIST=1
fi
if sudo /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  HAD_JOB=1
fi
DEPLOYING=1

sudo /usr/bin/install -d -o root -g admin -m 0775 \
  "$SITE_ROOT" \
  "$SITE_ROOT/codex-session-keeper" \
  "$SITE_ROOT/codex-session-keeper/stable" \
  "$SITE_ROOT/codex-session-keeper/stable/macos" \
  "$SITE_ROOT/codex-session-keeper/stable/windows"

/usr/bin/printf '%s\n' 'codex-session-keeper-update-root-v1' > "$MARKER_TEMP"
sudo /usr/bin/install -o root -g admin -m 0664 "$MARKER_TEMP" "$SITE_ROOT/.codex-update-root"
/usr/bin/printf '%s\n' 'codex-session-keeper update service health check' > "$HEALTH_TEMP"
sudo /usr/bin/install -o root -g admin -m 0664 "$HEALTH_TEMP" "$SITE_ROOT$HEALTH_PATH"
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
  wait_for_listener_to_stop
fi
sudo /usr/bin/install -o root -g wheel -m 0644 "$PLIST_TEMP" "$PLIST_DEST"
sudo /bin/launchctl bootstrap system "$PLIST_DEST"
sudo /bin/launchctl enable "system/$LABEL"
sudo /bin/launchctl kickstart -k "system/$LABEL"
wait_for_service
DEPLOYING=0
echo "installed $LABEL on http://192.168.10.54:18080/"

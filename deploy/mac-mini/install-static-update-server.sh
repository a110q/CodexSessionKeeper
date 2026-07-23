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
REPLACEMENT_JOB_STARTED=0
REPLACEMENT_MASTER_PID=""

cleanup() {
  /bin/rm -f "$BACKUP_CONFIG" "$BACKUP_PLIST" "$MARKER_TEMP" "$HEALTH_TEMP" "$PLIST_TEMP"
}

run_lsof() { sudo /usr/sbin/lsof -nP -F pfn -iTCP:18080 -sTCP:LISTEN; }
run_launchctl_print() { sudo /bin/launchctl print "system/$LABEL" 2>&1; }
run_launchctl_bootout() { sudo /bin/launchctl bootout "system/$LABEL"; }
run_launchctl_bootstrap() { sudo /bin/launchctl bootstrap system "$PLIST_DEST"; }
run_launchctl_enable() { sudo /bin/launchctl enable "system/$LABEL"; }
run_launchctl_kickstart() { sudo /bin/launchctl kickstart -k "system/$LABEL"; }
process_command() { sudo /bin/ps -p "$1" -o command=; }
process_parent_pid() { sudo /bin/ps -p "$1" -o ppid= | /usr/bin/tr -d '[:space:]'; }

inspect_launchd_job() {
  local output status
  LAUNCHD_JOB_PRESENT=0
  LAUNCHD_JOB_OUTPUT=""
  LAUNCHD_INSPECTION_ERROR=""
  if output="$(run_launchctl_print)"; then
    LAUNCHD_JOB_PRESENT=1
    LAUNCHD_JOB_OUTPUT="$output"
    return 0
  else
    status=$?
  fi
  LAUNCHD_JOB_OUTPUT="$output"
  if [[ "$output" == *"Could not find service"* || "$output" == *"Could not find the service"* ]]; then
    return 0
  fi
  LAUNCHD_INSPECTION_ERROR="could not inspect launchd job $LABEL (launchctl status $status): $output"
  echo "$LAUNCHD_INSPECTION_ERROR" >&2
  return "$status"
}

snapshot_existing_job() {
  inspect_launchd_job || return 1
  HAD_JOB="$LAUNCHD_JOB_PRESENT"
}

listener_records() {
  local output status line pid="" endpoint=""
  if output="$(run_lsof)"; then
    :
  else
    status=$?
    [[ "$status" -eq 1 ]] && return 0
    echo "unable to inspect listeners on port 18080" >&2
    return "$status"
  fi
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      n*)
        endpoint="${line#n}"
        [[ "$pid" =~ ^[0-9]+$ && -n "$endpoint" ]] && /usr/bin/printf '%s\t%s\n' "$pid" "$endpoint"
        ;;
    esac
  done <<<"$output"
}

listener_pids() { listener_records | /usr/bin/awk -F '\t' '!seen[$1]++ { print $1 }'; }

launchd_master_pid() {
  local state pid
  LAUNCHD_MASTER_PID=""
  if ! inspect_launchd_job; then
    LISTENER_VALIDATION_ERROR="$LAUNCHD_INSPECTION_ERROR"
    return 1
  fi
  if [[ "$LAUNCHD_JOB_PRESENT" -eq 0 ]]; then
    LISTENER_VALIDATION_ERROR="launchd job is not loaded"
    return 1
  fi
  state="$(/usr/bin/awk -F ' = ' '/^[[:space:]]*state = / { print $2; exit }' <<<"$LAUNCHD_JOB_OUTPUT")"
  pid="$(/usr/bin/awk -F ' = ' '/^[[:space:]]*pid = / { print $2; exit }' <<<"$LAUNCHD_JOB_OUTPUT")"
  [[ "$state" == "running" ]] || { LISTENER_VALIDATION_ERROR="launchd job is not running"; return 1; }
  [[ "$pid" =~ ^[0-9]+$ ]] || { LISTENER_VALIDATION_ERROR="launchd job has no master PID"; return 1; }
  LAUNCHD_MASTER_PID="$pid"
}

is_descended_from_master() {
  local pid="$1" master_pid="$2" parent hops=0
  while [[ "$pid" != "$master_pid" ]]; do
    ((hops += 1))
    [[ "$hops" -le 128 ]] || return 1
    parent="$(process_parent_pid "$pid")" || return 1
    [[ "$parent" =~ ^[0-9]+$ && "$parent" -gt 1 && "$parent" != "$pid" ]] || return 1
    pid="$parent"
  done
}

validate_listener_records() {
  local records master_pid master_command pid endpoint
  LISTENER_VALIDATION_ERROR=""
  records="$(listener_records)" || { LISTENER_VALIDATION_ERROR="unable to inspect listeners"; return 1; }
  [[ -n "$records" ]] || { LISTENER_VALIDATION_ERROR="nginx is not listening on $EXPECTED_IP:18080"; return 1; }
  launchd_master_pid || return 1
  master_pid="$LAUNCHD_MASTER_PID"
  if [[ "$REPLACEMENT_JOB_STARTED" -eq 1 ]]; then
    REPLACEMENT_MASTER_PID="$master_pid"
  fi
  master_command="$(process_command "$master_pid")" || { LISTENER_VALIDATION_ERROR="could not inspect launchd master PID $master_pid"; return 1; }
  [[ "$master_command" == *"$NGINX_BIN"* && "$master_command" == *"$CONFIG_DEST"* ]] || {
    LISTENER_VALIDATION_ERROR="launchd master is not this update nginx"; return 1;
  }
  while IFS=$'\t' read -r pid endpoint; do
    [[ "$endpoint" == "$EXPECTED_IP:18080" ]] || { LISTENER_VALIDATION_ERROR="unexpected listener endpoint $endpoint"; return 1; }
    is_descended_from_master "$pid" "$master_pid" || {
      LISTENER_VALIDATION_ERROR="listener PID $pid is not descended from launchd master $master_pid"; return 1;
    }
  done <<<"$records"
}

assert_listener_owned_by_service() {
  local records
  records="$(listener_records)" || return 1
  [[ -z "$records" ]] && return 0
  if ! validate_listener_records; then
    echo "port 18080 is already owned: existing service does not own $EXPECTED_IP:18080 ($LISTENER_VALIDATION_ERROR)" >&2
    return 1
  fi
}

wait_for_listener_to_stop() {
  local attempt records
  for attempt in {1..50}; do
    records="$(listener_records)" || return 1
    [[ -z "$records" ]] && return 0
    /bin/sleep 0.1
  done
  echo "existing update service did not release port 18080" >&2
  return 1
}

stop_service() {
  local records
  inspect_launchd_job || return 1
  records="$(listener_records)" || return 1
  if [[ -n "$records" ]] && ! validate_listener_records; then
    echo "refusing to stop listener: $LISTENER_VALIDATION_ERROR" >&2
    return 1
  fi
  if [[ "$LAUNCHD_JOB_PRESENT" -eq 0 ]]; then
    [[ -z "$records" ]] && return 0
    echo "launchd job $LABEL is absent while port 18080 is still listening" >&2
    return 1
  fi
  if ! run_launchctl_bootout; then
    echo "could not bootout $LABEL" >&2
    return 1
  fi
  wait_for_listener_to_stop
}

launchd_job_pid() {
  /usr/bin/awk -F ' = ' '/^[[:space:]]*pid = / { print $2; exit }' <<<"$LAUNCHD_JOB_OUTPUT"
}

wait_for_launchd_job_absent() {
  local attempt
  for attempt in {1..50}; do
    inspect_launchd_job || return 1
    [[ "$LAUNCHD_JOB_PRESENT" -eq 0 ]] && return 0
    /bin/sleep 0.1
  done
  echo "replacement launchd job did not unload" >&2
  return 1
}

replacement_listener_pids() {
  local master_pid="$1" records pid endpoint
  [[ "$master_pid" =~ ^[0-9]+$ ]] || return 0
  records="$(listener_records)" || return 1
  while IFS=$'\t' read -r pid endpoint; do
    [[ -n "$pid" ]] || continue
    if [[ "$pid" == "$master_pid" ]] || is_descended_from_master "$pid" "$master_pid"; then
      /usr/bin/printf '%s\n' "$pid"
    fi
  done <<<"$records"
}

wait_for_listener_pids_to_exit() {
  local expected_pids="$1" attempt records current_pids pid still_listening
  [[ -n "$expected_pids" ]] || return 0
  for attempt in {1..50}; do
    records="$(listener_records)" || return 1
    current_pids="$(/usr/bin/awk -F '\t' '{ print $1 }' <<<"$records")"
    still_listening=0
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if /usr/bin/grep -Fxq "$pid" <<<"$current_pids"; then
        still_listening=1
        break
      fi
    done <<<"$expected_pids"
    [[ "$still_listening" -eq 0 ]] && return 0
    /bin/sleep 0.1
  done
  echo "replacement listener processes did not exit" >&2
  return 1
}

stop_replacement_service() {
  local master_pid="$REPLACEMENT_MASTER_PID" replacement_pids=""
  inspect_launchd_job || return 1
  if [[ "$LAUNCHD_JOB_PRESENT" -eq 1 ]]; then
    master_pid="$(launchd_job_pid)"
    replacement_pids="$(replacement_listener_pids "$master_pid")" || return 1
    if ! run_launchctl_bootout; then
      echo "could not bootout replacement $LABEL" >&2
      return 1
    fi
  elif [[ -n "$master_pid" ]]; then
    replacement_pids="$(replacement_listener_pids "$master_pid")" || return 1
  fi
  wait_for_launchd_job_absent || return 1
  wait_for_listener_pids_to_exit "$replacement_pids"
}

restore_config() {
  if [[ "$HAD_CONFIG" -eq 1 ]]; then sudo /usr/bin/install -o root -g wheel -m 0644 "$BACKUP_CONFIG" "$CONFIG_DEST"; else sudo /bin/rm -f "$CONFIG_DEST"; fi
}
restore_plist() {
  if [[ "$HAD_PLIST" -eq 1 ]]; then sudo /usr/bin/install -o root -g wheel -m 0644 "$BACKUP_PLIST" "$PLIST_DEST"; else sudo /bin/rm -f "$PLIST_DEST"; fi
}
restart_prior_service() { run_launchctl_bootstrap && run_launchctl_enable && run_launchctl_kickstart; }

verify_rollback_restoration() {
  local attempt
  if [[ "$HAD_CONFIG" -eq 1 ]]; then sudo /usr/bin/cmp -s "$BACKUP_CONFIG" "$CONFIG_DEST" || return 1; elif [[ -e "$CONFIG_DEST" ]]; then return 1; fi
  if [[ "$HAD_PLIST" -eq 1 ]]; then sudo /usr/bin/cmp -s "$BACKUP_PLIST" "$PLIST_DEST" || return 1; elif [[ -e "$PLIST_DEST" ]]; then return 1; fi
  if [[ "$HAD_JOB" -eq 0 ]]; then wait_for_listener_to_stop; return; fi
  for attempt in {1..50}; do
    validate_listener_records && return 0
    /bin/sleep 0.1
  done
  return 1
}

rollback() {
  local failed=0
  [[ "$DEPLOYING" -eq 1 && "$ROLLING_BACK" -eq 0 ]] || return 0
  ROLLING_BACK=1
  if [[ "$REPLACEMENT_JOB_STARTED" -eq 1 ]]; then
    if ! stop_replacement_service; then
      echo "rollback failed: could not stop replacement service" >&2
      return 1
    fi
  elif ! stop_service; then
    echo "rollback failed: could not stop replacement service" >&2
    return 1
  fi
  if ! restore_config; then echo "rollback failed: could not restore nginx configuration" >&2; failed=1; fi
  if ! restore_plist; then echo "rollback failed: could not restore launchd plist" >&2; failed=1; fi
  if [[ "$HAD_JOB" -eq 1 ]] && ! restart_prior_service; then echo "rollback failed: could not restart prior launchd job" >&2; failed=1; fi
  if ! verify_rollback_restoration; then echo "rollback failed: restoration verification did not pass" >&2; failed=1; fi
  [[ "$failed" -eq 0 ]]
}

on_error() {
  local status="$1"
  trap - ERR
  if ! rollback; then echo "rollback failed while handling deployment error" >&2; fi
  exit "$status"
}

trap cleanup EXIT
trap 'on_error $?' ERR

die() { echo "$*" >&2; exit 2; }

verify_service() {
  local health_status post_status
  if ! validate_listener_records; then echo "$LISTENER_VALIDATION_ERROR" >&2; return 1; fi
  if ! health_status="$(/usr/bin/curl --fail --silent --show-error --output /dev/null --write-out '%{http_code}' "http://$EXPECTED_IP:18080$HEALTH_PATH")"; then
    echo "health file is not readable through nginx" >&2; return 1
  fi
  [[ "$health_status" == "200" ]] || { echo "health file returned HTTP $health_status instead of 200" >&2; return 1; }
  if ! post_status="$(/usr/bin/curl --silent --show-error --output /dev/null --write-out '%{http_code}' -X POST "http://$EXPECTED_IP:18080$HEALTH_PATH")"; then
    echo "POST verification request failed" >&2; return 1
  fi
  [[ "$post_status" == "405" ]] || { echo "POST returned HTTP $post_status instead of 405" >&2; return 1; }
}

wait_for_service() {
  local attempt
  for attempt in {1..50}; do verify_service && return 0; /bin/sleep 0.1; done
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
snapshot_existing_job || die "$LAUNCHD_INSPECTION_ERROR"
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
if [[ "$HAD_JOB" -eq 1 ]]; then
  stop_service
fi
sudo /usr/bin/install -o root -g wheel -m 0644 "$PLIST_TEMP" "$PLIST_DEST"
sudo /bin/launchctl bootstrap system "$PLIST_DEST"
REPLACEMENT_JOB_STARTED=1
sudo /bin/launchctl enable "system/$LABEL"
sudo /bin/launchctl kickstart -k "system/$LABEL"
wait_for_service
DEPLOYING=0
echo "installed $LABEL on http://192.168.10.54:18080/"

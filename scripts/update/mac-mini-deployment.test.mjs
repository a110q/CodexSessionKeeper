import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const nginx = () => readFileSync(path.join(root, 'deploy', 'mac-mini', 'nginx.conf'), 'utf8');
const installer = () => readFileSync(
  path.join(root, 'deploy', 'mac-mini', 'install-static-update-server.sh'),
  'utf8',
);
const installerPath = path.join(root, 'deploy', 'mac-mini', 'install-static-update-server.sh');

function runInstallerFunctions(body, env = {}) {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'codex-update-test-'));
  const helperPath = path.join(tempDir, 'installer-functions.sh');
  const source = installer();
  writeFileSync(helperPath, source.slice(0, source.indexOf('\n/sbin/ifconfig')));
  try {
    return spawnSync('/bin/bash', [
      '-c',
      `set -uo pipefail
source "$1"
NGINX_BIN=/opt/homebrew/opt/nginx/bin/nginx
${body}`,
      'bash',
      helperPath,
    ], {
      encoding: 'utf8',
      env: { ...process.env, TMPDIR: tempDir, ...env },
    });
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

test('Nginx is fixed to the Mac mini, private ranges, and read-only HTTP methods', () => {
  const source = nginx();
  assert.match(source, /listen 192\.168\.10\.54:18080;/);
  assert.match(source, /root \/Users\/Shared\/codex-update-site;/);
  assert.match(source, /allow 10\.0\.0\.0\/8;/);
  assert.match(source, /allow 172\.16\.0\.0\/12;/);
  assert.match(source, /allow 192\.168\.0\.0\/16;/);
  assert.match(source, /deny all;/);
  assert.match(source, /\$request_method !~ \^\(GET\|HEAD\)\$/);
  assert.match(source, /return 405;/);
  assert.match(source, /autoindex off;/);
  assert.match(source, /Cache-Control "no-cache"/);
  assert.match(source, /max-age=31536000, immutable/);
});

test('installer refuses the wrong host and installs a root launch daemon', () => {
  const source = installer();
  assert.match(source, /EXPECTED_IP="192\.168\.10\.54"/);
  assert.match(source, /\/sbin\/ifconfig/);
  assert.match(source, /com\.company\.codex-update-server/);
  assert.match(source, /\/Library\/LaunchDaemons/);
  assert.match(source, /UserName.*root/);
  assert.match(source, /ProgramArguments/);
  assert.match(source, /daemon off;/);
  assert.doesNotMatch(source, /docker/i);
});

test('installer uses only Apple Silicon Homebrew and preserves the publishable site permissions', () => {
  const source = installer();
  assert.match(source, /ARCH="\$\(\/usr\/bin\/uname -m\)"/);
  assert.match(source, /\[\[ "\$ARCH" == "arm64" \]\]/);
  assert.match(source, /BREW_BIN="\/opt\/homebrew\/bin\/brew"/);
  assert.doesNotMatch(source, /\/usr\/local\/bin\/brew/);
  assert.match(source, /install -d -o root -g admin -m 0775/);
  assert.match(source, /SITE_ROOT/);
  assert.doesNotMatch(source, /chmod[^\n]*(?:0755|0700).*SITE_ROOT/);
  assert.doesNotMatch(source, /chmod[^\n]*-N/);
});

test('installer verifies the activated service, listener, health file, and method protection without swallowing failures', () => {
  const source = installer();
  assert.match(source, /launchctl print "system\/\$LABEL"/);
  assert.match(source, /lsof -nP -F pfn -iTCP:18080 -sTCP:LISTEN/);
  assert.match(source, /HEALTH_PATH="\/codex-session-keeper\/health\.txt"/);
  assert.match(source, /curl --fail --silent --show-error[^\n]*"http:\/\/\$EXPECTED_IP:18080\$HEALTH_PATH"/);
  assert.match(source, /curl --silent --show-error --output \/dev\/null --write-out '%\{http_code\}'[^\n]*-X POST/);
  assert.match(source, /\[\[ "\$post_status" == "405" \]\]/);
  assert.doesNotMatch(source, /curl[^\n]*\|\| true/);
});

test('installer protects against a foreign listener and rolls back an updated service after activation failure', () => {
  const source = installer();
  assert.match(source, /existing service does not own \$EXPECTED_IP:18080/);
  assert.match(source, /BACKUP_CONFIG/);
  assert.match(source, /BACKUP_PLIST/);
  assert.match(source, /rollback\(\)/);
  assert.match(source, /installed \$LABEL/);
  assert.match(source, /verify_service/);
});

test('listener inspection treats lsof status 1 as no listener but propagates operational errors', () => {
  const noListener = runInstallerFunctions(`
    sudo() { return 1; }
    listener_pids
  `);
  assert.equal(noListener.status, 0, noListener.stderr);
  assert.equal(noListener.stdout.trim(), '');

  const failure = runInstallerFunctions(`
    sudo() { return 2; }
    listener_pids
  `);
  assert.notEqual(failure.status, 0, failure.stderr);
  assert.match(failure.stderr, /unable to inspect listeners/);
});

test('listener validation accepts nginx workers descended from the running launchd master', () => {
  const result = runInstallerFunctions(`
    run_lsof() {
      cat <<'EOF'
p410
f8
n192.168.10.54:18080
p411
f8
n192.168.10.54:18080
EOF
    }
    run_launchctl_print() { printf 'state = running\\npid = 410\\n'; }
    process_command() {
      case "$1" in
        410) printf '%s -c %s -g daemon off;' "$NGINX_BIN" "$CONFIG_DEST" ;;
        411) printf 'nginx: worker process' ;;
      esac
    }
    process_parent_pid() { [[ "$1" == 411 ]] && printf '410' || printf '1'; }
    validate_listener_records
  `);
  assert.equal(result.status, 0, result.stderr);
});

test('listener validation rejects wildcard and separately launched matching nginx listeners', () => {
  const wildcard = runInstallerFunctions(`
    run_lsof() { printf 'p410\\nf8\\nn*:18080\\n'; }
    run_launchctl_print() { printf 'state = running\\npid = 410\\n'; }
    process_command() { printf '%s -c %s' "$NGINX_BIN" "$CONFIG_DEST"; }
    process_parent_pid() { printf '1'; }
    if validate_listener_records; then exit 1; fi
    grep -F 'unexpected listener endpoint' <<<"$LISTENER_VALIDATION_ERROR"
  `);
  assert.equal(wildcard.status, 0, wildcard.stderr);

  const separateProcess = runInstallerFunctions(`
    run_lsof() { printf 'p512\\nf8\\nn192.168.10.54:18080\\n'; }
    run_launchctl_print() { printf 'state = running\\npid = 410\\n'; }
    process_command() { printf '%s -c %s' "$NGINX_BIN" "$CONFIG_DEST"; }
    process_parent_pid() { printf '1'; }
    if validate_listener_records; then exit 1; fi
    grep -F 'not descended from launchd master' <<<"$LISTENER_VALIDATION_ERROR"
  `);
  assert.equal(separateProcess.status, 0, separateProcess.stderr);
});

test('listener validation rejects a launchd job that is loaded but not running', () => {
  const result = runInstallerFunctions(`
    run_lsof() { printf 'p410\\nf8\\nn192.168.10.54:18080\\n'; }
    run_launchctl_print() { printf 'state = exited\\npid = 410\\n'; }
    process_command() { printf '%s -c %s' "$NGINX_BIN" "$CONFIG_DEST"; }
    process_parent_pid() { printf '1'; }
    if validate_listener_records; then exit 1; fi
    grep -F 'launchd job is not running' <<<"$LISTENER_VALIDATION_ERROR"
  `);
  assert.equal(result.status, 0, result.stderr);
});

test('rollback reports a replacement stop failure instead of succeeding silently', () => {
  const result = runInstallerFunctions(`
    stop_service() { return 1; }
    restore_config() { return 0; }
    restore_plist() { return 0; }
    verify_rollback_restoration() { return 0; }
    DEPLOYING=1
    HAD_CONFIG=0
    HAD_PLIST=0
    HAD_JOB=0
    if rollback; then exit 1; fi
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /rollback failed/);
});

test('service stop propagates a launchctl bootout failure even if the wait helper returns success', () => {
  const result = runInstallerFunctions(`
    run_lsof() { printf 'p410\\nf8\\nn192.168.10.54:18080\\n'; }
    run_launchctl_print() { printf 'state = running\\npid = 410\\n'; }
    process_command() { printf '%s -c %s' "$NGINX_BIN" "$CONFIG_DEST"; }
    process_parent_pid() { printf '1'; }
    run_launchctl_bootout() { return 1; }
    wait_for_listener_to_stop() { return 0; }
    if stop_service; then exit 1; fi
  `);
  assert.equal(result.status, 0, result.stderr);
});

test('service stop unloads a loaded job even when it has already lost its listener', () => {
  const result = runInstallerFunctions(`
    run_lsof() { return 1; }
    run_launchctl_print() { printf 'state = exited\\npid = 410\\n'; }
    run_launchctl_bootout() { printf 'bootout-called\\n'; }
    wait_for_listener_to_stop() { return 0; }
    stop_service
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /bootout-called/);
});

test('rollback stops a known replacement after listener validation fails before restoring files', () => {
  const result = runInstallerFunctions(`
    lsof_counter="$(mktemp)"
    launchctl_counter="$(mktemp)"
    booted_marker="$(mktemp)"
    check_log="$(mktemp)"
    rm -f "$booted_marker"
    trap 'cat "$check_log"; rm -f "$lsof_counter" "$launchctl_counter" "$booted_marker" "$check_log"' EXIT
    run_lsof() {
      calls="$(wc -l < "$lsof_counter")"
      printf 'x\\n' >> "$lsof_counter"
      if [[ "$calls" -lt 51 ]]; then
        printf 'p410\\nf8\\nn*:18080\\n'
      else
        return 1
      fi
    }
    run_launchctl_print() {
      calls="$(wc -l < "$launchctl_counter")"
      printf 'x\\n' >> "$launchctl_counter"
      if [[ "$calls" -lt 51 ]]; then
        printf 'state = running\\npid = 410\\n'
      else
        printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
        return 113
      fi
    }
    run_launchctl_bootout() { : > "$booted_marker"; printf 'bootout-replacement\\n'; }
    process_command() { printf '%s -c %s' "$NGINX_BIN" "$CONFIG_DEST"; }
    process_parent_pid() { printf '1'; }
    process_identity() { [[ -e "$booted_marker" ]] && return 1; printf 'Mon Jul 21 10:00:00 2026 replacement nginx'; }
    restore_config() { printf 'restore-config\\n'; }
    restore_plist() { printf 'restore-plist\\n'; }
    verify_rollback_restoration() { printf 'verify-restore\\n'; }
    DEPLOYING=1
    REPLACEMENT_JOB_STARTED=1
    HAD_JOB=0
    if wait_for_service; then exit 1; fi
    rollback
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /bootout-replacement/);
  assert.match(result.stdout, /restore-config/);
  assert.match(result.stdout, /verify-restore/);
});

test('launchctl inspection distinguishes present jobs, explicit absence, and operational failures', () => {
  const running = runInstallerFunctions(`
    run_launchctl_print() { printf 'state = running\\npid = 410\\n'; }
    inspect_launchd_job
    [[ "$LAUNCHD_JOB_PRESENT" == 1 ]]
    grep -F 'state = running' <<<"$LAUNCHD_JOB_OUTPUT"
  `);
  assert.equal(running.status, 0, running.stderr);

  const exited = runInstallerFunctions(`
    run_launchctl_print() { printf 'state = exited\\npid = 410\\n'; }
    inspect_launchd_job
    [[ "$LAUNCHD_JOB_PRESENT" == 1 ]]
  `);
  assert.equal(exited.status, 0, exited.stderr);

  const absent = runInstallerFunctions(`
    run_launchctl_print() {
      printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
      return 113
    }
    process_parent_pid() { return 1; }
    inspect_launchd_job
    [[ "$LAUNCHD_JOB_PRESENT" == 0 ]]
  `);
  assert.equal(absent.status, 0, absent.stderr);

  const operationalFailure = runInstallerFunctions(`
    run_launchctl_print() { printf 'launchctl: permission denied\\n'; return 1; }
    if inspect_launchd_job; then exit 1; fi
    grep -F 'could not inspect launchd job' <<<"$LAUNCHD_INSPECTION_ERROR"
  `);
  assert.equal(operationalFailure.status, 0, operationalFailure.stderr);
});

test('job snapshot and preflight stop preserve present states and reject launchctl operational failures', () => {
  const exited = runInstallerFunctions(`
    run_launchctl_print() { printf 'state = exited\\npid = 410\\n'; }
    snapshot_existing_job
    [[ "$HAD_JOB" == 1 ]]
  `);
  assert.equal(exited.status, 0, exited.stderr);

  const absent = runInstallerFunctions(`
    run_launchctl_print() { printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"; return 113; }
    snapshot_existing_job
    [[ "$HAD_JOB" == 0 ]]
  `);
  assert.equal(absent.status, 0, absent.stderr);

  const preflightFailure = runInstallerFunctions(`
    run_lsof() { return 1; }
    run_launchctl_print() { printf 'launchctl: permission denied\\n'; return 1; }
    if stop_service; then exit 1; fi
  `);
  assert.equal(preflightFailure.status, 0, preflightFailure.stderr);

  const snapshotFailure = runInstallerFunctions(`
    run_launchctl_print() { printf 'launchctl: permission denied\\n'; return 1; }
    if snapshot_existing_job; then exit 1; fi
  `);
  assert.equal(snapshotFailure.status, 0, snapshotFailure.stderr);
});

test('replacement rollback checks a captured master after its launchd label is already absent', () => {
  const result = runInstallerFunctions(`
    lsof_counter="$(mktemp)"
    launchctl_counter="$(mktemp)"
    check_log="$(mktemp)"
    trap 'cat "$check_log"; rm -f "$lsof_counter" "$launchctl_counter" "$check_log"' EXIT
    run_lsof() {
      calls="$(wc -l < "$lsof_counter")"
      printf 'x\\n' >> "$lsof_counter"
      if [[ "$calls" -eq 0 ]]; then
        printf 'p410\\nf8\\nn192.168.10.54:18080\\n'
      else
        printf 'replacement-listener-checked\\n' >> "$check_log"
        return 1
      fi
    }
    run_launchctl_print() {
      calls="$(wc -l < "$launchctl_counter")"
      printf 'x\\n' >> "$launchctl_counter"
      if [[ "$calls" -eq 0 ]]; then
        printf 'state = running\\npid = 410\\n'
      else
        printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
        return 113
      fi
    }
    process_command() { printf '%s -c %s' "$NGINX_BIN" "$CONFIG_DEST"; }
    process_parent_pid() { printf '1'; }
    process_identity() { printf 'Mon Jul 21 10:00:00 2026 replacement nginx'; }
    REPLACEMENT_JOB_STARTED=1
    validate_listener_records
    stop_replacement_service
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /replacement-listener-checked/);
});

test('replacement stop waits for listener PIDs captured before the master can be reparented', () => {
  const result = runInstallerFunctions(`
    booted_marker="$(mktemp)"
    launchctl_counter="$(mktemp)"
    rm -f "$booted_marker"
    trap 'rm -f "$booted_marker" "$launchctl_counter"' EXIT
    run_lsof() { printf 'p411\\nf8\\nn192.168.10.54:18080\\n'; }
    run_launchctl_print() {
      calls="$(wc -l < "$launchctl_counter")"
      printf 'x\\n' >> "$launchctl_counter"
      if [[ "$calls" -eq 0 ]]; then
        printf 'state = running\\npid = 410\\n'
      else
        printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
        return 113
      fi
    }
    run_launchctl_bootout() { : > "$booted_marker"; }
    process_parent_pid() {
      [[ -e "$booted_marker" ]] && printf '1' || printf '410'
    }
    process_identity() { printf 'Mon Jul 21 10:00:00 2026 replacement nginx'; }
    REPLACEMENT_JOB_STARTED=1
    if stop_replacement_service; then exit 1; fi
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /replacement listener processes did not exit/);
});

test('listener status 1 is empty only when lsof also has no stderr', () => {
  const empty = runInstallerFunctions(`
    run_lsof() { return 1; }
    listener_records
  `);
  assert.equal(empty.status, 0, empty.stderr);
  assert.equal(empty.stdout.trim(), '');

  const error = runInstallerFunctions(`
    run_lsof() { printf 'lsof: permission denied\\n' >&2; return 1; }
    if listener_records; then exit 1; fi
  `);
  assert.equal(error.status, 0, error.stderr);
  assert.match(error.stderr, /lsof: permission denied/);
});

test('launchctl absence requires the observed status 113 and exact English message for this label', () => {
  assert.match(installer(), /run_launchctl_print\(\) \{ sudo \/usr\/bin\/env LC_ALL=C LANG=C \/bin\/launchctl print/);
  const exactAbsent = runInstallerFunctions(`
    run_launchctl_print() {
      printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
      return 113
    }
    inspect_launchd_job
    [[ "$LAUNCHD_JOB_PRESENT" == 0 ]]
  `);
  assert.equal(exactAbsent.status, 0, exactAbsent.stderr);

  const wrongLabel = runInstallerFunctions(`
    run_launchctl_print() {
      printf 'Bad request.\\nCould not find service "other.service" in domain for system\\n'
      return 113
    }
    if inspect_launchd_job; then exit 1; fi
  `);
  assert.equal(wrongLabel.status, 0, wrongLabel.stderr);

  const wrongStatus = runInstallerFunctions(`
    run_launchctl_print() {
      printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
      return 1
    }
    if inspect_launchd_job; then exit 1; fi
  `);
  assert.equal(wrongStatus.status, 0, wrongStatus.stderr);

  const localized = runInstallerFunctions(`
    run_launchctl_print() { printf '请求错误。\\n找不到服务。\\n'; return 113; }
    if inspect_launchd_job; then exit 1; fi
  `);
  assert.equal(localized.status, 0, localized.stderr);
});

test('rollback refuses file restore when a replacement label is absent but port 18080 is still occupied', () => {
  const result = runInstallerFunctions(`
    run_lsof() { printf 'p777\\nf8\\nn192.168.10.54:18080\\n'; }
    run_launchctl_print() {
      printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
      return 113
    }
    wait_for_listener_to_stop() { printf 'port-empty-check\\n'; return 1; }
    restore_config() { printf 'restore-config\\n'; }
    restore_plist() { printf 'restore-plist\\n'; }
    verify_rollback_restoration() { printf 'verify-restore\\n'; }
    DEPLOYING=1
    REPLACEMENT_JOB_STARTED=1
    REPLACEMENT_MASTER_PID=999
    if rollback; then exit 1; fi
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /port-empty-check/);
  assert.doesNotMatch(result.stdout, /restore-config|restore-plist|verify-restore/);
});

test('ERR rollback simulation stops replacement and checks an empty port before restore', () => {
  const result = runInstallerFunctions(`
    set -eE
    log_file="$(mktemp)"
    trap 'cat "$log_file"; rm -f "$log_file"' EXIT
    run_launchctl_bootstrap() { printf 'bootstrap\\n' >> "$log_file"; }
    run_launchctl_enable() { printf 'enable\\n' >> "$log_file"; return 1; }
    run_launchctl_kickstart() { printf 'kickstart\\n' >> "$log_file"; }
    run_launchctl_print() {
      printf 'Bad request.\\nCould not find service "%s" in domain for system\\n' "$LABEL"
      return 113
    }
    run_lsof() { printf 'p777\\nf8\\nn192.168.10.54:18080\\n'; }
    wait_for_listener_to_stop() { printf 'port-empty-check\\n' >> "$log_file"; return 1; }
    restore_config() { printf 'restore-config\\n' >> "$log_file"; }
    restore_plist() { printf 'restore-plist\\n' >> "$log_file"; }
    verify_rollback_restoration() { printf 'verify-restore\\n' >> "$log_file"; }
    DEPLOYING=1
    activate() {
      run_launchctl_bootstrap
      REPLACEMENT_JOB_STARTED=1
      run_launchctl_enable
      run_launchctl_kickstart
    }
    activate
  `);
  assert.notEqual(result.status, 0, result.stderr);
  assert.match(result.stderr, /rollback failed/);
  assert.match(result.stdout, /bootstrap\nenable\nport-empty-check/);
  assert.doesNotMatch(result.stdout, /restore-config|restore-plist|verify-restore/);
});

test('replacement identities must exit rather than merely stop listening', () => {
  const alive = runInstallerFunctions(`
    process_identity() { printf 'Mon Jul 21 10:00:00 2026 nginx worker'; }
    if wait_for_replacement_identities_to_exit $'411\\tMon Jul 21 10:00:00 2026 nginx worker'; then exit 1; fi
  `);
  assert.equal(alive.status, 0, alive.stderr);

  const exited = runInstallerFunctions(`
    process_identity() { return 1; }
    wait_for_replacement_identities_to_exit $'411\\tMon Jul 21 10:00:00 2026 nginx worker'
  `);
  assert.equal(exited.status, 0, exited.stderr);

  const reused = runInstallerFunctions(`
    process_identity() { printf 'Mon Jul 21 11:00:00 2026 unrelated process'; }
    wait_for_replacement_identities_to_exit $'411\\tMon Jul 21 10:00:00 2026 nginx worker'
  `);
  assert.equal(reused.status, 0, reused.stderr);
});

test('site file rollback removes new files and restores prior marker and health snapshots', () => {
  const fresh = runInstallerFunctions(`
    restore_site_file() { printf "restore:$1:$2\\n"; }
    MARKER_HAD_FILE=0
    HEALTH_HAD_FILE=0
    rollback_site_files
  `);
  assert.equal(fresh.status, 0, fresh.stderr);
  assert.match(fresh.stdout, /restore:.*\.codex-update-root:0/);
  assert.match(fresh.stdout, /restore:.*health\.txt:0/);

  const existing = runInstallerFunctions(`
    restore_site_file() { printf "restore:$1:$2\\n"; }
    MARKER_HAD_FILE=1
    HEALTH_HAD_FILE=1
    rollback_site_files
  `);
  assert.equal(existing.status, 0, existing.stderr);
  assert.match(existing.stdout, /restore:.*\.codex-update-root:1/);
  assert.match(existing.stdout, /restore:.*health\.txt:1/);
});

test('site file snapshots restore exact contents and metadata', () => {
  const result = runInstallerFunctions(`
    sudo() { "$@"; }
    site_dir="$(mktemp -d)"
    trap 'rm -rf "$site_dir"' EXIT
    MARKER_PATH="$site_dir/.codex-update-root"
    HEALTH_DEST="$site_dir/health.txt"
    BACKUP_MARKER="$(mktemp)"
    BACKUP_HEALTH="$(mktemp)"
    printf 'old marker\\n' > "$MARKER_PATH"
    printf 'old health\\n' > "$HEALTH_DEST"
    chmod 0640 "$MARKER_PATH"
    chmod 0600 "$HEALTH_DEST"
    backup_site_files
    marker_metadata="$MARKER_METADATA"
    health_metadata="$HEALTH_METADATA"
    printf 'replacement marker\\n' > "$MARKER_PATH"
    printf 'replacement health\\n' > "$HEALTH_DEST"
    chmod 0666 "$MARKER_PATH" "$HEALTH_DEST"
    rollback_site_files
    cmp -s "$BACKUP_MARKER" "$MARKER_PATH"
    cmp -s "$BACKUP_HEALTH" "$HEALTH_DEST"
    [[ "$(site_file_metadata "$MARKER_PATH")" == "$marker_metadata" ]]
    [[ "$(site_file_metadata "$HEALTH_DEST")" == "$health_metadata" ]]
    MARKER_PATH="$site_dir/new-marker"
    HEALTH_DEST="$site_dir/new-health"
    BACKUP_MARKER="$(mktemp)"
    BACKUP_HEALTH="$(mktemp)"
    MARKER_HAD_FILE=0
    HEALTH_HAD_FILE=0
    MARKER_METADATA=""
    HEALTH_METADATA=""
    printf 'new marker\\n' > "$MARKER_PATH"
    printf 'new health\\n' > "$HEALTH_DEST"
    rollback_site_files
    [[ ! -e "$MARKER_PATH" && ! -e "$HEALTH_DEST" ]]
  `);
  assert.equal(result.status, 0, result.stderr);
});

test('production activation function rolls back bootstrap, enable, and kickstart failures before restore', () => {
  assert.match(installer(), /activate_service\(\) \{[\s\S]*run_launchctl_bootstrap[\s\S]*run_launchctl_enable[\s\S]*run_launchctl_kickstart/);
  for (const failingStep of ['bootstrap', 'enable', 'kickstart']) {
    const result = runInstallerFunctions(`
      set -e
      log_file="$(mktemp)"
      trap 'cat "$log_file"; rm -f "$log_file"' EXIT
      stop_service() { printf 'port-empty\\n' >> "$log_file"; }
      install_launchd_plist() { printf 'install-plist\\n' >> "$log_file"; }
      run_launchctl_bootstrap() { printf 'bootstrap\\n' >> "$log_file"; [[ "${failingStep}" != bootstrap ]]; }
      run_launchctl_enable() { printf 'enable\\n' >> "$log_file"; [[ "${failingStep}" != enable ]]; }
      run_launchctl_kickstart() { printf 'kickstart\\n' >> "$log_file"; [[ "${failingStep}" != kickstart ]]; }
      wait_for_service() { printf 'verify\\n' >> "$log_file"; }
      stop_replacement_service() { printf 'stop-replacement\\nport-empty\\n' >> "$log_file"; }
      rollback_site_files() { printf 'restore-site\\n' >> "$log_file"; }
      restore_config() { printf 'restore-config\\n' >> "$log_file"; }
      restore_plist() { printf 'restore-plist\\n' >> "$log_file"; }
      verify_rollback_restoration() { printf 'verify-restore\\n' >> "$log_file"; }
      DEPLOYING=1
      HAD_JOB=0
      activate_service
    `);
    assert.notEqual(result.status, 0, `${failingStep}: ${result.stderr}`);
    assert.match(result.stdout, /bootstrap/);
    assert.match(result.stdout, /port-empty/);
    assert.ok(result.stdout.indexOf('port-empty') < result.stdout.indexOf('restore-site'));
    if (failingStep === 'bootstrap') {
      assert.doesNotMatch(result.stdout, /stop-replacement/);
    } else {
      assert.match(result.stdout, /stop-replacement/);
    }
    assert.doesNotMatch(result.stdout, /installed/);
  }
});

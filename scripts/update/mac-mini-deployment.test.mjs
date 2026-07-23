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
      env: { ...process.env, ...env },
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

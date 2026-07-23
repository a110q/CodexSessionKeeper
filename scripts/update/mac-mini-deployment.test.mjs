import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const nginx = () => readFileSync(path.join(root, 'deploy', 'mac-mini', 'nginx.conf'), 'utf8');
const installer = () => readFileSync(
  path.join(root, 'deploy', 'mac-mini', 'install-static-update-server.sh'),
  'utf8',
);

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
  assert.match(source, /lsof -nP -t -iTCP@"\$EXPECTED_IP":18080 -sTCP:LISTEN/);
  assert.match(source, /HEALTH_PATH="\/codex-session-keeper\/health\.txt"/);
  assert.match(source, /curl --fail --silent --show-error[^\n]*"http:\/\/\$EXPECTED_IP:18080\$HEALTH_PATH"/);
  assert.match(source, /curl --silent --show-error --output \/dev\/null --write-out '%\{http_code\}'[^\n]*-X POST/);
  assert.match(source, /\[\[ "\$post_status" != "405" \]\]/);
  assert.doesNotMatch(source, /curl[^\n]*\|\| true/);
});

test('installer protects against a foreign listener and rolls back an updated service after activation failure', () => {
  const source = installer();
  assert.match(source, /existing service does not own 192\.168\.10\.54:18080/);
  assert.match(source, /BACKUP_CONFIG/);
  assert.match(source, /BACKUP_PLIST/);
  assert.match(source, /rollback\(\)/);
  assert.match(source, /installed \$LABEL/);
  assert.match(source, /verify_service/);
});

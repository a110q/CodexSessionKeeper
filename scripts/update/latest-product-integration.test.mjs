import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

test('latest bounded backup and signed updater coexist', () => {
  assert.equal(
    existsSync('Sources/CodexSessionVaultCore/Backup/SessionBackupStreamer.swift'),
    true,
    'latest bounded Swift backup streamer is missing',
  );
  assert.equal(
    existsSync('Tests/CodexSessionVaultCoreTests/LargeJSONLEndToEndAcceptanceTests.swift'),
    true,
    'large JSONL acceptance suite is missing',
  );
  assert.equal(
    existsSync('Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift'),
    true,
    'macOS updater is missing',
  );
  assert.equal(existsSync('Config/UpdateServer.testing.json'), true);
  assert.equal(
    existsSync('windows/codex_session_manager_electron/src/update/update-service.js'),
    true,
    'Windows updater is missing',
  );
});

test('macOS package explains and allows company-LAN update access', () => {
  const script = readFileSync('scripts/build_app.sh', 'utf8');
  assert.match(script, /<key>NSLocalNetworkUsageDescription<\/key>/);
  assert.match(script, /用于连接公司局域网更新服务器/);
  assert.match(script, /<key>NSAllowsLocalNetworking<\/key>\s*<true\/>/);
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { parseUpdateServerConfig, UPDATE_SERVER } from './update-server.mjs';

const RELEASE_BASE = 'http://192.168.10.54:18080/codex-session-keeper/stable/';
const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '..', '..');

test('repository update server is the fixed Mac mini endpoint', () => {
  assert.deepEqual(UPDATE_SERVER, {
    releaseBaseURL: RELEASE_BASE,
    windowsFeedURL: `${RELEASE_BASE}windows/`,
    macDownloadPrefix: `${RELEASE_BASE}macos/`,
    macAppcastURL: `${RELEASE_BASE}macos/appcast.xml`,
  });
});

test('update server parser rejects mutable or ambiguous URLs', () => {
  for (const releaseBaseURL of [
    'ftp://192.168.10.54:18080/codex-session-keeper/stable/',
    'http://user:pass@192.168.10.54:18080/codex-session-keeper/stable/',
    'http://192.168.10.54:18080/codex-session-keeper/stable/?channel=beta',
    'http://192.168.10.54:18080/codex-session-keeper/stable/#latest',
    'http://192.168.10.54:18080/other/stable/',
    'http://192.168.10.54:18080/codex-session-keeper/stable',
  ]) {
    assert.throws(
      () => parseUpdateServerConfig({ releaseBaseURL }),
      /releaseBaseURL/,
      releaseBaseURL,
    );
  }
});

test('macOS packaging reads UpdateServer.json and retains no NAS fallback', () => {
  const buildScript = readFileSync(path.join(repositoryRoot, 'scripts', 'build_app.sh'), 'utf8');
  const coordinator = readFileSync(
    path.join(repositoryRoot, 'Sources', 'CodexSessionVault', 'Update', 'MacUpdateCoordinator.swift'),
    'utf8',
  );

  assert.match(buildScript, /Config\/UpdateServer\.json/);
  assert.doesNotMatch(buildScript, /UPDATE_BASE_URL:-/);
  assert.doesNotMatch(buildScript, /192\.168\.10\.99/);
  assert.doesNotMatch(coordinator, /fallbackBaseURL/);
  assert.doesNotMatch(coordinator, /192\.168\.10\.99/);
});

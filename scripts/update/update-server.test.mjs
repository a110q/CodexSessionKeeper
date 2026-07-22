import assert from 'node:assert/strict';
import test from 'node:test';

import { parseUpdateServerConfig, UPDATE_SERVER } from './update-server.mjs';

const RELEASE_BASE = 'http://192.168.10.54:18080/codex-session-keeper/stable/';

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

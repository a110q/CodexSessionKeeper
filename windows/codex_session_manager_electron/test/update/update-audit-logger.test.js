const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { createUpdateAuditLogger } = require('../../src/update/update-audit-logger');

test('writes bounded JSONL update audit entries', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-update-audit-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'update-audit.jsonl');
  const audit = createUpdateAuditLogger({
    filePath,
    now: () => new Date('2026-07-24T00:00:00.000Z'),
    platform: 'windows-x64',
  });

  await audit({ event: 'download_confirmation_requested', version: '1.1.0' });
  await audit({ event: 'download_confirmed', version: '1.1.0' });

  const entries = (await fs.readFile(filePath, 'utf8'))
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line));
  assert.deepEqual(entries, [
    {
      schemaVersion: 1,
      timestamp: '2026-07-24T00:00:00.000Z',
      platform: 'windows-x64',
      event: 'download_confirmation_requested',
      version: '1.1.0',
    },
    {
      schemaVersion: 1,
      timestamp: '2026-07-24T00:00:00.000Z',
      platform: 'windows-x64',
      event: 'download_confirmed',
      version: '1.1.0',
    },
  ]);
});

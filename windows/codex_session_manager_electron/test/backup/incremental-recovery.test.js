'use strict';

const assert = require('node:assert/strict');
const fsSync = require('node:fs');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  loadIncrementalBackupCatalog,
  preflightIncrementalRecovery,
  restoreIncrementalSessions,
} = require('../../src/backup/incremental-recovery');

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'incremental-recovery-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const paths = {
    codexRoot: path.join(root, '.codex'),
    backupRoot: path.join(root, 'nas', 'incremental-backups'),
    manifestPath: path.join(root, 'nas', 'incremental-backups', 'manifest.json'),
  };
  await fs.mkdir(paths.backupRoot, { recursive: true });
  await fs.mkdir(paths.codexRoot, { recursive: true });
  return { root, paths };
}

async function writeManifest(paths, sessions) {
  await fs.writeFile(paths.manifestPath, JSON.stringify({
    version: 2,
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    createdAt: '2026-07-08T12:00:00.000Z',
    updatedAt: '2026-07-08T12:05:00.000Z',
    sessions,
  }, null, 2));
}

function record(sessionId, backupPath, title = sessionId) {
  return {
    sessionId,
    sourcePath: `C:\\Users\\Ada\\.codex\\sessions\\${sessionId}.jsonl`,
    backupPath,
    title,
    firstSeenAt: '2026-07-08T12:00:00.000Z',
    lastBackedUpAt: '2026-07-08T12:05:00.000Z',
    lineCount: 1,
    bytesBackedUp: 32,
    status: 'active',
  };
}

async function addBackup(paths, sessionId, content = '{"role":"user"}\n') {
  const backupPath = path.join('sessions', '2026', '07', `${sessionId}.jsonl`);
  const filePath = path.join(paths.backupRoot, backupPath);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, content);
  return record(sessionId, backupPath, `${sessionId} title`);
}

test('catalog classifies missing and existing backup sessions', async (t) => {
  const { paths } = await makeFixture(t);
  const missing = await addBackup(paths, 'missing');
  const existing = await addBackup(paths, 'existing');
  await writeManifest(paths, { missing, existing });

  const result = await loadIncrementalBackupCatalog({
    paths,
    currentSessionIds: new Set(['existing']),
  });

  assert.equal(result.totalCount, 2);
  assert.equal(result.missingCount, 1);
  assert.equal(result.candidates.find((item) => item.sessionId === 'missing').isRestorable, true);
  assert.equal(result.candidates.find((item) => item.sessionId === 'existing').status, 'existing');
});

test('preflight validates the complete source set before recovery side effects', async (t) => {
  const { root, paths } = await makeFixture(t);
  const good = await addBackup(paths, 'good');
  const outsideRoot = path.join(root, 'outside');
  const linkedRoot = path.join(paths.backupRoot, 'sessions', 'linked');
  await fs.mkdir(outsideRoot);
  await fs.writeFile(path.join(outsideRoot, 'bad.jsonl'), 'outside\n');
  await fs.symlink(outsideRoot, linkedRoot, process.platform === 'win32' ? 'junction' : 'dir');
  await writeManifest(paths, {
    good,
    bad: record('bad', path.join('sessions', 'linked', 'bad.jsonl')),
  });

  await assert.rejects(
    preflightIncrementalRecovery({ paths, sessionIds: ['good', 'bad'] }),
    (error) => error.code === 'INVALID_SNAPSHOT_PATH',
  );

  assert.equal(fsSync.existsSync(path.join(paths.codexRoot, 'sessions', 'recovered')), false);
  assert.equal(fsSync.existsSync(path.join(paths.backupRoot, 'recovery-packages')), false);
});

test('direct restore writes selected files atomically and merges session index without a package', async (t) => {
  const { paths } = await makeFixture(t);
  const selectedContent = '{"role":"user","content":"selected"}\n';
  const selected = await addBackup(paths, 'selected', selectedContent);
  const other = await addBackup(paths, 'other', '{"role":"user","content":"other"}\n');
  await writeManifest(paths, { selected, other });
  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['selected'] });

  const result = await restoreIncrementalSessions({ paths, preflight });

  const recoveredPath = path.join(paths.codexRoot, 'sessions', 'recovered', 'selected.jsonl');
  assert.equal(await fs.readFile(recoveredPath, 'utf8'), selectedContent);
  assert.equal(result.recoveredFiles.selected, recoveredPath);
  assert.equal(fsSync.existsSync(path.join(paths.codexRoot, 'sessions', 'recovered', 'other.jsonl')), false);
  assert.match(await fs.readFile(path.join(paths.codexRoot, 'session_index.jsonl'), 'utf8'), /"id":"selected"/);
  assert.equal(fsSync.existsSync(path.join(paths.backupRoot, 'recovery-packages')), false);
});

test('restore revalidates every preflight source and never overwrites a destination', async (t) => {
  const { root, paths } = await makeFixture(t);
  const selected = await addBackup(paths, 'selected', 'safe\n');
  await writeManifest(paths, { selected });
  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['selected'] });
  const sourceRoot = path.join(paths.backupRoot, 'sessions');
  const outsideRoot = path.join(root, 'outside');
  await fs.mkdir(outsideRoot);
  await fs.writeFile(path.join(outsideRoot, 'selected.jsonl'), 'outside\n');
  await fs.rm(sourceRoot, { recursive: true });
  await fs.symlink(outsideRoot, sourceRoot, process.platform === 'win32' ? 'junction' : 'dir');

  await assert.rejects(
    restoreIncrementalSessions({ paths, preflight }),
    (error) => error.code === 'INVALID_SNAPSHOT_PATH',
  );
  assert.equal(fsSync.existsSync(path.join(paths.codexRoot, 'sessions', 'recovered')), false);

  await fs.rm(sourceRoot, { force: true });
  await fs.mkdir(path.dirname(preflight[0].sourcePath), { recursive: true });
  await fs.writeFile(preflight[0].sourcePath, 'safe\n');
  const destination = path.join(paths.codexRoot, 'sessions', 'recovered', 'selected.jsonl');
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.writeFile(destination, 'live\n');
  await assert.rejects(restoreIncrementalSessions({ paths, preflight }), /already exists/i);
  assert.equal(await fs.readFile(destination, 'utf8'), 'live\n');
});

test('catalog keeps invalid and missing backup records visible but not restorable', async (t) => {
  const { paths } = await makeFixture(t);
  await writeManifest(paths, {
    escaped: record('escaped', '..\\outside.jsonl'),
    missing: record('missing', path.join('sessions', 'missing.jsonl')),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });
  assert.equal(catalog.candidates.find((item) => item.sessionId === 'escaped').status, 'invalidBackup');
  assert.equal(catalog.candidates.find((item) => item.sessionId === 'missing').status, 'backupFileMissing');
  assert.equal(catalog.candidates.every((item) => item.isRestorable === false), true);
});

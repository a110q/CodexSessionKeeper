const assert = require('node:assert/strict');
const fsSync = require('node:fs');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  buildIncrementalRecoveryPackage,
  loadIncrementalBackupCatalog,
} = require('../../src/backup/incremental-recovery');

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'incremental-recovery-'));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  const paths = {
    codexRoot: path.join(root, '.codex'),
    backupRoot: path.join(root, 'vault', 'incremental-backups'),
    manifestPath: path.join(root, 'vault', 'incremental-backups', 'manifest.json'),
  };
  await fs.mkdir(paths.backupRoot, { recursive: true });
  return { root, paths };
}

async function writeManifest(paths, sessions) {
  await fs.writeFile(paths.manifestPath, JSON.stringify({
    version: 1,
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    createdAt: '2026-07-08T12:00:00.000Z',
    updatedAt: '2026-07-08T12:05:00.000Z',
    sessions,
  }, null, 2), 'utf8');
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

test('catalog classifies missing and existing backup sessions', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'missing.jsonl'), '{"role":"user"}\n');
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'existing.jsonl'), '{"role":"user"}\n');
  await writeManifest(paths, {
    missing: record('missing', path.join('sessions', '2026', '07', '08', 'missing.jsonl'), 'missing title'),
    existing: record('existing', path.join('sessions', '2026', '07', '08', 'existing.jsonl'), 'existing title'),
  });

  const result = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set(['existing']) });

  assert.equal(result.totalCount, 2);
  assert.equal(result.missingCount, 1);
  assert.equal(result.existingCount, 1);
  assert.equal(result.candidates.find((item) => item.sessionId === 'missing').status, 'missing');
  assert.equal(result.candidates.find((item) => item.sessionId === 'existing').status, 'existing');
});

test('catalog candidates retain backup records for sqlite repair', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'missing.jsonl'), '{"role":"user"}\n');
  await writeManifest(paths, {
    missing: record('missing', path.join('sessions', '2026', '07', '08', 'missing.jsonl'), 'manifest title'),
  });

  const result = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });

  assert.equal(result.candidates[0].backupRecord.sessionId, 'missing');
  assert.equal(result.candidates[0].backupRecord.title, 'manifest title');
  assert.equal(result.candidates[0].backupRecord.backupPath, path.join('sessions', '2026', '07', '08', 'missing.jsonl'));
});

test('catalog rejects path traversal and package only copies selected sessions', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(
    path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'selected.jsonl'),
    '{"role":"user","content":"selected"}\n'
  );
  await fs.writeFile(
    path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'other.jsonl'),
    '{"role":"user","content":"other"}\n'
  );
  await writeManifest(paths, {
    selected: record('selected', path.join('sessions', '2026', '07', '08', 'selected.jsonl'), 'selected'),
    other: record('other', path.join('sessions', '2026', '07', '08', 'other.jsonl'), 'other'),
    bad: record('bad', '..\\outside.jsonl', 'bad'),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });
  assert.equal(catalog.candidates.find((item) => item.sessionId === 'bad').status, 'invalidBackup');

  const recovery = await buildIncrementalRecoveryPackage({
    paths,
    sessionIds: ['selected'],
    now: () => new Date('2026-07-08T12:30:00.000Z'),
  });

  assert.equal(
    await fs.readFile(path.join(recovery.dataPath, 'sessions', 'recovered', 'selected.jsonl'), 'utf8'),
    '{"role":"user","content":"selected"}\n'
  );
  await assert.rejects(
    fs.access(path.join(recovery.dataPath, 'sessions', 'recovered', 'other.jsonl')),
    /ENOENT/
  );
  const indexText = await fs.readFile(path.join(recovery.dataPath, 'session_index.jsonl'), 'utf8');
  assert.match(indexText, /"id":"selected"/);
  assert.doesNotMatch(indexText, /"id":"other"/);
});

test('recovery package exposes recovered file paths by session id', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(
    path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'selected.jsonl'),
    '{"role":"user","content":"selected"}\n'
  );
  await writeManifest(paths, {
    selected: record('selected', path.join('sessions', '2026', '07', '08', 'selected.jsonl'), 'selected'),
  });

  const recovery = await buildIncrementalRecoveryPackage({
    paths,
    sessionIds: ['selected'],
    now: () => new Date('2026-07-08T12:30:00.000Z'),
  });

  assert.equal(
    recovery.recoveredFiles.selected,
    path.join(recovery.dataPath, 'sessions', 'recovered', 'selected.jsonl')
  );
  assert.equal(
    await fs.readFile(recovery.recoveredFiles.selected, 'utf8'),
    '{"role":"user","content":"selected"}\n'
  );
});

test('missing backup file is visible but not restorable', async (t) => {
  const { paths } = await makeFixture(t);
  await writeManifest(paths, {
    missingFile: record('missingFile', path.join('sessions', '2026', '07', '08', 'missingFile.jsonl'), 'missing file'),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });

  const candidate = catalog.candidates[0];
  assert.equal(candidate.status, 'backupFileMissing');
  assert.equal(candidate.isRestorable, false);
  assert.match(candidate.error, /Backup file is missing/);
});

test('catalog and package reject backup files reached through symlinks', async (t) => {
  const { root, paths } = await makeFixture(t);
  const outsideRoot = path.join(root, 'outside');
  const linkPath = path.join(paths.backupRoot, 'sessions', 'linked-outside');
  await fs.mkdir(outsideRoot, { recursive: true });
  await fs.mkdir(path.dirname(linkPath), { recursive: true });
  await fs.writeFile(path.join(outsideRoot, 'secret.jsonl'), 'outside-secret\n');
  await fs.symlink(outsideRoot, linkPath, process.platform === 'win32' ? 'junction' : 'dir');
  await writeManifest(paths, {
    escaped: record('escaped', path.join('sessions', 'linked-outside', 'secret.jsonl')),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });
  assert.equal(catalog.candidates[0].status, 'invalidBackup');
  assert.equal(catalog.candidates[0].isRestorable, false);
  await assert.rejects(
    buildIncrementalRecoveryPackage({ paths, sessionIds: ['escaped'] }),
    (error) => error.code === 'INVALID_SNAPSHOT_PATH'
  );
});

test('package revalidates a backup source changed after cataloging', async (t) => {
  const { root, paths } = await makeFixture(t);
  const sessionsRoot = path.join(paths.backupRoot, 'sessions');
  const outsideRoot = path.join(root, 'outside');
  await fs.mkdir(sessionsRoot, { recursive: true });
  await fs.mkdir(outsideRoot, { recursive: true });
  await fs.writeFile(path.join(sessionsRoot, 'selected.jsonl'), 'safe\n');
  await fs.writeFile(path.join(outsideRoot, 'selected.jsonl'), 'outside\n');
  await writeManifest(paths, {
    selected: record('selected', path.join('sessions', 'selected.jsonl')),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });
  assert.equal(catalog.candidates[0].isRestorable, true);
  await fs.rm(sessionsRoot, { recursive: true, force: true });
  await fs.symlink(outsideRoot, sessionsRoot, process.platform === 'win32' ? 'junction' : 'dir');

  await assert.rejects(
    buildIncrementalRecoveryPackage({ paths, sessionIds: ['selected'] }),
    (error) => error.code === 'INVALID_SNAPSHOT_PATH'
  );
  assert.equal(fsSync.existsSync(path.join(paths.backupRoot, 'recovery-packages')), false);
});

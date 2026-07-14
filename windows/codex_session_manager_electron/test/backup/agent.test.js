const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { BackupAgent, createFileCommitter } = require('../../src/backup/backup-agent');
const { CursorStore } = require('../../src/backup/cursor-store');
const { backupPaths } = require('../../src/backup/paths');
const { readNewCompleteLines } = require('../../src/backup/session-tailer');

async function makeTestPaths(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-backup-agent-'));
  t.after(async () => {
    await fs.rm(root, { force: true, recursive: true });
  });

  const codexRoot = path.join(root, '.codex');
  const backupRoot = path.join(root, 'vault', 'incremental-backups');
  const stateRoot = path.join(root, 'local-state');
  await fs.mkdir(backupRoot, { recursive: true });

  return {
    root,
    paths: backupPaths({ homeDir: root, codexRoot, backupRoot, stateRoot, pathImpl: path }),
  };
}

function jsonLine(record) {
  return `${JSON.stringify(record)}\n`;
}

async function writeSessionFile(filePath, lines) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, lines.join(''), 'utf8');
}

async function readLines(filePath) {
  const text = await fs.readFile(filePath, 'utf8');
  return text.split('\n').slice(0, -1);
}

async function fileHash(filePath) {
  return crypto.createHash('sha256')
    .update(await fs.readFile(filePath))
    .digest('hex');
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function makeClock() {
  let tick = 0;
  return () => new Date(Date.UTC(2026, 0, 2, 3, 4, tick++));
}

function cursorFor(paths, sourceName, overrides = {}) {
  const sourcePath = path.join(paths.codexRoot, 'sessions', sourceName);
  return {
    sessionId: path.basename(sourceName, '.jsonl'),
    sourcePath,
    backupPath: path.join('sessions', sourceName),
    lastByteOffset: 10,
    lastSourceSize: 10,
    lastSourceModifiedAt: 1770000000.25,
    lineCount: 1,
    pendingPartialLine: '',
    status: 'active',
    lastError: null,
    updatedAt: 1770000001.5,
    ...overrides,
  };
}

function spyOnDatabaseExport(store) {
  const originalExport = store.db.export.bind(store.db);
  let calls = 0;
  store.db.export = (...args) => {
    calls += 1;
    return originalExport(...args);
  };
  return {
    get calls() {
      return calls;
    },
  };
}

test('initial scan backs up existing jsonl and records manifest title and line count', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'alpha.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'First prompt' }),
    jsonLine({ role: 'assistant', content: 'Answer' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.version, 2);
  assert.equal(manifest.codexRoot, paths.codexRoot);
  assert.equal(manifest.backupRoot, paths.backupRoot);
  assert.equal(Object.keys(manifest.sessions).length, 1);

  const record = manifest.sessions.alpha;
  assert.equal(record.sessionId, 'alpha');
  assert.equal(record.sourcePath, sourcePath);
  assert.equal(record.title, 'First prompt');
  assert.equal(record.lineCount, 2);
  assert.equal(record.status, 'active');
  assert.equal(record.backupPath, path.join('sessions', 'alpha.jsonl'));
  assert.deepEqual(await readLines(path.join(paths.backupRoot, record.backupPath)), [
    JSON.stringify({ role: 'user', content: 'First prompt' }),
    JSON.stringify({ role: 'assistant', content: 'Answer' }),
  ]);
});

test('second scan appends only new completed lines and repeated scan has no duplicate', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'append.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'Start' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();
  await fs.appendFile(sourcePath, jsonLine({ role: 'assistant', content: 'New answer' }), 'utf8');
  await agent.performOneShotScan();
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const backupPath = path.join(paths.backupRoot, manifest.sessions.append.backupPath);
  assert.deepEqual(await readLines(backupPath), [
    JSON.stringify({ role: 'user', content: 'Start' }),
    JSON.stringify({ role: 'assistant', content: 'New answer' }),
  ]);
  assert.equal(manifest.sessions.append.lineCount, 2);
});

test('steady-state scan reads new source bytes from the committed cursor', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'cursor-offset.jsonl');
  const first = jsonLine({ role: 'user', content: 'one' });
  const second = jsonLine({ role: 'assistant', content: 'two' });
  await writeSessionFile(sourcePath, [first]);
  const offsets = [];
  const agent = new BackupAgent({
    paths,
    tailer: (filePath, offset) => {
      offsets.push(offset);
      return readNewCompleteLines(filePath, offset);
    },
  });

  await agent.performOneShotScan();
  await fs.appendFile(sourcePath, second);
  await agent.performOneShotScan();

  assert.deepEqual(offsets, [0, Buffer.byteLength(first)]);
  assert.equal(await fs.readFile(paths.backupFilePath(sourcePath), 'utf8'), first + second);
});

test('first scan reconciles existing backup file without duplicate append', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'retry.jsonl');
  const firstLine = JSON.stringify({ role: 'user', content: 'Already copied' });
  const secondLine = JSON.stringify({ role: 'assistant', content: 'Copied after retry' });
  await writeSessionFile(sourcePath, [`${firstLine}\n`, `${secondLine}\n`]);

  const firstScanAt = new Date(Date.UTC(2026, 0, 2, 3, 4, 0));
  const backupPath = paths.backupFilePath(sourcePath);
  await fs.mkdir(path.dirname(backupPath), { recursive: true });
  await fs.writeFile(backupPath, `${firstLine}\n`, 'utf8');

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.deepEqual(await readLines(backupPath), [firstLine, secondLine]);
  assert.equal(manifest.sessions.retry.lineCount, 2);
  assert.equal(manifest.sessions.retry.bytesBackedUp, Buffer.byteLength(`${firstLine}\n${secondLine}\n`));

  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const cursor = await store.get(sourcePath);
  assert.equal(cursor.lineCount, 2);
  assert.equal(cursor.lastByteOffset, Buffer.byteLength(`${firstLine}\n${secondLine}\n`));
});

test('missing manifest recovers backup path from existing cursor on a later day', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'cursor-retry.jsonl');
  const line = JSON.stringify({ role: 'user', content: 'Cursor survived' });
  await writeSessionFile(sourcePath, [`${line}\n`]);

  const firstAgent = new BackupAgent({
    paths,
    now: () => new Date(Date.UTC(2026, 0, 2, 3, 4, 0)),
  });
  await firstAgent.performOneShotScan();

  const firstManifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const originalBackupPath = firstManifest.sessions['cursor-retry'].backupPath;
  const originalBackupFilePath = path.join(paths.backupRoot, originalBackupPath);
  await fs.rm(paths.manifestPath, { force: true });

  const retryAgent = new BackupAgent({
    paths,
    now: () => new Date(Date.UTC(2026, 0, 3, 3, 4, 0)),
  });
  await retryAgent.performOneShotScan();

  const retryManifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const retryRecord = retryManifest.sessions['cursor-retry'];
  assert.equal(retryRecord.backupPath, originalBackupPath);
  assert.deepEqual(await readLines(originalBackupFilePath), [line]);
  assert.equal(await fileExists(paths.backupFilePath('cursor-retry', new Date(Date.UTC(2026, 0, 3, 3, 4, 0)))), false);

  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const cursor = await store.get(sourcePath);
  assert.equal(cursor.backupPath, originalBackupPath);
});

test('inaccessible existing backup fails closed without advancing metadata', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'write-only-backup.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'Start' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  let manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const backupPath = path.join(paths.backupRoot, manifest.sessions['write-only-backup'].backupPath);
  await fs.chmod(backupPath, 0o200);
  t.after(async () => {
    await fs.chmod(backupPath, 0o600).catch(() => {});
  });

  const before = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8')).sessions['write-only-backup'];
  await fs.appendFile(sourcePath, jsonLine({ role: 'assistant', content: 'New answer' }), 'utf8');
  await assert.rejects(agent.performOneShotScan());
  await fs.chmod(backupPath, 0o600);

  manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.deepEqual(manifest.sessions['write-only-backup'], before);
});

test('no-op scan does not rewrite the cursor database', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'noop.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'Stable' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const beforeHash = await fileHash(paths.cursorDatabasePath);
  const originalWriteFile = fs.writeFile;
  let cursorDatabaseWriteCount = 0;
  fs.writeFile = async (filePath, ...args) => {
    if (String(filePath).startsWith(`${paths.cursorDatabasePath}.tmp-`)) {
      cursorDatabaseWriteCount += 1;
    }

    return originalWriteFile.call(fs, filePath, ...args);
  };

  try {
    await agent.performOneShotScan();
  } finally {
    fs.writeFile = originalWriteFile;
  }

  const afterHash = await fileHash(paths.cursorDatabasePath);

  assert.equal(cursorDatabaseWriteCount, 0);
  assert.equal(afterHash, beforeHash);
});

test('scan batches many changed cursors into one database export', async (t) => {
  const { paths } = await makeTestPaths(t);
  const seedStore = new CursorStore({ paths });
  await seedStore.open();
  await seedStore.close();
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'batch-one.jsonl'), [
    jsonLine({ role: 'user', content: 'One' }),
  ]);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'batch-two.jsonl'), [
    jsonLine({ role: 'user', content: 'Two' }),
  ]);

  const originalOpen = CursorStore.prototype.open;
  const originalAll = CursorStore.prototype.all;
  const originalUpsertMany = CursorStore.prototype.upsertMany;
  let allCalls = 0;
  let upsertManyCalls = 0;
  let exportCalls = 0;
  CursorStore.prototype.open = async function (...args) {
    const result = await originalOpen.apply(this, args);
    const originalExport = this.db.export.bind(this.db);
    this.db.export = (...exportArgs) => {
      exportCalls += 1;
      return originalExport(...exportArgs);
    };
    return result;
  };
  CursorStore.prototype.all = function (...args) {
    allCalls += 1;
    return originalAll.apply(this, args);
  };
  CursorStore.prototype.upsertMany = async function (...args) {
    upsertManyCalls += 1;
    return originalUpsertMany.apply(this, args);
  };

  try {
    await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  } finally {
    CursorStore.prototype.open = originalOpen;
    if (originalAll) CursorStore.prototype.all = originalAll;
    else delete CursorStore.prototype.all;
    if (originalUpsertMany) CursorStore.prototype.upsertMany = originalUpsertMany;
    else delete CursorStore.prototype.upsertMany;
  }

  assert.equal(allCalls, 1);
  assert.equal(upsertManyCalls, 1);
  assert.equal(exportCalls, 1);
});

test('partial trailing line is not backed up until completed', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'partial.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'Complete' }),
    JSON.stringify({ role: 'assistant', content: 'Still pending' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  let manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  let backupPath = path.join(paths.backupRoot, manifest.sessions.partial.backupPath);
  assert.deepEqual(await readLines(backupPath), [
    JSON.stringify({ role: 'user', content: 'Complete' }),
  ]);
  assert.equal(manifest.sessions.partial.lineCount, 1);

  await fs.appendFile(sourcePath, '\n', 'utf8');
  await agent.performOneShotScan();

  manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  backupPath = path.join(paths.backupRoot, manifest.sessions.partial.backupPath);
  assert.deepEqual(await readLines(backupPath), [
    JSON.stringify({ role: 'user', content: 'Complete' }),
    JSON.stringify({ role: 'assistant', content: 'Still pending' }),
  ]);
  assert.equal(manifest.sessions.partial.lineCount, 2);
});

test('archived sessions are scanned', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'archived_sessions', '2026', 'archived.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'Archived prompt' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions.archived.sourcePath, sourcePath);
  assert.deepEqual(
    await readLines(path.join(paths.backupRoot, manifest.sessions.archived.backupPath)),
    [JSON.stringify({ role: 'user', content: 'Archived prompt' })],
  );
});

test('moving a session from sessions to archived does not duplicate backup', async (t) => {
  const { paths } = await makeTestPaths(t);
  const activePath = path.join(paths.codexRoot, 'sessions', 'moved.jsonl');
  const archivedPath = path.join(paths.codexRoot, 'archived_sessions', 'moved.jsonl');
  await writeSessionFile(activePath, [
    jsonLine({ role: 'user', content: 'Original' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  await fs.mkdir(path.dirname(archivedPath), { recursive: true });
  await fs.rename(activePath, archivedPath);
  await agent.performOneShotScan();
  await fs.appendFile(archivedPath, jsonLine({ role: 'assistant', content: 'After archive' }), 'utf8');
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions.moved;
  assert.equal(record.sourcePath, archivedPath);
  assert.deepEqual(await readLines(path.join(paths.backupRoot, record.backupPath)), [
    JSON.stringify({ role: 'user', content: 'Original' }),
    JSON.stringify({ role: 'assistant', content: 'After archive' }),
  ]);
  assert.equal(record.lineCount, 2);
});

test('active sessions are preferred over archived sessions with the same id', async (t) => {
  const { paths } = await makeTestPaths(t);
  const activePath = path.join(paths.codexRoot, 'sessions', 'dupe.jsonl');
  const archivedPath = path.join(paths.codexRoot, 'archived_sessions', 'nested', 'dupe.jsonl');
  await writeSessionFile(activePath, [
    jsonLine({ role: 'user', content: 'Active wins' }),
  ]);
  await writeSessionFile(archivedPath, [
    jsonLine({ role: 'user', content: 'Archived loses' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions.dupe;
  assert.equal(record.sourcePath, activePath);
  assert.deepEqual(await readLines(path.join(paths.backupRoot, record.backupPath)), [
    JSON.stringify({ role: 'user', content: 'Active wins' }),
  ]);
});

test('status JSON is written with aggregate counts', async (t) => {
  const { paths } = await makeTestPaths(t);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'one.jsonl'), [
    jsonLine({ role: 'user', content: 'One' }),
  ]);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'two.jsonl'), [
    jsonLine({ role: 'user', content: 'Two' }),
    jsonLine({ role: 'assistant', content: 'Two answer' }),
  ]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const status = JSON.parse(await fs.readFile(paths.statusPath, 'utf8'));
  assert.equal(status.agentVersion, '2.0.0');
  assert.equal(status.enabled, true);
  assert.equal(status.status, 'running');
  assert.equal(status.mode, 'polling');
  assert.equal(status.codexRoot, paths.codexRoot);
  assert.equal(status.backupRoot, paths.backupRoot);
  assert.equal(status.sessionCount, 2);
  assert.equal(status.lineCount, 3);
  assert.equal(status.autoStartEnabled, false);
  assert.equal(status.lastError, null);
  assert.equal(typeof status.bytesBackedUp, 'number');
  assert.ok(status.bytesBackedUp > 0);
  assert.ok(status.firstRunAt);
  assert.ok(status.lastStartedAt);
  assert.ok(status.lastHeartbeatAt);
  assert.ok(status.lastBackupAt);
});

test('oversized line within limit backs up and does not block following lines', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sessionId = 'oversized-ok';
  const sourcePath = path.join(paths.codexRoot, 'sessions', `${sessionId}.jsonl`);
  const longText = 'x'.repeat(1024 * 1024 + 10);
  const longLine = JSON.stringify({ role: 'user', content: longText });
  const nextLine = JSON.stringify({ role: 'assistant', content: 'after' });
  await writeSessionFile(sourcePath, [`${longLine}\n`, `${nextLine}\n`]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions[sessionId];
  const backupPath = path.join(paths.backupRoot, record.backupPath);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const cursor = await store.get(record.sourcePath);
  const status = JSON.parse(await fs.readFile(paths.statusPath, 'utf8'));

  assert.deepEqual(await readLines(backupPath), [longLine, nextLine]);
  assert.equal(record.lineCount, 2);
  assert.equal(cursor.lastByteOffset, Buffer.byteLength(`${longLine}\n${nextLine}\n`));
  assert.equal(cursor.lastError, null);
  assert.equal(status.lastError, null);
});

test('oversized line beyond limit sets error status and continues other sessions', async (t) => {
  const { paths } = await makeTestPaths(t);
  const blockedId = 'oversized-blocked';
  const healthyId = 'healthy';
  const blockedPath = path.join(paths.codexRoot, 'sessions', `${blockedId}.jsonl`);
  const healthyPath = path.join(paths.codexRoot, 'sessions', `${healthyId}.jsonl`);
  await writeSessionFile(blockedPath, ['x'.repeat(32 * 1024 * 1024 + 1)]);
  await writeSessionFile(healthyPath, [jsonLine({ role: 'user', content: 'healthy' })]);

  const agent = new BackupAgent({ paths, now: makeClock() });
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const blockedRecord = manifest.sessions[blockedId];
  const healthyRecord = manifest.sessions[healthyId];
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const blockedCursor = await store.get(blockedRecord.sourcePath);
  const status = JSON.parse(await fs.readFile(paths.statusPath, 'utf8'));

  assert.equal(blockedRecord.lineCount, 0);
  assert.equal(blockedRecord.bytesBackedUp, 0);
  assert.equal(blockedCursor.lastByteOffset, 0);
  assert.match(blockedCursor.lastError, /exceeds maximum JSONL line size/);
  assert.deepEqual(await readLines(path.join(paths.backupRoot, healthyRecord.backupPath)), [
    JSON.stringify({ role: 'user', content: 'healthy' }),
  ]);
  assert.equal(status.status, 'error');
  assert.match(status.lastError, /exceeds maximum JSONL line size/);
});

test('invalid relative backup path throws a clear error', async (t) => {
  const { paths, root } = await makeTestPaths(t);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'escape.jsonl'), [
    jsonLine({ role: 'user', content: 'Escape' }),
  ]);
  paths.backupFilePath = () => path.join(root, 'outside.jsonl');

  const agent = new BackupAgent({ paths, now: makeClock() });
  await assert.rejects(
    () => agent.performOneShotScan(),
    /Backup path is outside backup root:/,
  );
});

test('missing NAS backup root is not recreated and writes local error status only', async (t) => {
  const { paths } = await makeTestPaths(t);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'missing-root.jsonl'), [
    jsonLine({ role: 'user', content: 'pending' }),
  ]);
  await fs.rm(paths.backupRoot, { recursive: true });

  await assert.rejects(new BackupAgent({ paths }).performOneShotScan(), /unavailable|missing/i);

  assert.equal(await fileExists(paths.backupRoot), false);
  assert.equal(JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8')).status, 'error');
  assert.equal(await fileExists(paths.remoteStatusPath), false);
});

test('target validator runs before remote side effects', async (t) => {
  const { paths } = await makeTestPaths(t);
  let validationCount = 0;
  const agent = new BackupAgent({
    paths,
    validateTarget: async () => {
      validationCount += 1;
      throw new Error('untrusted target');
    },
  });

  await assert.rejects(agent.performOneShotScan(), /untrusted target/);

  assert.equal(validationCount, 1);
  assert.equal(await fileExists(paths.manifestPath), false);
  assert.equal(await fileExists(paths.sessionsRoot), false);
});

test('failed data sync does not advance cursor or manifest', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'sync-failure.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'one' })]);
  const agent = new BackupAgent({
    paths,
    fileCommitter: createFileCommitter({ sync: async () => { throw new Error('injected sync failure'); } }),
  });

  await assert.rejects(agent.performOneShotScan(), /injected sync failure/);

  assert.equal(await fileExists(paths.manifestPath), false);
  const store = new CursorStore({ paths });
  await store.open();
  assert.equal(await store.get(sourcePath), null);
  await store.close();
  assert.equal(await fileExists(paths.backupFilePath(sourcePath)), false);
});

test('matching interrupted append is adopted without duplication', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'interrupted.jsonl');
  const one = jsonLine({ role: 'user', content: 'one' });
  const two = jsonLine({ role: 'assistant', content: 'two' });
  await writeSessionFile(sourcePath, [one]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  const target = paths.backupFilePath(sourcePath);
  await fs.appendFile(sourcePath, two);
  await fs.appendFile(target, two);

  await agent.performOneShotScan();

  assert.equal(await fs.readFile(target, 'utf8'), one + two);
  assert.equal(JSON.parse(await fs.readFile(paths.manifestPath, 'utf8')).sessions.interrupted.lineCount, 2);
});

test('mismatched interrupted append and same-size rewrite rebuild exact source', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'rewrite.jsonl');
  const original = jsonLine({ role: 'user', content: 'AAAA' });
  await writeSessionFile(sourcePath, [original]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  const target = paths.backupFilePath(sourcePath);
  await fs.appendFile(target, jsonLine({ role: 'assistant', content: 'evil' }));
  const rewritten = jsonLine({ role: 'user', content: 'BBBB' });
  await fs.writeFile(sourcePath, rewritten);

  await agent.performOneShotScan();

  assert.equal(await fs.readFile(target, 'utf8'), rewritten);
  assert.ok(JSON.parse(await fs.readFile(paths.manifestPath, 'utf8')).sessions.rewrite.contentHash);
});

test('pendingSessionCount stores metadata only in local state', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'pending.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'one' })]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  await fs.appendFile(sourcePath, jsonLine({ role: 'assistant', content: 'two' }));

  assert.equal(await agent.pendingSessionCount(), 1);
  const pendingText = await fs.readFile(paths.pendingSourcesPath, 'utf8');
  assert.equal(pendingText.includes('"content"'), false);
  assert.equal(pendingText.includes(sourcePath), true);
});

test('cursor store preserves tricky values and pending partial line', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });

  const pendingPartialLine = `half\\0line ${String.fromCodePoint(0x1f680)}`;
  const sourcePath = path.join(paths.codexRoot, "sessions", "quote's.jsonl");
  const cursor = {
    sessionId: 'quote-session',
    sourcePath,
    backupPath: path.join('sessions', 'quote.jsonl'),
    lastByteOffset: 42,
    lastSourceSize: 99,
    lastSourceModifiedAt: 1770000000.25,
    lineCount: 7,
    pendingPartialLine,
    status: 'active',
    lastError: "boom'); DROP TABLE backup_cursors; --",
    updatedAt: 1770000001.5,
  };

  await store.upsert(cursor);
  assert.deepEqual(await store.get(sourcePath), cursor);
});

test('cursor store materializes all cursors and exports a changed batch once', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const one = cursorFor(paths, 'batch-one.jsonl');
  const two = cursorFor(paths, 'batch-two.jsonl', {
    lastByteOffset: 20,
    lastSourceSize: 20,
    lineCount: 2,
    pendingPartialLine: 'partial',
  });
  const exportSpy = spyOnDatabaseExport(store);

  await store.upsertMany([one, two]);

  const cursors = store.all();
  assert.equal(exportSpy.calls, 1);
  assert.ok(cursors instanceof Map);
  assert.equal(cursors.size, 2);
  assert.deepEqual(cursors.get(one.sourcePath), one);
  assert.deepEqual(cursors.get(two.sourcePath), two);
});

test('empty cursor batch does not export the database', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const exportSpy = spyOnDatabaseExport(store);

  await store.upsertMany([]);

  assert.equal(exportSpy.calls, 0);
  assert.equal(store.all().size, 0);
});

test('SQL failure rolls back the cursor batch without a durable replacement', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const durableHash = await fileHash(paths.cursorDatabasePath);
  store.db.run(`
    CREATE TRIGGER reject_bad_cursor
    BEFORE INSERT ON backup_cursors
    WHEN NEW.source_path LIKE '%bad.jsonl'
    BEGIN
      SELECT RAISE(ABORT, 'injected SQL failure');
    END;
  `);
  const exportSpy = spyOnDatabaseExport(store);

  await assert.rejects(
    store.upsertMany([
      cursorFor(paths, 'good.jsonl'),
      cursorFor(paths, 'bad.jsonl'),
    ]),
    /injected SQL failure/,
  );

  assert.equal(exportSpy.calls, 0);
  assert.equal(store.all().size, 0);
  assert.equal(await fileHash(paths.cursorDatabasePath), durableHash);
});

test('durable cursor replacement failure leaves the previous database readable', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  const original = cursorFor(paths, 'durable.jsonl');
  await store.upsert(original);
  const exportSpy = spyOnDatabaseExport(store);
  const originalRename = fs.rename;
  fs.rename = async () => {
    throw new Error('injected durable replacement failure');
  };

  try {
    await assert.rejects(
      store.upsertMany([cursorFor(paths, 'durable.jsonl', { lastByteOffset: 99 })]),
      /injected durable replacement failure/,
    );
  } finally {
    fs.rename = originalRename;
    await store.close();
  }

  const reopened = new CursorStore({ paths });
  await reopened.open();
  t.after(async () => {
    await reopened.close();
  });
  assert.equal(exportSpy.calls, 1);
  assert.deepEqual(await reopened.get(original.sourcePath), original);
});

test('session tailer reads across chunks until complete lines are exhausted', async (t) => {
  const { root } = await makeTestPaths(t);
  const filePath = path.join(root, 'tailer-bounded.jsonl');
  await fs.writeFile(filePath, 'one\ntwo\nthree\n', 'utf8');

  assert.deepEqual(readNewCompleteLines(filePath, 0, 4), {
    lines: ['one', 'two', 'three'],
    nextOffset: Buffer.byteLength('one\ntwo\nthree\n'),
    pendingPartialLine: '',
    blockedError: null,
  });
});

test('session tailer continues reading when newline is beyond one chunk', async (t) => {
  const { root } = await makeTestPaths(t);
  const filePath = path.join(root, 'tailer.jsonl');
  const longLine = 'a'.repeat(8);
  await fs.writeFile(filePath, `${longLine}\n\npending`, 'utf8');

  assert.deepEqual(readNewCompleteLines(filePath, 0, 4), {
    lines: [longLine, ''],
    nextOffset: Buffer.byteLength(`${longLine}\n\n`),
    pendingPartialLine: 'pending',
    blockedError: null,
  });
});

test('session tailer reports blocked error when line exceeds maximum line bytes', async (t) => {
  const { root } = await makeTestPaths(t);
  const filePath = path.join(root, 'tailer-blocked.jsonl');
  await fs.writeFile(filePath, '123456789\nnext\n', 'utf8');

  const result = readNewCompleteLines(filePath, 0, 4, 8);

  assert.deepEqual(result.lines, []);
  assert.equal(result.nextOffset, 0);
  assert.equal(result.pendingPartialLine, '');
  assert.match(result.blockedError, /exceeds maximum JSONL line size/);
});

test('session tailer keeps data available when an oversized partial line is later completed', async (t) => {
  const { root } = await makeTestPaths(t);
  const filePath = path.join(root, 'tailer-completed-later.jsonl');
  const longLine = 'b'.repeat(8);
  await fs.writeFile(filePath, longLine, 'utf8');

  assert.deepEqual(readNewCompleteLines(filePath, 0, 4), {
    lines: [],
    nextOffset: 0,
    pendingPartialLine: longLine,
    blockedError: null,
  });

  await fs.appendFile(filePath, '\nnext\n', 'utf8');

  assert.deepEqual(readNewCompleteLines(filePath, 0, 64), {
    lines: [longLine, 'next'],
    nextOffset: Buffer.byteLength(`${longLine}\nnext\n`),
    pendingPartialLine: '',
    blockedError: null,
  });
});

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { BackupAgent, createFileCommitter } = require('../../src/backup/backup-agent');
const { CursorStore } = require('../../src/backup/cursor-store');
const { BackupIntegrityAuditor } = require('../../src/backup/integrity-auditor');
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

async function withoutJsonlReadFile(operation) {
  const originalReadFile = fs.readFile;
  fs.readFile = async (filePath, ...args) => {
    if (String(filePath).endsWith('.jsonl')) {
      throw new Error(`whole-file JSONL read attempted: ${filePath}`);
    }
    return originalReadFile.call(fs, filePath, ...args);
  };
  try {
    return await operation();
  } finally {
    fs.readFile = originalReadFile;
  }
}

async function withTrackedReadRanges(filePaths, operation) {
  const originalOpen = fs.open;
  const tracked = new Map(filePaths.map((filePath) => [path.resolve(filePath), []]));
  fs.open = async (filePath, ...args) => {
    const handle = await originalOpen.call(fs, filePath, ...args);
    const ranges = tracked.get(path.resolve(String(filePath)));
    if (ranges) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (buffer, offset, length, position) => {
        const result = await originalRead(buffer, offset, length, position);
        if (result.bytesRead > 0) {
          ranges.push({ start: position, end: position + result.bytesRead, requested: length });
        }
        return result;
      };
    }
    return handle;
  };
  try {
    await operation();
  } finally {
    fs.open = originalOpen;
  }
  return new Map(filePaths.map((filePath) => [filePath, tracked.get(path.resolve(filePath))]));
}

async function loadCursor(paths, sourcePath) {
  const store = new CursorStore({ paths });
  await store.open();
  try {
    return await store.get(sourcePath);
  } finally {
    await store.close();
  }
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

function spyOnAllCursorStoreExports() {
  const originalFlush = CursorStore.prototype.flush;
  let calls = 0;
  CursorStore.prototype.flush = async function (...args) {
    const database = this.db;
    const originalExport = database.export;
    database.export = (...exportArgs) => {
      calls += 1;
      return originalExport.apply(database, exportArgs);
    };
    try {
      return await originalFlush.apply(this, args);
    } finally {
      database.export = originalExport;
    }
  };
  return {
    get calls() {
      return calls;
    },
    restore() {
      CursorStore.prototype.flush = originalFlush;
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

test('steady-state scan reads new source bytes with the real bounded streamer', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'cursor-offset.jsonl');
  const first = jsonLine({ role: 'user', content: 'one' });
  const second = jsonLine({ role: 'assistant', content: 'two' });
  await writeSessionFile(sourcePath, [first]);
  const agent = new BackupAgent({ paths });

  const initialRanges = await withTrackedReadRanges(
    [sourcePath],
    () => agent.performOneShotScan(),
  );
  await fs.appendFile(sourcePath, second);
  const appendedRanges = await withTrackedReadRanges(
    [sourcePath],
    () => agent.performOneShotScan(),
  );

  const oldOffset = Buffer.byteLength(first);
  const newOffset = oldOffset + Buffer.byteLength(second);
  assert.equal(initialRanges.get(sourcePath)[0].start, 0);
  assert.ok(appendedRanges.get(sourcePath).every(({ start, end }) => (
    start >= oldOffset && end <= newOffset
  )));
  assert.equal(await fs.readFile(paths.backupFilePath(sourcePath), 'utf8'), first + second);
});

test('backup agent does not execute the discarded legacy tailer side channel', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'no-tailer-side-channel.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'bounded' })]);
  let tailerCalls = 0;
  const agent = new BackupAgent({
    paths,
    tailer: () => {
      tailerCalls += 1;
      return { lines: [] };
    },
  });

  await agent.performOneShotScan();

  assert.equal(tailerCalls, 0);
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

test('fresh scan with no changed cursors performs zero total database exports', async (t) => {
  const { paths } = await makeTestPaths(t);
  const exportSpy = spyOnAllCursorStoreExports();

  try {
    await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  } finally {
    exportSpy.restore();
  }

  assert.equal(exportSpy.calls, 0);
  assert.equal(await fileExists(paths.cursorDatabasePath), false);
});

test('fresh scan batches many changed cursors into one total database export', async (t) => {
  const { paths } = await makeTestPaths(t);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'batch-one.jsonl'), [
    jsonLine({ role: 'user', content: 'One' }),
  ]);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'batch-two.jsonl'), [
    jsonLine({ role: 'user', content: 'Two' }),
  ]);

  const originalAll = CursorStore.prototype.all;
  const originalUpsertMany = CursorStore.prototype.upsertMany;
  const exportSpy = spyOnAllCursorStoreExports();
  let allCalls = 0;
  let upsertManyCalls = 0;
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
    exportSpy.restore();
    if (originalAll) CursorStore.prototype.all = originalAll;
    else delete CursorStore.prototype.all;
    if (originalUpsertMany) CursorStore.prototype.upsertMany = originalUpsertMany;
    else delete CursorStore.prototype.upsertMany;
  }

  assert.equal(allCalls, 1);
  assert.equal(upsertManyCalls, 1);
  assert.equal(exportSpy.calls, 1);
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

test('adopting an ahead user record recovers and preserves the first title', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'interrupted-title.jsonl');
  const assistant = jsonLine({ role: 'assistant', content: 'assistant only' });
  const firstUser = jsonLine({ role: 'user', content: 'Recovered first prompt' });
  const laterUser = jsonLine({ role: 'user', content: 'Later prompt' });
  await writeSessionFile(sourcePath, [assistant]);
  const agent = new BackupAgent({ paths, now: makeClock() });

  await agent.performOneShotScan();
  let manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions['interrupted-title'].title, null);

  const targetPath = paths.backupFilePath(sourcePath);
  await fs.appendFile(sourcePath, firstUser);
  await fs.appendFile(targetPath, firstUser);
  await agent.performOneShotScan();

  manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions['interrupted-title'].title, 'Recovered first prompt');
  assert.equal(manifest.sessions['interrupted-title'].lineCount, 2);

  await agent.performOneShotScan();
  manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions['interrupted-title'].title, 'Recovered first prompt');

  await fs.appendFile(sourcePath, laterUser);
  await agent.performOneShotScan();
  manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions['interrupted-title'].title, 'Recovered first prompt');
  assert.equal(await fs.readFile(targetPath, 'utf8'), assistant + firstUser + laterUser);
});

test('retry syncs an adopted ahead target before advancing metadata', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'sync-ahead-retry.jsonl');
  const first = jsonLine({ role: 'user', content: 'first' });
  const second = jsonLine({ role: 'assistant', content: 'second' });
  await writeSessionFile(sourcePath, [first]);
  await new BackupAgent({ paths }).performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  const baselineRecord = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'))
    .sessions['sync-ahead-retry'];
  const baselineCursor = await loadCursor(paths, sourcePath);
  await fs.appendFile(sourcePath, second);

  let syncCalls = 0;
  const retryAgent = new BackupAgent({
    paths,
    fileCommitter: createFileCommitter({
      sync: async (handle) => {
        syncCalls += 1;
        if (syncCalls <= 2) throw new Error(`injected sync failure ${syncCalls}`);
        await handle.sync();
      },
    }),
  });

  await assert.rejects(retryAgent.performOneShotScan(), /injected sync failure 1/);
  assert.equal(syncCalls, 1);
  assert.equal(await fs.readFile(targetPath, 'utf8'), first + second);
  assert.deepEqual(
    JSON.parse(await fs.readFile(paths.manifestPath, 'utf8')).sessions['sync-ahead-retry'],
    baselineRecord,
  );
  assert.deepEqual(await loadCursor(paths, sourcePath), baselineCursor);

  await assert.rejects(retryAgent.performOneShotScan(), /injected sync failure 2/);
  assert.equal(syncCalls, 2);
  assert.equal(await fs.readFile(targetPath, 'utf8'), first + second);
  assert.deepEqual(
    JSON.parse(await fs.readFile(paths.manifestPath, 'utf8')).sessions['sync-ahead-retry'],
    baselineRecord,
  );
  assert.deepEqual(await loadCursor(paths, sourcePath), baselineCursor);

  await retryAgent.performOneShotScan();
  assert.equal(syncCalls, 3);
  assert.equal(await fs.readFile(targetPath, 'utf8'), first + second);
  const updatedRecord = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'))
    .sessions['sync-ahead-retry'];
  const updatedCursor = await loadCursor(paths, sourcePath);
  assert.equal(updatedRecord.lineCount, 2);
  assert.equal(updatedRecord.bytesBackedUp, Buffer.byteLength(first + second));
  assert.equal(updatedRecord.contentHash, null);
  assert.equal(updatedCursor.lastByteOffset, Buffer.byteLength(first + second));

  await retryAgent.performOneShotScan();
  assert.equal(syncCalls, 3);
  assert.equal(await fs.readFile(targetPath, 'utf8'), first + second);
});

test('fresh large scan never uses whole-file JSONL reads for rebuild or stats', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'large-streamed.jsonl');
  const longLine = jsonLine({ role: 'user', content: 'x'.repeat(3 * 1024 * 1024 + 17) });
  await writeSessionFile(sourcePath, [longLine, 'partial']);

  await withoutJsonlReadFile(() => new BackupAgent({ paths }).performOneShotScan());

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions['large-streamed'];
  assert.equal(record.lineCount, 1);
  assert.equal((await fs.stat(path.join(paths.backupRoot, record.backupPath))).size, Buffer.byteLength(longLine));
});

test('fresh cursor reconciliation compares an existing target prefix without whole-file reads', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'prefix-streamed.jsonl');
  const first = jsonLine({ role: 'user', content: 'already committed' });
  const second = jsonLine({ role: 'assistant', content: 'new record' });
  await writeSessionFile(sourcePath, [first, second]);
  const targetPath = paths.backupFilePath(sourcePath);
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, first);

  await withoutJsonlReadFile(() => new BackupAgent({ paths }).performOneShotScan());

  assert.equal(await fs.readFile(targetPath, 'utf8'), first + second);
});

test('initial matching target reconciliation derives title, line count, and full hash in one bounded pass', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'existing-seed-hash.jsonl');
  const assistant = jsonLine({ role: 'assistant', content: 'x'.repeat(3 * 1024 * 1024 + 17) });
  const user = jsonLine({ role: 'user', content: 'title beyond the first chunk' });
  const contents = assistant + user;
  await writeSessionFile(sourcePath, [contents]);
  const targetPath = paths.backupFilePath(sourcePath);
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, contents);

  const ranges = await withTrackedReadRanges(
    [sourcePath, targetPath],
    () => withoutJsonlReadFile(() => new BackupAgent({ paths }).performOneShotScan()),
  );

  const record = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'))
    .sessions['existing-seed-hash'];
  assert.equal(record.title, 'title beyond the first chunk');
  assert.equal(record.lineCount, 2);
  assert.equal(record.contentHash, crypto.createHash('sha256').update(contents).digest('hex'));
  assert.equal(
    ranges.get(sourcePath).reduce((total, range) => total + range.end - range.start, 0),
    Buffer.byteLength(contents),
  );
  assert.equal(
    ranges.get(targetPath).reduce((total, range) => total + range.end - range.start, 0),
    Buffer.byteLength(contents),
  );
  assert.ok([...ranges.values()].flat().every(({ requested }) => requested <= 1024 * 1024));
});

test('initial matching empty target reconciliation stores the canonical empty hash', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'existing-empty-seed.jsonl');
  await writeSessionFile(sourcePath, []);
  const targetPath = paths.backupFilePath(sourcePath);
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, '');

  await withoutJsonlReadFile(() => new BackupAgent({ paths }).performOneShotScan());

  const record = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'))
    .sessions['existing-empty-seed'];
  assert.equal(record.lineCount, 0);
  assert.equal(record.bytesBackedUp, 0);
  assert.equal(record.contentHash, crypto.createHash('sha256').update('').digest('hex'));
});

test('unchanged scan stops before target, body, hash, manifest, cursor, and export work', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'strict-no-change.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'stable' })]);
  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const targetPath = path.join(paths.backupRoot, manifest.sessions['strict-no-change'].backupPath);
  const exportSpy = spyOnAllCursorStoreExports();
  const originalStat = fs.stat;
  const originalLstat = fs.lstat;
  const originalOpen = fs.open;
  const originalReadFile = fs.readFile;
  const originalRename = fs.rename;
  let targetStatCount = 0;
  let bodyReadCount = 0;
  let manifestWriteCount = 0;
  let cursorWriteCount = 0;
  fs.stat = async (filePath, ...args) => {
    if (path.resolve(String(filePath)) === path.resolve(targetPath)) {
      targetStatCount += 1;
      throw new Error('unchanged scan touched target stat');
    }
    return originalStat.call(fs, filePath, ...args);
  };
  fs.lstat = async (filePath, ...args) => {
    if (path.resolve(String(filePath)) === path.resolve(targetPath)) {
      targetStatCount += 1;
      throw new Error('unchanged scan touched target lstat');
    }
    return originalLstat.call(fs, filePath, ...args);
  };
  fs.open = async (filePath, ...args) => {
    if ([sourcePath, targetPath].some((candidate) => path.resolve(String(filePath)) === path.resolve(candidate))) {
      bodyReadCount += 1;
      throw new Error('unchanged scan opened session body');
    }
    return originalOpen.call(fs, filePath, ...args);
  };
  fs.readFile = async (filePath, ...args) => {
    if ([sourcePath, targetPath].some((candidate) => path.resolve(String(filePath)) === path.resolve(candidate))) {
      bodyReadCount += 1;
      throw new Error('unchanged scan read session body');
    }
    return originalReadFile.call(fs, filePath, ...args);
  };
  fs.rename = async (from, to, ...args) => {
    if (path.resolve(String(to)) === path.resolve(paths.manifestPath)) manifestWriteCount += 1;
    if (path.resolve(String(to)) === path.resolve(paths.cursorDatabasePath)) cursorWriteCount += 1;
    return originalRename.call(fs, from, to, ...args);
  };

  try {
    await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  } finally {
    fs.stat = originalStat;
    fs.lstat = originalLstat;
    fs.open = originalOpen;
    fs.readFile = originalReadFile;
    fs.rename = originalRename;
    exportSpy.restore();
  }

  assert.equal(targetStatCount, 0);
  assert.equal(bodyReadCount, 0);
  assert.equal(manifestWriteCount, 0);
  assert.equal(cursorWriteCount, 0);
  assert.equal(exportSpy.calls, 0);
});

test('append reads only the new committed range and clears the optional full hash', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'range-append.jsonl');
  const first = jsonLine({ role: 'user', content: 'first' });
  const second = jsonLine({ role: 'assistant', content: 'second' });
  await writeSessionFile(sourcePath, [first]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  const oldOffset = Buffer.byteLength(first);
  await fs.appendFile(sourcePath, second);
  const newOffset = oldOffset + Buffer.byteLength(second);
  const originalOpen = fs.open;
  const readRanges = [];
  fs.open = async (filePath, ...args) => {
    const handle = await originalOpen.call(fs, filePath, ...args);
    if (path.resolve(String(filePath)) === path.resolve(sourcePath)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (buffer, offset, length, position) => {
        const result = await originalRead(buffer, offset, length, position);
        if (result.bytesRead > 0) {
          readRanges.push({ start: position, end: position + result.bytesRead, requested: length });
        }
        return result;
      };
    }
    return handle;
  };
  try {
    await withoutJsonlReadFile(() => agent.performOneShotScan());
  } finally {
    fs.open = originalOpen;
  }

  assert.ok(readRanges.length > 0);
  assert.ok(readRanges.every(({ start, end, requested }) => (
    start >= oldOffset && end <= newOffset && requested <= 1024 * 1024
  )));
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions['range-append'];
  assert.equal(record.bytesBackedUp, newOffset);
  assert.equal(record.contentHash, null);
});

test('untitled append never reopens the large target prefix for a title', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'append-title-range.jsonl');
  const prefix = jsonLine({ role: 'assistant', content: 'x'.repeat(3 * 1024 * 1024 + 17) });
  const appended = jsonLine({ role: 'assistant', content: 'still untitled' });
  await writeSessionFile(sourcePath, [prefix]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  const oldOffset = Buffer.byteLength(prefix);
  await fs.appendFile(sourcePath, appended);
  const newOffset = oldOffset + Buffer.byteLength(appended);

  const ranges = await withTrackedReadRanges(
    [sourcePath, targetPath],
    () => agent.performOneShotScan(),
  );

  assert.ok(ranges.get(sourcePath).length > 0);
  assert.ok(ranges.get(targetPath).length > 0);
  assert.ok([...ranges.values()].flat().every(({ start, end, requested }) => (
    start >= oldOffset && end <= newOffset && requested <= 1024 * 1024
  )));
  const record = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'))
    .sessions['append-title-range'];
  assert.equal(record.title, null);
});

test('empty seed and empty rebuild store the canonical full hash', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'empty-hash.jsonl');
  await writeSessionFile(sourcePath, []);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  const emptyHash = crypto.createHash('sha256').update('').digest('hex');
  let manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions['empty-hash'].contentHash, emptyHash);

  await fs.writeFile(sourcePath, jsonLine({ role: 'user', content: 'temporary' }));
  await fs.utimes(sourcePath, new Date(), new Date(Date.now() + 5_000));
  await agent.performOneShotScan();
  await fs.writeFile(sourcePath, '');
  await fs.utimes(sourcePath, new Date(), new Date(Date.now() + 10_000));
  await agent.performOneShotScan();

  manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions['empty-hash'];
  assert.equal(record.contentHash, emptyHash);
  assert.equal((await fs.stat(path.join(paths.backupRoot, record.backupPath))).size, 0);
});

test('same-size changed-mtime rewrite streams an exact rebuild without JSONL readFile', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'same-size-streamed.jsonl');
  const original = jsonLine({ role: 'user', content: 'AAAA' });
  const replacement = jsonLine({ role: 'user', content: 'BBBB' });
  await writeSessionFile(sourcePath, [original]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  await fs.writeFile(sourcePath, replacement);
  await fs.utimes(sourcePath, new Date(), new Date(Date.now() + 5_000));

  await withoutJsonlReadFile(() => agent.performOneShotScan());

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions['same-size-streamed'];
  assert.equal(await fs.readFile(path.join(paths.backupRoot, record.backupPath), 'utf8'), replacement);
  assert.equal(record.contentHash, crypto.createHash('sha256').update(replacement).digest('hex'));
});

test('truncation streams an exact rebuild without JSONL readFile', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'truncated-streamed.jsonl');
  const retained = jsonLine({ role: 'user', content: 'keep' });
  await writeSessionFile(sourcePath, [retained, jsonLine({ role: 'assistant', content: 'remove' })]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  await fs.writeFile(sourcePath, retained);
  await fs.utimes(sourcePath, new Date(), new Date(Date.now() + 5_000));

  await withoutJsonlReadFile(() => agent.performOneShotScan());

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions['truncated-streamed'];
  assert.equal(await fs.readFile(path.join(paths.backupRoot, record.backupPath), 'utf8'), retained);
  assert.equal(record.lineCount, 1);
  assert.equal(record.bytesBackedUp, Buffer.byteLength(retained));
});

test('missing target streams a rebuild without JSONL readFile', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'missing-streamed.jsonl');
  const contents = jsonLine({ role: 'user', content: 'restore target' });
  await writeSessionFile(sourcePath, [contents]);
  const agent = new BackupAgent({ paths });
  await agent.performOneShotScan();
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const targetPath = path.join(paths.backupRoot, manifest.sessions['missing-streamed'].backupPath);
  await fs.rm(targetPath);
  await fs.utimes(sourcePath, new Date(), new Date(Date.now() + 5_000));

  await withoutJsonlReadFile(() => agent.performOneShotScan());

  assert.equal(await fs.readFile(targetPath, 'utf8'), contents);
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
  assert.equal(await fileExists(paths.cursorDatabasePath), false);
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
  assert.equal(await fileExists(paths.cursorDatabasePath), false);
});

test('durable cursor replacement failure leaves the previous database readable', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const original = cursorFor(paths, 'durable.jsonl');
  await store.upsert(original);
  const exportSpy = spyOnAllCursorStoreExports();
  t.after(() => {
    exportSpy.restore();
  });
  const originalRename = fs.rename;
  const rejectedPath = cursorFor(paths, 'rejected.jsonl').sourcePath;
  fs.rename = async () => {
    throw new Error('injected durable replacement failure');
  };

  try {
    await assert.rejects(
      store.upsertMany([
        cursorFor(paths, 'durable.jsonl', { lastByteOffset: 99 }),
        cursorFor(paths, 'rejected.jsonl'),
      ]),
      /injected durable replacement failure/,
    );
  } finally {
    fs.rename = originalRename;
  }

  assert.equal(exportSpy.calls, 1);
  assert.equal(store.all().size, 1);
  assert.deepEqual(await store.get(original.sourcePath), original);
  assert.equal(await store.get(rejectedPath), null);

  const accepted = cursorFor(paths, 'durable.jsonl', { lastByteOffset: 77 });
  await store.upsertMany([accepted]);
  assert.equal(exportSpy.calls, 2);
  assert.deepEqual(await store.get(original.sourcePath), accepted);
  assert.equal(await store.get(rejectedPath), null);
  await store.close();

  const reopened = new CursorStore({ paths });
  await reopened.open();
  t.after(async () => {
    await reopened.close();
  });
  assert.equal(reopened.all().size, 1);
  assert.deepEqual(await reopened.get(original.sourcePath), accepted);
  assert.equal(await reopened.get(rejectedPath), null);
});

test('rollback failure restores the last durable database and permits reuse', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const original = cursorFor(paths, 'rollback.jsonl');
  await store.upsert(original);
  store.db.run(`
    CREATE TRIGGER reject_bad_cursor
    BEFORE INSERT ON backup_cursors
    WHEN NEW.source_path LIKE '%bad.jsonl'
    BEGIN
      SELECT RAISE(ABORT, 'injected SQL failure');
    END;
  `);
  const failedDatabase = store.db;
  const originalRun = failedDatabase.run;
  failedDatabase.run = function (sql, ...args) {
    if (sql === 'ROLLBACK;') {
      throw new Error('injected rollback failure');
    }
    return originalRun.call(failedDatabase, sql, ...args);
  };
  const exportSpy = spyOnAllCursorStoreExports();
  t.after(() => {
    exportSpy.restore();
  });
  const rejectedPath = cursorFor(paths, 'bad.jsonl').sourcePath;

  await assert.rejects(
    store.upsertMany([
      cursorFor(paths, 'good.jsonl'),
      cursorFor(paths, 'bad.jsonl'),
    ]),
    /injected SQL failure/,
  );

  assert.equal(exportSpy.calls, 0);
  assert.equal(store.all().size, 1);
  assert.deepEqual(await store.get(original.sourcePath), original);
  assert.equal(await store.get(rejectedPath), null);

  const accepted = cursorFor(paths, 'rollback.jsonl', { lastByteOffset: 55 });
  await store.upsertMany([accepted]);
  assert.equal(exportSpy.calls, 1);
  assert.deepEqual(await store.get(original.sourcePath), accepted);
  await store.close();

  const reopened = new CursorStore({ paths });
  await reopened.open();
  t.after(async () => {
    await reopened.close();
  });
  assert.equal(reopened.all().size, 1);
  assert.deepEqual(await reopened.get(original.sourcePath), accepted);
  assert.equal(await reopened.get(rejectedPath), null);
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

test('successful initial seed initializes audit state and prevents an immediate audit', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'initial-seed-audit.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'one' })]);
  const agent = new BackupAgent({ paths, now: () => now });

  await agent.performOneShotScan();

  const state = JSON.parse(await fs.readFile(paths.auditStatePath, 'utf8'));
  assert.equal(state.lastCompletedAt, now.toISOString());
  assert.equal(state.lastResult, 'seeded');
  assert.deepEqual(
    await agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001'),
    { outcome: 'not-due', checked: 0, repaired: 0 },
  );
  const status = JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8'));
  assert.equal(status.lastAuditAt, now.toISOString());
  assert.equal(status.lastAuditResult, 'seeded');
  assert.equal(status.repairCount, 0);
});

test('blocked initial seed does not initialize audit completion', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'blocked-audit-seed.jsonl');
  await writeSessionFile(sourcePath, ['x'.repeat(32 * 1024 * 1024 + 1)]);

  await new BackupAgent({ paths }).performOneShotScan();

  assert.equal(await fileExists(paths.auditStatePath), false);
  assert.equal(JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8')).status, 'error');
});

for (const publication of [
  ['remote status', (paths) => paths.remoteStatusPath],
  ['local status', (paths) => paths.localStatusPath],
  ['pending sources', (paths) => paths.pendingSourcesPath],
  ['audit state', (paths) => paths.auditStatePath],
]) {
  test(`failed initial ${publication[0]} publication does not record seed completion and retry seeds once`, async (t) => {
    const { paths } = await makeTestPaths(t);
    const sourcePath = path.join(paths.codexRoot, 'sessions', `failed-${publication[0].replace(' ', '-')}.jsonl`);
    await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: publication[0] })]);
    const failedAt = new Date('2026-07-14T04:05:06.000Z');
    const retryAt = new Date('2026-07-14T04:06:06.000Z');
    let currentDate = failedAt;
    const agent = new BackupAgent({ paths, now: () => currentDate });
    const failedPath = publication[1](paths);
    const originalRename = fs.rename;
    let injectFailure = true;
    fs.rename = async (source, destination, ...args) => {
      if (injectFailure && path.resolve(String(destination)) === path.resolve(failedPath)) {
        throw new Error(`injected ${publication[0]} publication failure`);
      }
      return originalRename.call(fs, source, destination, ...args);
    };

    try {
      await assert.rejects(
        agent.performOneShotScan(),
        new RegExp(`injected ${publication[0]} publication failure`),
      );
      assert.equal(await fileExists(paths.auditStatePath), false);
      if (publication[0] === 'audit state') {
        assert.equal(await fileExists(paths.remoteStatusPath), true);
        assert.equal(await fileExists(paths.localStatusPath), true);
        assert.equal(await fileExists(paths.pendingSourcesPath), true);
        for (const statusPath of [paths.remoteStatusPath, paths.localStatusPath]) {
          const status = JSON.parse(await fs.readFile(statusPath, 'utf8'));
          assert.notEqual(status.lastAuditResult, 'seeded');
          assert.notEqual(status.lastAuditAt, failedAt.toISOString());
        }
      }

      injectFailure = false;
      currentDate = retryAt;
      await agent.performOneShotScan();
      const seeded = JSON.parse(await fs.readFile(paths.auditStatePath, 'utf8'));
      assert.equal(seeded.lastCompletedAt, retryAt.toISOString());
      assert.equal(seeded.lastResult, 'seeded');

      currentDate = new Date(retryAt.getTime() + 60_000);
      await agent.performOneShotScan();
      assert.deepEqual(JSON.parse(await fs.readFile(paths.auditStatePath, 'utf8')), seeded);
      for (const statusPath of [paths.remoteStatusPath, paths.localStatusPath]) {
        const status = JSON.parse(await fs.readFile(statusPath, 'utf8'));
        assert.equal(status.lastAuditAt, retryAt.toISOString());
        assert.equal(status.lastAuditResult, 'seeded');
      }
    } finally {
      fs.rename = originalRename;
    }
  });
}

test('incremental polling requests startup orphan cleanup only once per agent', async (t) => {
  const { paths } = await makeTestPaths(t);
  const cleanupRequests = [];
  const integrityAuditor = {
    recoverPendingRepairIfNeeded: async ({ cleanupOrphans }) => cleanupRequests.push(cleanupOrphans),
    recordInitialSeedCompleted: async () => {},
  };
  const agent = new BackupAgent({
    paths,
    integrityAuditorFactory: () => integrityAuditor,
  });

  await agent.performOneShotScan();
  await agent.performOneShotScan();
  await agent.performOneShotScan();

  assert.deepEqual(cleanupRequests, [true, false, false]);
});

test('integrity audit runs only after incremental catch-up', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'audit-catchup.jsonl');
  const one = jsonLine({ role: 'user', content: 'one' });
  const two = jsonLine({ role: 'assistant', content: 'two' });
  await writeSessionFile(sourcePath, [one]);
  const agent = new BackupAgent({ paths, now: () => now });
  await agent.performOneShotScan();
  await fs.writeFile(paths.auditStatePath, JSON.stringify({
    lastCompletedAt: new Date(now.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  }));
  await fs.appendFile(sourcePath, two);

  assert.deepEqual(
    await agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001'),
    { outcome: 'completed', checked: 1, repaired: 0 },
  );
  assert.equal(await fs.readFile(paths.backupFilePath(sourcePath), 'utf8'), one + two);
  assert.ok(JSON.parse(await fs.readFile(paths.manifestPath, 'utf8')).sessions['audit-catchup'].contentHash);
});

test('queued incremental scan interrupts audit at a chunk boundary and catches up', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'audit-priority.jsonl');
  const line = jsonLine({ role: 'user', content: 'bulk' });
  const initial = line.repeat(50000);
  await writeSessionFile(sourcePath, [initial]);
  await new BackupAgent({ paths, now: () => now }).performOneShotScan();
  await fs.writeFile(paths.auditStatePath, JSON.stringify({
    lastCompletedAt: new Date(now.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  }));
  let releaseRead;
  let announceRead;
  const readStarted = new Promise((resolve) => { announceRead = resolve; });
  const readRelease = new Promise((resolve) => { releaseRead = resolve; });
  let paused = false;
  const auditor = new BackupIntegrityAuditor({
    paths,
    instrumentation: {
      didReadChunk: async () => {
        if (paused) return;
        paused = true;
        announceRead();
        await readRelease;
      },
    },
  });
  let interruptionSignals = 0;
  const agent = new BackupAgent({
    paths,
    now: () => now,
    instrumentation: { auditInterruptionSet: () => { interruptionSignals += 1; } },
    integrityAuditorFactory: () => auditor,
  });

  const auditPromise = agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001');
  await readStarted;
  const interruptionSignalsBeforeQueuedScan = interruptionSignals;
  const appended = jsonLine({ role: 'assistant', content: 'new' });
  await fs.appendFile(sourcePath, appended);
  const scanPromise = agent.performOneShotScan();
  releaseRead();

  assert.deepEqual(await auditPromise, { outcome: 'interrupted', checked: 0, repaired: 0 });
  await scanPromise;
  assert.equal(interruptionSignals, interruptionSignalsBeforeQueuedScan + 1);
  assert.ok((await fs.readFile(paths.backupFilePath(sourcePath), 'utf8')).endsWith(appended));
});

test('incremental scan recovers pending repair journal before appending', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'wal-before-scan.jsonl');
  const one = jsonLine({ role: 'user', content: 'one' });
  const two = jsonLine({ role: 'assistant', content: 'two' });
  await writeSessionFile(sourcePath, [one]);
  await new BackupAgent({ paths, now: () => now }).performOneShotScan();
  await fs.writeFile(paths.auditStatePath, JSON.stringify({
    lastCompletedAt: new Date(now.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  }));
  const targetPath = paths.backupFilePath(sourcePath);
  const corrupted = Buffer.from(await fs.readFile(targetPath));
  corrupted[0] ^= 0x01;
  await fs.writeFile(targetPath, corrupted);
  const injected = new Error('crash after formal replace');
  const crashAuditor = new BackupIntegrityAuditor({
    paths,
    instrumentation: {
      checkpoint: (value) => {
        if (value === 'afterFormalReplaceBeforeInstalledJournalCommit') throw injected;
      },
    },
  });
  const crashAgent = new BackupAgent({
    paths,
    now: () => now,
    integrityAuditorFactory: () => crashAuditor,
  });
  await assert.rejects(
    crashAgent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001'),
    injected,
  );
  const pendingRepairPath = path.join(paths.stateRoot, 'integrity-repair-pending.json');
  assert.equal(await fileExists(pendingRepairPath), true);

  await fs.appendFile(sourcePath, two);
  await new BackupAgent({ paths, now: () => now }).performOneShotScan();

  assert.equal(await fileExists(pendingRepairPath), false);
  assert.equal(await fs.readFile(targetPath, 'utf8'), one + two);
  assert.equal(JSON.parse(await fs.readFile(paths.auditStatePath, 'utf8')).repairedCount, 1);
  assert.equal(JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8')).repairCount, 1);
});

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  BackupAgent,
  auditDelayMilliseconds,
  createFileCommitter,
} = require('../../src/backup/backup-agent');
const { CursorStore } = require('../../src/backup/cursor-store');
const { BackupIntegrityAuditor } = require('../../src/backup/integrity-auditor');
const { backupPaths } = require('../../src/backup/paths');
const { readNewCompleteLines } = require('../../src/backup/session-tailer');
const { loadVerification } = require('../../src/backup/verification-store');

const DEVICE_ID = '00000000-0000-0000-0000-000000000001';

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

function fixedSizeJSONLine(byteCount, fillByte) {
  const prefix = Buffer.from('{"role":"assistant","content":"');
  const suffix = Buffer.from('"}\n');
  assert.ok(byteCount > prefix.length + suffix.length);
  return Buffer.concat([
    prefix,
    Buffer.alloc(byteCount - prefix.length - suffix.length, fillByte),
    suffix,
  ]);
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

function controlledPromise() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function waitForCondition(predicate, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for test condition.');
    await new Promise((resolve) => setImmediate(resolve));
  }
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
    sourceFileIdentity: null,
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

function spyOnCursorStoreWriteTransactions(store) {
  const originalRunSQLite = store.runSQLite;
  let calls = 0;
  store.runSQLite = function (sql, ...args) {
    if (/^\s*BEGIN IMMEDIATE;/i.test(sql)) calls += 1;
    return originalRunSQLite.call(this, sql, ...args);
  };
  return {
    get calls() {
      return calls;
    },
    restore() {
      store.runSQLite = originalRunSQLite;
    },
  };
}

function spyOnAllCursorStoreWriteTransactions() {
  const originalRunSQLite = CursorStore.prototype.runSQLite;
  let calls = 0;
  CursorStore.prototype.runSQLite = function (sql, ...args) {
    if (/^\s*BEGIN IMMEDIATE;/i.test(sql)) calls += 1;
    return originalRunSQLite.call(this, sql, ...args);
  };
  return {
    get calls() {
      return calls;
    },
    reset() {
      calls = 0;
    },
    restore() {
      CursorStore.prototype.runSQLite = originalRunSQLite;
    },
  };
}

function spyOnAllCursorStoreReads() {
  const originalAll = CursorStore.prototype.all;
  let calls = 0;
  const waiters = [];
  CursorStore.prototype.all = function (...args) {
    calls += 1;
    for (let index = waiters.length - 1; index >= 0; index -= 1) {
      if (calls >= waiters[index].expected) {
        waiters[index].event.resolve();
        waiters.splice(index, 1);
      }
    }
    return originalAll.apply(this, args);
  };
  return {
    get calls() {
      return calls;
    },
    reset() {
      calls = 0;
    },
    waitForCalls(expected) {
      if (calls >= expected) return Promise.resolve();
      const event = controlledPromise();
      waiters.push({ expected, event });
      return event.promise;
    },
    restore() {
      CursorStore.prototype.all = originalAll;
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

test('initial scan publishes a matching verification sidecar', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'verified.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'verified' })]);

  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions.verified;
  const verification = await loadVerification(paths.verificationPath);
  const entry = verification.sessions.verified;
  assert.equal(entry.backupPath, record.backupPath);
  assert.equal(entry.byteCount, record.bytesBackedUp);
  assert.equal(entry.lineCount, record.lineCount);
  assert.ok(entry.chunkHashes.length > 0);
  assert.equal(entry.verifiedAt, '2026-01-02T03:04:00.000Z');
});

test('upload readback reports the verifying progress phase', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'verification-progress.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'progress' })]);
  const phases = [];

  await new BackupAgent({
    paths,
    onProgress: (progress) => phases.push(progress.phase),
  }).performOneShotScan();

  assert.ok(phases.includes('verifying'));
  assert.equal(phases.at(-1), 'seeding');
});

test('rebuild readback failure retries once then publishes a verified file', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'readback-retry.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'retry readback' })]);
  let syncCount = 0;
  const fileCommitter = createFileCommitter({
    sync: async (handle) => {
      syncCount += 1;
      await handle.sync();
      if (syncCount === 1) {
        await handle.write(Buffer.from('x'), 0, 1, 0);
        await handle.sync();
      }
    },
  });

  await new BackupAgent({ paths, fileCommitter, now: makeClock() }).performOneShotScan();

  assert.equal(syncCount, 2);
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions['readback-retry'];
  assert.match(await fs.readFile(path.join(paths.backupRoot, record.backupPath), 'utf8'), /retry readback/);
  const verification = await loadVerification(paths.verificationPath);
  assert.equal(verification.sessions['readback-retry'].byteCount, record.bytesBackedUp);
});

test('two rebuild readback failures preserve the formal backup and metadata', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'readback-fails.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'old payload' })]);
  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  const before = await Promise.all([
    fs.readFile(targetPath),
    fs.readFile(paths.manifestPath),
    fs.readFile(paths.cursorDatabasePath),
    fs.readFile(paths.verificationPath),
  ]);
  await fs.writeFile(sourcePath, jsonLine({ role: 'user', content: 'new payload' }));
  const later = new Date(Date.now() + 60000);
  await fs.utimes(sourcePath, later, later);
  let syncCount = 0;
  const fileCommitter = createFileCommitter({
    sync: async (handle) => {
      syncCount += 1;
      await handle.sync();
      await handle.write(Buffer.from('x'), 0, 1, 0);
      await handle.sync();
    },
  });

  await assert.rejects(
    new BackupAgent({ paths, fileCommitter }).performOneShotScan(),
    (error) => /readback-fails\.jsonl/.test(error.message) && /JSONL/i.test(error.message),
  );

  assert.equal(syncCount, 2);
  const after = await Promise.all([
    fs.readFile(targetPath),
    fs.readFile(paths.manifestPath),
    fs.readFile(paths.cursorDatabasePath),
    fs.readFile(paths.verificationPath),
  ]);
  assert.deepEqual(after, before);
});

test('two append readback failures roll back to the last verified length', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'append-readback-fails.jsonl');
  const first = jsonLine({ role: 'user', content: 'first' });
  const second = jsonLine({ role: 'assistant', content: 'second' });
  await writeSessionFile(sourcePath, [first]);
  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  const before = await Promise.all([
    fs.readFile(targetPath),
    fs.readFile(paths.manifestPath),
    fs.readFile(paths.cursorDatabasePath),
    fs.readFile(paths.verificationPath),
  ]);
  const oldOffset = before[0].length;
  await fs.appendFile(sourcePath, second);
  let syncCount = 0;
  const fileCommitter = createFileCommitter({
    sync: async (handle) => {
      syncCount += 1;
      await handle.sync();
      if (syncCount === 1 || syncCount === 3) {
        await handle.write(Buffer.from('x'), 0, 1, oldOffset);
        await handle.sync();
      }
    },
  });

  await assert.rejects(new BackupAgent({ paths, fileCommitter }).performOneShotScan());

  assert.equal(syncCount, 3);
  const after = await Promise.all([
    fs.readFile(targetPath),
    fs.readFile(paths.manifestPath),
    fs.readFile(paths.cursorDatabasePath),
    fs.readFile(paths.verificationPath),
  ]);
  assert.deepEqual(after, before);
});

test('append verification repairs an already-corrupted final chunk with one rebuild retry', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'append-repairs-old-chunk.jsonl');
  const first = jsonLine({ role: 'user', content: 'first' });
  const second = jsonLine({ role: 'assistant', content: 'second' });
  await writeSessionFile(sourcePath, [first]);
  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();

  const targetPath = paths.backupFilePath(sourcePath);
  const corrupted = await fs.readFile(targetPath);
  corrupted[0] ^= 0x01;
  await fs.writeFile(targetPath, corrupted);
  await fs.appendFile(sourcePath, second);

  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();

  assert.equal(await fs.readFile(targetPath, 'utf8'), first + second);
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const verification = await loadVerification(paths.verificationPath);
  assert.equal(manifest.sessions['append-repairs-old-chunk'].bytesBackedUp, Buffer.byteLength(first + second));
  assert.equal(verification.sessions['append-repairs-old-chunk'].byteCount, Buffer.byteLength(first + second));
  assert.equal((await loadCursor(paths, sourcePath)).lastByteOffset, Buffer.byteLength(first + second));
});

test('second scan appends only new completed lines and repeated scan has no duplicate', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'append.jsonl');
  await writeSessionFile(sourcePath, [
    jsonLine({ role: 'user', content: 'Start' }),
  ]);

  const baseCommitter = createFileCommitter();
  let appendCount = 0;
  let rebuildCount = 0;
  const fileCommitter = {
    ...baseCommitter,
    async appendCompleteLines(...args) {
      appendCount += 1;
      return baseCommitter.appendCompleteLines(...args);
    },
    async rebuildCompleteLines(...args) {
      rebuildCount += 1;
      return baseCommitter.rebuildCompleteLines(...args);
    },
  };
  const agent = new BackupAgent({ paths, fileCommitter, now: makeClock() });
  await agent.performOneShotScan();
  appendCount = 0;
  rebuildCount = 0;
  await fs.appendFile(sourcePath, jsonLine({ role: 'assistant', content: 'New answer' }), 'utf8');
  await agent.performOneShotScan();
  assert.equal(appendCount, 1);
  assert.equal(rebuildCount, 0);
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const backupPath = path.join(paths.backupRoot, manifest.sessions.append.backupPath);
  assert.deepEqual(await readLines(backupPath), [
    JSON.stringify({ role: 'user', content: 'Start' }),
    JSON.stringify({ role: 'assistant', content: 'New answer' }),
  ]);
  assert.equal(manifest.sessions.append.lineCount, 2);
});

test('steady-state scan reads the append and revalidates from the final chunk boundary', async (t) => {
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
    start >= 0 && end <= newOffset
  )));
  assert.ok(appendedRanges.get(sourcePath).some(({ start }) => start === oldOffset));
  assert.equal(await fs.readFile(paths.backupFilePath(sourcePath), 'utf8'), first + second);
});

test('growing full rewrite with changed first and middle anchors rebuilds the exact source', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'growing-anchor-rewrite.jsonl');
  const chunkSize = 4 * 1024 * 1024;
  const originalChunks = [0x61, 0x62, 0x63, 0x64, 0x65]
    .map((fill) => fixedSizeJSONLine(chunkSize, fill));
  await fs.mkdir(path.dirname(sourcePath), { recursive: true });
  await fs.writeFile(sourcePath, Buffer.concat(originalChunks));
  await new BackupAgent({ paths }).performOneShotScan();

  const replacementChunks = [...originalChunks];
  replacementChunks[0] = fixedSizeJSONLine(chunkSize, 0x78);
  replacementChunks[2] = fixedSizeJSONLine(chunkSize, 0x79);
  const appended = Buffer.from(jsonLine({ role: 'assistant', content: 'growth' }));
  const replacement = Buffer.concat([...replacementChunks, appended]);
  await fs.writeFile(sourcePath, replacement);
  const changedAt = new Date(Date.now() + 60_000);
  await fs.utimes(sourcePath, changedAt, changedAt);

  const baseCommitter = createFileCommitter();
  let appendCount = 0;
  let rebuildCount = 0;
  const fileCommitter = {
    ...baseCommitter,
    async appendCompleteLines(...args) {
      appendCount += 1;
      return baseCommitter.appendCompleteLines(...args);
    },
    async rebuildCompleteLines(...args) {
      rebuildCount += 1;
      return baseCommitter.rebuildCompleteLines(...args);
    },
  };

  await new BackupAgent({ paths, fileCommitter }).performOneShotScan();

  assert.equal(appendCount, 0);
  assert.equal(rebuildCount, 1);
  assert.deepEqual(await fs.readFile(paths.backupFilePath(sourcePath)), replacement);
});

test('source identity replacement rebuilds even when all old anchors still match', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'identity-replacement.jsonl');
  const initial = Buffer.from(jsonLine({ role: 'assistant', content: 'stable prefix' }));
  await fs.mkdir(path.dirname(sourcePath), { recursive: true });
  await fs.writeFile(sourcePath, initial);
  await new BackupAgent({ paths }).performOneShotScan();
  const beforeCursor = await loadCursor(paths, sourcePath);
  assert.match(beforeCursor.sourceFileIdentity, /^\d+:\d+$/);

  const replacementPath = `${sourcePath}.replacement`;
  const replacement = Buffer.concat([
    initial,
    Buffer.from(jsonLine({ role: 'assistant', content: 'new line' })),
  ]);
  await fs.writeFile(replacementPath, replacement);
  const changedAt = new Date(Date.now() + 60_000);
  await fs.utimes(replacementPath, changedAt, changedAt);
  await fs.rename(replacementPath, sourcePath);

  const baseCommitter = createFileCommitter();
  let appendCount = 0;
  let rebuildCount = 0;
  const fileCommitter = {
    ...baseCommitter,
    async appendCompleteLines(...args) {
      appendCount += 1;
      return baseCommitter.appendCompleteLines(...args);
    },
    async rebuildCompleteLines(...args) {
      rebuildCount += 1;
      return baseCommitter.rebuildCompleteLines(...args);
    },
  };

  await new BackupAgent({ paths, fileCommitter }).performOneShotScan();

  assert.equal(appendCount, 0);
  assert.equal(rebuildCount, 1);
  assert.notEqual((await loadCursor(paths, sourcePath)).sourceFileIdentity, beforeCursor.sourceFileIdentity);
  assert.deepEqual(await fs.readFile(paths.backupFilePath(sourcePath)), replacement);
});

test('legacy null source identity validates anchors, appends, and records the current identity', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'legacy-null-identity.jsonl');
  const initial = jsonLine({ role: 'user', content: 'initial' });
  const appended = jsonLine({ role: 'assistant', content: 'append' });
  await writeSessionFile(sourcePath, [initial]);
  await new BackupAgent({ paths }).performOneShotScan();
  const store = new CursorStore({ paths });
  await store.open();
  const legacyCursor = await store.get(sourcePath);
  await store.upsert({ ...legacyCursor, sourceFileIdentity: null });
  await store.close();
  await fs.appendFile(sourcePath, appended);

  const baseCommitter = createFileCommitter();
  let appendCount = 0;
  let rebuildCount = 0;
  const fileCommitter = {
    ...baseCommitter,
    async appendCompleteLines(...args) {
      appendCount += 1;
      return baseCommitter.appendCompleteLines(...args);
    },
    async rebuildCompleteLines(...args) {
      rebuildCount += 1;
      return baseCommitter.rebuildCompleteLines(...args);
    },
  };

  await new BackupAgent({ paths, fileCommitter }).performOneShotScan();

  assert.equal(appendCount, 1);
  assert.equal(rebuildCount, 0);
  assert.match((await loadCursor(paths, sourcePath)).sourceFileIdentity, /^\d+:\d+$/);
  assert.equal(await fs.readFile(paths.backupFilePath(sourcePath), 'utf8'), initial + appended);
});

test('unchanged legacy null identity does no body, target, rebuild, or cursor write work', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'legacy-null-unchanged.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'unchanged' })]);
  await new BackupAgent({ paths }).performOneShotScan();
  const store = new CursorStore({ paths });
  await store.open();
  const current = await store.get(sourcePath);
  await store.upsert({ ...current, sourceFileIdentity: null });
  await store.close();

  const baseCommitter = createFileCommitter();
  let targetInspections = 0;
  let rebuildCount = 0;
  const fileCommitter = {
    ...baseCommitter,
    async inspectTarget(...args) {
      targetInspections += 1;
      return baseCommitter.inspectTarget(...args);
    },
    async rebuildCompleteLines(...args) {
      rebuildCount += 1;
      return baseCommitter.rebuildCompleteLines(...args);
    },
  };
  const transactionSpy = spyOnAllCursorStoreWriteTransactions();
  t.after(() => transactionSpy.restore());
  const targetPath = paths.backupFilePath(sourcePath);

  const ranges = await withTrackedReadRanges(
    [sourcePath, targetPath],
    () => new BackupAgent({ paths, fileCommitter }).performOneShotScan(),
  );

  assert.equal(targetInspections, 0);
  assert.equal(rebuildCount, 0);
  assert.deepEqual(ranges.get(sourcePath), []);
  assert.deepEqual(ranges.get(targetPath), []);
  assert.equal(transactionSpy.calls, 0);
  assert.equal((await loadCursor(paths, sourcePath)).sourceFileIdentity, null);
});

test('idle pending count treats an unchanged legacy null identity as settled', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'legacy-null-idle.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'unchanged' })]);
  await new BackupAgent({ paths }).performOneShotScan();
  const store = new CursorStore({ paths });
  await store.open();
  const current = await store.get(sourcePath);
  await store.upsert({ ...current, sourceFileIdentity: null });
  await store.close();

  assert.equal(await new BackupAgent({ paths }).pendingSessionCount(), 0);
  assert.deepEqual(JSON.parse(await fs.readFile(paths.pendingSourcesPath, 'utf8')), { pending: [] });
  assert.equal((await loadCursor(paths, sourcePath)).sourceFileIdentity, null);
});

test('source change during append truncates the target and leaves backup metadata unchanged', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'changes-during-append.jsonl');
  const initial = jsonLine({ role: 'user', content: 'initial' });
  const appended = jsonLine({ role: 'assistant', content: 'intended append' });
  await writeSessionFile(sourcePath, [initial]);
  await new BackupAgent({ paths }).performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  const beforeTarget = await fs.readFile(targetPath);
  const beforeManifest = await fs.readFile(paths.manifestPath);
  const beforeVerification = await fs.readFile(paths.verificationPath);
  const beforeCursor = await loadCursor(paths, sourcePath);
  await fs.appendFile(sourcePath, appended);

  const baseCommitter = createFileCommitter();
  let sourceMutated = false;
  const fileCommitter = {
    ...baseCommitter,
    async appendCompleteLines(...args) {
      const result = await baseCommitter.appendCompleteLines(...args);
      sourceMutated = true;
      await fs.appendFile(sourcePath, jsonLine({ role: 'assistant', content: 'raced append' }));
      const changedAt = new Date(Date.now() + 60_000);
      await fs.utimes(sourcePath, changedAt, changedAt);
      return result;
    },
  };

  await assert.rejects(
    new BackupAgent({ paths, fileCommitter }).performOneShotScan(),
    /changed during backup/i,
  );

  assert.equal(sourceMutated, true);
  assert.deepEqual(await fs.readFile(targetPath), beforeTarget);
  assert.deepEqual(await fs.readFile(paths.manifestPath), beforeManifest);
  assert.deepEqual(await fs.readFile(paths.verificationPath), beforeVerification);
  assert.deepEqual(await loadCursor(paths, sourcePath), beforeCursor);
});

test('source metadata recheck failure after append restores the caller verification object before throwing', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'removed-during-append.jsonl');
  const initial = jsonLine({ role: 'user', content: 'initial' });
  const appended = jsonLine({ role: 'assistant', content: 'intended append' });
  await writeSessionFile(sourcePath, [initial]);
  await new BackupAgent({ paths }).performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  const beforeTarget = await fs.readFile(targetPath);
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const verification = await loadVerification(paths.verificationPath);
  const beforeManifest = JSON.stringify(manifest);
  const beforeVerification = JSON.stringify(verification);
  const currentCursor = await loadCursor(paths, sourcePath);
  await fs.appendFile(sourcePath, appended);

  const baseCommitter = createFileCommitter();
  const agent = new BackupAgent({ paths, fileCommitter: baseCommitter });
  const originalLstat = fs.lstat;
  let trustedMetadataReads = 0;
  fs.lstat = async (filePath, options, ...args) => {
    if (path.resolve(String(filePath)) === path.resolve(sourcePath) && options?.bigint === true) {
      trustedMetadataReads += 1;
      if (trustedMetadataReads > 1) throw new Error('injected source metadata recheck failure');
    }
    return originalLstat.call(fs, filePath, options, ...args);
  };
  try {
    await assert.rejects(agent.processSessionFile({
      sourcePath,
      sessionId: 'removed-during-append',
      scanDate: new Date('2026-07-16T06:00:00.000Z'),
      manifest,
      verification,
      onVerifying: () => {},
      currentCursor,
      cursorMap: new Map([[sourcePath, currentCursor]]),
    }), /injected source metadata recheck failure/);
  } finally {
    fs.lstat = originalLstat;
  }

  assert.deepEqual(await fs.readFile(targetPath), beforeTarget);
  assert.equal(JSON.stringify(manifest), beforeManifest);
  assert.equal(JSON.stringify(verification), beforeVerification);
  assert.deepEqual(await loadCursor(paths, sourcePath), currentCursor);
});

test('daily audit repairs a growing rewrite that preserves all three append anchors', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'non-anchor-rewrite.jsonl');
  const chunkSize = 4 * 1024 * 1024;
  const chunks = [0x61, 0x62, 0x63, 0x64, 0x65]
    .map((fill) => fixedSizeJSONLine(chunkSize, fill));
  await fs.mkdir(path.dirname(sourcePath), { recursive: true });
  await fs.writeFile(sourcePath, Buffer.concat(chunks));
  const now = new Date('2026-07-16T06:00:00.000Z');
  const agent = new BackupAgent({ paths, now: () => now });
  await agent.performOneShotScan();

  const rewrittenChunks = [...chunks];
  rewrittenChunks[1] = fixedSizeJSONLine(chunkSize, 0x78);
  const rewritten = Buffer.concat([
    ...rewrittenChunks,
    Buffer.from(jsonLine({ role: 'assistant', content: 'growth' })),
  ]);
  await fs.writeFile(sourcePath, rewritten);
  const changedAt = new Date(now.getTime() + 60_000);
  await fs.utimes(sourcePath, changedAt, changedAt);
  await agent.performOneShotScan();
  const targetPath = paths.backupFilePath(sourcePath);
  assert.notDeepEqual(await fs.readFile(targetPath), rewritten);

  await fs.writeFile(paths.auditStatePath, `${JSON.stringify({
    lastCompletedAt: new Date(now.getTime() - (86400 * 1000) - 1).toISOString(),
    lastResult: 'completed',
    repairedCount: 0,
  })}\n`);
  const outcome = await agent.performIntegrityAuditIfDue(DEVICE_ID);

  assert.deepEqual(outcome, { outcome: 'completed', checked: 1, repaired: 1 });
  assert.deepEqual(await fs.readFile(targetPath), rewritten);
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

test('fresh scan with no changed cursors performs zero cursor write transactions', async (t) => {
  const { paths } = await makeTestPaths(t);
  const transactionSpy = spyOnAllCursorStoreWriteTransactions();

  try {
    await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  } finally {
    transactionSpy.restore();
  }

  assert.equal(transactionSpy.calls, 0);
  assert.equal(await fileExists(paths.cursorDatabasePath), true);
});

test('fresh scan batches many changed cursors into one native write transaction', async (t) => {
  const { paths } = await makeTestPaths(t);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'batch-one.jsonl'), [
    jsonLine({ role: 'user', content: 'One' }),
  ]);
  await writeSessionFile(path.join(paths.codexRoot, 'sessions', 'batch-two.jsonl'), [
    jsonLine({ role: 'user', content: 'Two' }),
  ]);

  const originalAll = CursorStore.prototype.all;
  const originalUpsertMany = CursorStore.prototype.upsertMany;
  const transactionSpy = spyOnAllCursorStoreWriteTransactions();
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
    transactionSpy.restore();
    if (originalAll) CursorStore.prototype.all = originalAll;
    else delete CursorStore.prototype.all;
    if (originalUpsertMany) CursorStore.prototype.upsertMany = originalUpsertMany;
    else delete CursorStore.prototype.upsertMany;
  }

  assert.equal(allCalls, 1);
  assert.equal(upsertManyCalls, 1);
  assert.equal(transactionSpy.calls, 1);
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
  const initialManifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const initialBackupPath = initialManifest.sessions.moved.backupPath;

  await fs.mkdir(path.dirname(archivedPath), { recursive: true });
  await fs.rename(activePath, archivedPath);
  const migrationTransactionSpy = spyOnAllCursorStoreWriteTransactions();
  try {
    await agent.performOneShotScan();
  } finally {
    migrationTransactionSpy.restore();
  }
  assert.equal(migrationTransactionSpy.calls, 1);
  await fs.appendFile(archivedPath, jsonLine({ role: 'assistant', content: 'After archive' }), 'utf8');
  await agent.performOneShotScan();

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions.moved;
  assert.equal(record.sourcePath, archivedPath);
  assert.equal(record.backupPath, initialBackupPath);
  assert.deepEqual(await readLines(path.join(paths.backupRoot, record.backupPath)), [
    JSON.stringify({ role: 'user', content: 'Original' }),
    JSON.stringify({ role: 'assistant', content: 'After archive' }),
  ]);
  assert.equal(record.lineCount, 2);

  const cursorStore = new CursorStore({ paths });
  await cursorStore.open();
  const cursors = cursorStore.all();
  await cursorStore.close();
  assert.equal(cursors.size, 1);
  assert.equal(cursors.has(activePath), false);
  assert.equal(cursors.has(archivedPath), true);

  const dueDate = new Date('2026-07-15T04:05:06.000Z');
  await fs.writeFile(paths.auditStatePath, `${JSON.stringify({
    lastCompletedAt: new Date(dueDate.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  })}\n`);
  const auditOutcome = await new BackupIntegrityAuditor({ paths }).runIfDue({
    now: dueDate,
    deviceId: DEVICE_ID,
    cursors,
    interruptionRequested: () => false,
  });
  assert.deepEqual(auditOutcome, { outcome: 'completed', checked: 1, repaired: 0 });
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

  let validations = 0;
  const agent = new BackupAgent({
    paths,
    now: makeClock(),
    validateTarget: async () => { validations += 1; },
  });
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

  validations = 0;
  await agent.requestImmediateScan('timer');
  assert.equal(validations, 1, 'an unchanged source with a backup error must be retried');
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

test('rollback sync failure stops retry without advancing metadata and later scan recovers', async (t) => {
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

  await assert.rejects(retryAgent.performOneShotScan(), /injected sync failure 2/);
  assert.equal(syncCalls, 2);
  assert.equal(await fs.readFile(targetPath, 'utf8'), first);
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

test('initial matching unverified target is rebuilt and gains a verification sidecar', async (t) => {
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
  assert.equal(ranges.get(targetPath).length, 0);
  assert.ok([...ranges.values()].flat().every(({ requested }) => requested <= 1024 * 1024));
  const verification = await loadVerification(paths.verificationPath);
  assert.equal(verification.sessions['existing-seed-hash'].byteCount, Buffer.byteLength(contents));
  assert.ok(verification.sessions['existing-seed-hash'].chunkHashes.length > 0);
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

test('unchanged scan stops before target, body, hash, manifest, and cursor transaction work', async (t) => {
  const { paths } = await makeTestPaths(t);
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'strict-no-change.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'stable' })]);
  await new BackupAgent({ paths, now: makeClock() }).performOneShotScan();
  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  const targetPath = path.join(paths.backupRoot, manifest.sessions['strict-no-change'].backupPath);
  const transactionSpy = spyOnAllCursorStoreWriteTransactions();
  const originalStat = fs.stat;
  const originalLstat = fs.lstat;
  const originalOpen = fs.open;
  const originalReadFile = fs.readFile;
  const originalRename = fs.rename;
  let targetStatCount = 0;
  let bodyReadCount = 0;
  let manifestWriteCount = 0;
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
    transactionSpy.restore();
  }

  assert.equal(targetStatCount, 0);
  assert.equal(bodyReadCount, 0);
  assert.equal(manifestWriteCount, 0);
  assert.equal(transactionSpy.calls, 0);
});

test('append revalidates from the final chunk boundary and clears the optional full hash', async (t) => {
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
    start >= 0 && end <= newOffset && requested <= 4 * 1024 * 1024
  )));
  assert.ok(readRanges.some(({ start }) => start === oldOffset));
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
    start >= 0 && end <= newOffset && requested <= 4 * 1024 * 1024
  )));
  assert.ok(ranges.get(sourcePath).some(({ start }) => start === oldOffset));
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
  let verification = await loadVerification(paths.verificationPath);
  assert.deepEqual(verification.sessions['empty-hash'].chunkHashes, []);
  assert.equal(verification.sessions['empty-hash'].byteCount, 0);

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
  verification = await loadVerification(paths.verificationPath);
  assert.deepEqual(verification.sessions['empty-hash'].chunkHashes, []);
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
    sourceFileIdentity: null,
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

test('cursor store materializes all cursors and writes a changed batch once', async (t) => {
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
  const transactionSpy = spyOnCursorStoreWriteTransactions(store);
  t.after(() => transactionSpy.restore());

  await store.upsertMany([one, two]);

  const cursors = store.all();
  assert.equal(transactionSpy.calls, 1);
  assert.ok(cursors instanceof Map);
  assert.equal(cursors.size, 2);
  assert.deepEqual(cursors.get(one.sourcePath), one);
  assert.deepEqual(cursors.get(two.sourcePath), two);
});

test('empty cursor batch does not start a write transaction', async (t) => {
  const { paths } = await makeTestPaths(t);
  const store = new CursorStore({ paths });
  await store.open();
  t.after(async () => {
    await store.close();
  });
  const transactionSpy = spyOnCursorStoreWriteTransactions(store);
  t.after(() => transactionSpy.restore());

  await store.upsertMany([]);

  assert.equal(transactionSpy.calls, 0);
  assert.equal(store.all().size, 0);
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

test('persisted status is published through the agent status callback', async (t) => {
  const { paths } = await makeTestPaths(t);
  const statuses = [];
  const agent = new BackupAgent({ paths, onStatus: (status) => statuses.push(status) });

  await agent.performOneShotScan();

  const persisted = JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8'));
  assert.deepEqual(statuses, [persisted]);
});

test('audit delay uses overdue jitter and a stable per-device daily window', () => {
  const now = new Date('2026-07-14T04:05:06.000Z');

  assert.equal(auditDelayMilliseconds(now, null, DEVICE_ID), 676000);
  assert.equal(
    auditDelayMilliseconds(now, new Date('2026-07-13T04:05:05.000Z'), DEVICE_ID),
    676000,
  );
  assert.equal(
    auditDelayMilliseconds(now, new Date('2026-07-13T12:00:00.000Z'), DEVICE_ID),
    new Date('2026-07-15T10:45:33.000Z').getTime() - now.getTime(),
  );
});

test('startup scan schedules an autonomous audit that catches up first and reschedules', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const timers = [];
  const cancelled = [];
  let scanCount = 0;
  let auditCount = 0;
  const auditor = {
    async recoverPendingRepairIfNeeded() {},
    async recordInitialSeedCompleted() {},
    async runIfDue({ deviceId }) {
      assert.equal(deviceId, DEVICE_ID);
      assert.equal(scanCount, 2);
      auditCount += 1;
      return { outcome: 'completed', checked: 0, repaired: 0 };
    },
  };
  const agent = new BackupAgent({
    paths,
    now: () => now,
    deviceId: DEVICE_ID,
    validateTarget: async () => { scanCount += 1; },
    integrityAuditorFactory: () => auditor,
    auditDelayProvider: (scheduledAt, lastAuditAt, deviceId) => {
      assert.deepEqual(scheduledAt, now);
      assert.equal(lastAuditAt, now.toISOString());
      assert.equal(deviceId, DEVICE_ID);
      return 1234;
    },
    auditTimerScheduler: (action, delay) => {
      const timer = { action, delay, unref() {} };
      timers.push(timer);
      return timer;
    },
    cancelAuditTimer: (timer) => cancelled.push(timer),
  });
  t.after(() => agent.stop());

  await agent.requestImmediateScan('startup');
  assert.equal(timers.length, 1);
  assert.equal(timers[0].delay, 1234);

  assert.deepEqual(
    await timers[0].action(),
    { outcome: 'completed', checked: 0, repaired: 0 },
  );
  assert.equal(auditCount, 1);
  assert.equal(scanCount, 2);
  assert.equal(timers.length, 2);
  assert.deepEqual(cancelled, []);
});

test('no-change periodic tick does not starve the original audit timer', async (t) => {
  const { paths } = await makeTestPaths(t);
  const timers = [];
  let scanCount = 0;
  let auditCount = 0;
  const auditor = {
    async recoverPendingRepairIfNeeded() {},
    async recordInitialSeedCompleted() {},
    async runIfDue() {
      assert.equal(scanCount, 2);
      auditCount += 1;
      return { outcome: 'completed', checked: 0, repaired: 0 };
    },
  };
  const agent = new BackupAgent({
    paths,
    deviceId: DEVICE_ID,
    validateTarget: async () => { scanCount += 1; },
    integrityAuditorFactory: () => auditor,
    auditDelayProvider: () => 86400000,
    auditTimerScheduler: (action, delay) => {
      const timer = { action, delay, unref() {} };
      timers.push(timer);
      return timer;
    },
  });
  t.after(() => agent.stop());

  await agent.requestImmediateScan('startup');
  const originalTimer = timers[0];
  await agent.requestImmediateScan('timer');
  assert.equal(timers.length, 1);

  assert.deepEqual(
    await originalTimer.action(),
    { outcome: 'completed', checked: 0, repaired: 0 },
  );
  assert.equal(auditCount, 1);
  assert.equal(scanCount, 2);
  assert.equal(timers.length, 2);
});

test('wake replaces an audit timer and a stale callback cannot clear or run the replacement', async (t) => {
  const { paths } = await makeTestPaths(t);
  const timers = [];
  const cancelled = [];
  let auditCount = 0;
  const auditor = {
    async recoverPendingRepairIfNeeded() {},
    async recordInitialSeedCompleted() {},
    async runIfDue() {
      auditCount += 1;
      return { outcome: 'not-due', checked: 0, repaired: 0 };
    },
  };
  const agent = new BackupAgent({
    paths,
    deviceId: DEVICE_ID,
    validateTarget: async () => {},
    integrityAuditorFactory: () => auditor,
    auditDelayProvider: () => 0,
    auditTimerScheduler: (action, delay) => {
      const timer = { action, delay, unref() {} };
      timers.push(timer);
      return timer;
    },
    cancelAuditTimer: (timer) => cancelled.push(timer),
  });
  t.after(() => agent.stop());

  await agent.requestImmediateScan('startup');
  const staleTimer = timers[0];
  await agent.requestImmediateScan('wake');
  const replacementTimer = timers[1];

  assert.deepEqual(cancelled, [staleTimer]);
  assert.equal(await staleTimer.action(), null);
  assert.equal(auditCount, 0);
  await replacementTimer.action();
  assert.equal(auditCount, 1);
  assert.equal(timers.length, 3);
});

test('explicit activation interruption of a scheduled audit is followed by a replacement schedule', async (t) => {
  const { paths } = await makeTestPaths(t);
  const timers = [];
  const auditEntered = controlledPromise();
  const releaseAudit = controlledPromise();
  const auditor = {
    async recoverPendingRepairIfNeeded() {},
    async recordInitialSeedCompleted() {},
    async runIfDue({ interruptionRequested }) {
      auditEntered.resolve();
      await releaseAudit.promise;
      return interruptionRequested()
        ? { outcome: 'interrupted', checked: 0, repaired: 0 }
        : { outcome: 'completed', checked: 0, repaired: 0 };
    },
  };
  const agent = new BackupAgent({
    paths,
    deviceId: DEVICE_ID,
    validateTarget: async () => {},
    integrityAuditorFactory: () => auditor,
    auditDelayProvider: () => 0,
    auditTimerScheduler: (action, delay) => {
      const timer = { action, delay, unref() {} };
      timers.push(timer);
      return timer;
    },
  });
  t.after(() => {
    releaseAudit.resolve();
    agent.stop();
  });

  await agent.requestImmediateScan('startup');
  const scheduledAudit = timers[0].action();
  await auditEntered.promise;
  const queuedScan = agent.requestImmediateScan('activation');
  releaseAudit.resolve();

  assert.deepEqual(
    await scheduledAudit,
    { outcome: 'interrupted', checked: 0, repaired: 0 },
  );
  await queuedScan;
  assert.equal(timers.length, 2);
});

test('stop cancels the current audit timer and rejects its stale callback', async (t) => {
  const { paths } = await makeTestPaths(t);
  const timers = [];
  const cancelled = [];
  let auditCount = 0;
  const auditor = {
    async recoverPendingRepairIfNeeded() {},
    async recordInitialSeedCompleted() {},
    async runIfDue() {
      auditCount += 1;
      return { outcome: 'completed', checked: 0, repaired: 0 };
    },
  };
  const agent = new BackupAgent({
    paths,
    deviceId: DEVICE_ID,
    validateTarget: async () => {},
    integrityAuditorFactory: () => auditor,
    auditDelayProvider: () => 0,
    auditTimerScheduler: (action, delay) => {
      const timer = { action, delay, unref() {} };
      timers.push(timer);
      return timer;
    },
    cancelAuditTimer: (timer) => cancelled.push(timer),
  });

  await agent.requestImmediateScan('startup');
  agent.stop();
  assert.deepEqual(cancelled, [timers[0]]);
  assert.equal(await timers[0].action(), null);
  assert.equal(auditCount, 0);
});

test('polling defaults to 30 seconds and stale timer callbacks are rejected after stop', async (t) => {
  const { paths } = await makeTestPaths(t);
  const scheduled = [];
  const cancelled = [];
  const triggers = [];
  let validations = 0;
  const agent = new BackupAgent({
    paths,
    validateTarget: async () => { validations += 1; },
    instrumentation: { scanRequested: (trigger) => triggers.push(trigger) },
    scheduleInterval: (action, delay) => {
      const timer = { action, delay, unref() {} };
      scheduled.push(timer);
      return timer;
    },
    cancelInterval: (timer) => cancelled.push(timer),
  });

  agent.startPolling();
  assert.equal(scheduled.length, 1);
  assert.equal(scheduled[0].delay, 30000);
  assert.equal(validations, 0);

  await scheduled[0].action();
  assert.equal(validations, 1);
  assert.deepEqual(triggers, ['timer']);

  agent.stop();
  await scheduled[0].action();
  assert.equal(validations, 1);
  assert.deepEqual(triggers, ['timer']);
  assert.deepEqual(cancelled, [scheduled[0]]);
});

test('no-change timer ticks stay local until five-minute health and thirty-minute heartbeat deadlines', async (t) => {
  const { paths } = await makeTestPaths(t);
  const startedAt = new Date('2026-07-15T01:00:00.000Z');
  let currentTime = startedAt;
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'idle-cadence.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'steady' })]);
  let validations = 0;
  let remoteStatusWrites = 0;
  const agent = new BackupAgent({
    paths,
    now: () => currentTime,
    healthCheckIntervalMs: 5 * 60 * 1000,
    remoteHeartbeatIntervalMs: 30 * 60 * 1000,
    validateTarget: async () => { validations += 1; },
    instrumentation: {
      remoteStatusWrite: () => { remoteStatusWrites += 1; },
    },
  });
  t.after(() => agent.stop());
  await agent.performOneShotScan();
  validations = 0;
  remoteStatusWrites = 0;

  currentTime = new Date(startedAt.getTime() + (5 * 60 * 1000) - 1);
  await agent.requestImmediateScan('timer');
  assert.equal(validations, 0);
  assert.equal(remoteStatusWrites, 0);

  currentTime = new Date(startedAt.getTime() + (5 * 60 * 1000));
  await agent.requestImmediateScan('timer');
  assert.equal(validations, 1);
  assert.equal(remoteStatusWrites, 0);

  currentTime = new Date(startedAt.getTime() + (30 * 60 * 1000) - 1);
  await agent.requestImmediateScan('timer');
  assert.equal(validations, 2);
  assert.equal(remoteStatusWrites, 0);

  currentTime = new Date(startedAt.getTime() + (30 * 60 * 1000));
  await agent.requestImmediateScan('timer');
  assert.equal(validations, 3);
  assert.equal(remoteStatusWrites, 1);
  const remoteStatus = JSON.parse(await fs.readFile(paths.remoteStatusPath, 'utf8'));
  assert.equal(remoteStatus.lastHeartbeatAt, currentTime.toISOString());
});

test('local append triggers an immediate timer scan before the health deadline', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-15T01:00:00.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'local-change.jsonl');
  const original = jsonLine({ role: 'user', content: 'original' });
  const appended = jsonLine({ role: 'assistant', content: 'new' });
  await writeSessionFile(sourcePath, [original]);
  await new BackupAgent({ paths, now: () => now }).performOneShotScan();
  const initialStatus = JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8'));
  await fs.appendFile(sourcePath, appended);
  let validations = 0;
  const agent = new BackupAgent({
    paths,
    now: () => new Date(now.getTime() + 30000),
    initialStatus,
    validateTarget: async () => { validations += 1; },
  });
  t.after(() => agent.stop());

  await agent.requestImmediateScan('timer');

  assert.equal(validations, 1);
  assert.ok((await fs.readFile(paths.backupFilePath(sourcePath), 'utf8')).endsWith(appended));
});

test('concurrent triggers serialize one active scan and at most one queued follow-up', async (t) => {
  const { paths } = await makeTestPaths(t);
  const gates = [];
  const triggers = [];
  let activeScans = 0;
  let maximumConcurrentScans = 0;
  let scanCount = 0;
  const agent = new BackupAgent({
    paths,
    validateTarget: async () => {
      scanCount += 1;
      activeScans += 1;
      maximumConcurrentScans = Math.max(maximumConcurrentScans, activeScans);
      const gate = controlledPromise();
      gates.push(gate);
      await gate.promise;
      activeScans -= 1;
    },
    instrumentation: { scanRequested: (trigger) => triggers.push(trigger) },
  });
  t.after(() => {
    for (const gate of gates) gate.resolve();
    agent.stop();
  });

  const requests = [];
  const drain = agent.requestImmediateScan('startup');
  requests.push(drain);
  await waitForCondition(() => scanCount === 1);
  requests.push(agent.requestImmediateScan('wake'));
  requests.push(agent.requestImmediateScan('reconnect'));
  requests.push(agent.requestImmediateScan('timer'));
  gates[0].resolve();
  await waitForCondition(() => scanCount === 2);
  requests.push(agent.requestImmediateScan('wake'));
  requests.push(agent.requestImmediateScan('reconnect'));
  requests.push(agent.requestImmediateScan('timer'));
  gates[1].resolve();
  await Promise.allSettled(requests);

  assert.equal(scanCount, 2);
  assert.equal(maximumConcurrentScans, 1);
  assert.deepEqual(triggers, ['startup', 'wake', 'reconnect', 'timer', 'wake', 'reconnect', 'timer']);
});

test('replacement quiescence wait is bounded and succeeds after the active writer drains', async (t) => {
  const { paths } = await makeTestPaths(t);
  const entered = controlledPromise();
  const release = controlledPromise();
  const agent = new BackupAgent({
    paths,
    validateTarget: async () => {
      entered.resolve();
      await release.promise;
    },
  });

  const scan = agent.requestImmediateScan('startup');
  await entered.promise;
  const keepAlive = setInterval(() => {}, 1000);
  t.after(() => clearInterval(keepAlive));
  const startedAt = Date.now();
  assert.equal(await agent.stopAndAwaitQuiescence(5), false);
  assert.ok(Date.now() - startedAt < 250);
  release.resolve();
  await scan;

  assert.equal(await agent.stopAndAwaitQuiescence(1000), true);
});

test('stop between atomic session steps retains pending state and does not publish a complete seed', async (t) => {
  const { paths } = await makeTestPaths(t);
  const firstPath = path.join(paths.codexRoot, 'sessions', 'a-first.jsonl');
  const secondPath = path.join(paths.codexRoot, 'sessions', 'b-second.jsonl');
  await writeSessionFile(firstPath, [jsonLine({ role: 'user', content: 'first' })]);
  await writeSessionFile(secondPath, [jsonLine({ role: 'user', content: 'second' })]);
  const firstFinished = controlledPromise();
  const releaseFirst = controlledPromise();
  const agent = new BackupAgent({ paths });
  const processSessionFile = agent.processSessionFile.bind(agent);
  let processed = 0;
  agent.processSessionFile = async (...args) => {
    const result = await processSessionFile(...args);
    processed += 1;
    if (processed === 1) {
      firstFinished.resolve();
      await releaseFirst.promise;
    }
    return result;
  };

  const scan = agent.requestImmediateScan('startup');
  await firstFinished.promise;
  agent.stop();
  releaseFirst.resolve();
  await scan;

  const manifest = JSON.parse(await fs.readFile(paths.manifestPath, 'utf8'));
  assert.deepEqual(Object.keys(manifest.sessions), ['a-first']);
  const status = JSON.parse(await fs.readFile(paths.localStatusPath, 'utf8'));
  assert.equal(status.status, 'waiting');
  const pending = JSON.parse(await fs.readFile(paths.pendingSourcesPath, 'utf8'));
  assert.equal(pending.pending.length, 1);
  assert.equal(pending.pending[0].sourcePath, secondPath);
  assert.equal(await fileExists(paths.auditStatePath), false);
});

test('stopped agent preserves its interruption epoch and rejects later audit work', async (t) => {
  const { paths } = await makeTestPaths(t);
  let validations = 0;
  const agent = new BackupAgent({
    paths,
    validateTarget: async () => { validations += 1; },
  });

  agent.stop();
  const outcome = await agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001');

  assert.deepEqual(outcome, { outcome: 'interrupted', checked: 0, repaired: 0 });
  assert.equal(validations, 0);
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

test('two no-change timer ticks do not interrupt a running audit or queue backup work', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'timer-audit.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'steady' }).repeat(50000)]);
  const readStarted = controlledPromise();
  const releaseRead = controlledPromise();
  let paused = false;
  const auditor = new BackupIntegrityAuditor({
    paths,
    instrumentation: {
      didReadChunk: async () => {
        if (paused) return;
        paused = true;
        readStarted.resolve();
        await releaseRead.promise;
      },
    },
  });
  let bodyReads = 0;
  let targetStats = 0;
  let interruptionSignals = 0;
  const readSpy = spyOnAllCursorStoreReads();
  const transactionSpy = spyOnAllCursorStoreWriteTransactions();
  t.after(() => {
    readSpy.restore();
    transactionSpy.restore();
  });
  const agent = new BackupAgent({
    paths,
    now: () => now,
    instrumentation: {
      auditInterruptionSet: () => { interruptionSignals += 1; },
      sourceBodyRead: () => { bodyReads += 1; },
      targetStat: () => { targetStats += 1; },
    },
    integrityAuditorFactory: () => auditor,
  });
  t.after(() => agent.stop());
  await agent.performOneShotScan();
  await fs.writeFile(paths.auditStatePath, JSON.stringify({
    lastCompletedAt: new Date(now.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  }));
  readSpy.reset();
  transactionSpy.reset();
  bodyReads = 0;
  targetStats = 0;

  const audit = agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001');
  await readStarted.promise;
  readSpy.reset();
  const baselineSignals = interruptionSignals;
  const firstTick = agent.requestImmediateScan('timer');
  assert.equal(interruptionSignals, baselineSignals);
  await firstTick;
  assert.equal(interruptionSignals, baselineSignals);
  const secondTick = agent.requestImmediateScan('timer');
  assert.equal(interruptionSignals, baselineSignals);
  await secondTick;
  assert.equal(interruptionSignals, baselineSignals);
  const preflightReads = readSpy.calls;
  const preflightTransactions = transactionSpy.calls;
  const preflightBodyReads = bodyReads;
  const preflightTargetStats = targetStats;
  releaseRead.resolve();
  const outcome = await audit;
  await Promise.allSettled([firstTick, secondTick]);

  assert.equal(preflightReads, 0);
  assert.equal(preflightTransactions, 0);
  assert.equal(preflightBodyReads, 0);
  assert.equal(preflightTargetStats, 0);
  assert.deepEqual(outcome, { outcome: 'completed', checked: 1, repaired: 0 });
});

test('timer tick with a complete append interrupts audit and backs up the append', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'timer-append.jsonl');
  const initial = jsonLine({ role: 'user', content: 'steady' }).repeat(50000);
  const appended = jsonLine({ role: 'assistant', content: 'new during audit' });
  await writeSessionFile(sourcePath, [initial]);
  const readStarted = controlledPromise();
  const releaseRead = controlledPromise();
  let paused = false;
  const auditor = new BackupIntegrityAuditor({
    paths,
    instrumentation: {
      didReadChunk: async () => {
        if (paused) return;
        paused = true;
        readStarted.resolve();
        await releaseRead.promise;
      },
    },
  });
  let bodyReads = 0;
  let targetStats = 0;
  let interruptionSignals = 0;
  const readSpy = spyOnAllCursorStoreReads();
  const transactionSpy = spyOnAllCursorStoreWriteTransactions();
  t.after(() => {
    readSpy.restore();
    transactionSpy.restore();
  });
  const agent = new BackupAgent({
    paths,
    now: () => now,
    instrumentation: {
      auditInterruptionSet: () => { interruptionSignals += 1; },
      sourceBodyRead: () => { bodyReads += 1; },
      targetStat: () => { targetStats += 1; },
    },
    integrityAuditorFactory: () => auditor,
  });
  t.after(() => agent.stop());
  await agent.performOneShotScan();
  await fs.writeFile(paths.auditStatePath, JSON.stringify({
    lastCompletedAt: new Date(now.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  }));
  readSpy.reset();
  transactionSpy.reset();
  bodyReads = 0;
  targetStats = 0;

  const audit = agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001');
  await readStarted.promise;
  readSpy.reset();
  const baselineSignals = interruptionSignals;
  await fs.appendFile(sourcePath, appended);
  const tick = agent.requestImmediateScan('timer');
  await waitForCondition(() => interruptionSignals === baselineSignals + 1);

  assert.equal(readSpy.calls, 0);
  assert.equal(transactionSpy.calls, 0);
  assert.equal(bodyReads, 0);
  assert.equal(targetStats, 0);
  releaseRead.resolve();

  assert.deepEqual(await audit, { outcome: 'interrupted', checked: 0, repaired: 0 });
  await tick;
  assert.equal(transactionSpy.calls, 1);
  assert.ok((await fs.readFile(paths.backupFilePath(sourcePath), 'utf8')).endsWith(appended));
});

test('stop interrupts an active audit at the next chunk boundary without waiting for completion', async (t) => {
  const { paths } = await makeTestPaths(t);
  const now = new Date('2026-07-14T04:05:06.000Z');
  const sourcePath = path.join(paths.codexRoot, 'sessions', 'audit-shutdown.jsonl');
  await writeSessionFile(sourcePath, [jsonLine({ role: 'user', content: 'bulk' }).repeat(50000)]);
  await new BackupAgent({ paths, now: () => now }).performOneShotScan();
  const previousAudit = {
    lastCompletedAt: new Date(now.getTime() - 86401000).toISOString(),
    lastResult: 'previous',
    repairedCount: 0,
  };
  await fs.writeFile(paths.auditStatePath, JSON.stringify(previousAudit));
  const readStarted = controlledPromise();
  const releaseRead = controlledPromise();
  let paused = false;
  const auditor = new BackupIntegrityAuditor({
    paths,
    instrumentation: {
      didReadChunk: async () => {
        if (paused) return;
        paused = true;
        readStarted.resolve();
        await releaseRead.promise;
      },
    },
  });
  const agent = new BackupAgent({
    paths,
    now: () => now,
    integrityAuditorFactory: () => auditor,
  });

  const audit = agent.performIntegrityAuditIfDue('00000000-0000-0000-0000-000000000001');
  await readStarted.promise;
  agent.stop();
  releaseRead.resolve();

  assert.deepEqual(await audit, { outcome: 'interrupted', checked: 0, repaired: 0 });
  assert.deepEqual(JSON.parse(await fs.readFile(paths.auditStatePath, 'utf8')), previousAudit);
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

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { CursorStore } = require('../../src/backup/cursor-store');
const {
  BackupIntegrityAuditor,
  dailyOffsetSeconds,
  overdueWakeDelaySeconds,
} = require('../../src/backup/integrity-auditor');
const { backupPaths } = require('../../src/backup/paths');

const DEVICE_ID = '00000000-0000-0000-0000-000000000001';
const DUE_DATE = new Date('2026-07-14T04:05:06.000Z');

function jsonLine(value) {
  return `${JSON.stringify(value)}\n`;
}

function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function multiChunkJSONL() {
  const line = Buffer.from(jsonLine({ role: 'user', content: 'bounded-integrity-audit' }));
  return Buffer.concat(Array.from({ length: 50000 }, () => line));
}

async function exists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function writeJson(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

class IntegrityFixture {
  static async create(t, options = {}) {
    const fixture = new IntegrityFixture(t, options);
    await fixture.initialize();
    return fixture;
  }

  constructor(t, {
    committed = Buffer.from(jsonLine({ role: 'user', content: 'authoritative' })),
    localTail = Buffer.alloc(0),
    nasData = null,
    corrupted = false,
    cursorsEnabled = true,
    instrumentation = {},
    chunkSize = 1024 * 1024,
    name = 'fixture',
  } = {}) {
    this.t = t;
    this.committed = Buffer.from(committed);
    this.localTail = Buffer.from(localTail);
    this.nasData = nasData == null ? Buffer.from(committed) : Buffer.from(nasData);
    if (corrupted) this.nasData[0] ^= 0x01;
    this.originalNASData = Buffer.from(this.nasData);
    this.cursorsEnabled = cursorsEnabled;
    this.instrumentation = instrumentation;
    this.chunkSize = chunkSize;
    this.name = name;
    this.now = new Date(DUE_DATE);
    this.deviceId = DEVICE_ID;
    this.sessionId = 'session-a';
  }

  async initialize() {
    this.root = await fs.mkdtemp(path.join(os.tmpdir(), `windows-integrity-${this.name}-`));
    this.t.after(async () => fs.rm(this.root, { recursive: true, force: true }));
    const codexRoot = path.join(this.root, '.codex');
    const backupRoot = path.join(this.root, 'nas', 'device', 'incremental-backups');
    const stateRoot = path.join(this.root, 'local-state');
    this.paths = backupPaths({
      homeDir: this.root,
      codexRoot,
      backupRoot,
      stateRoot,
      pathImpl: path,
    });
    await fs.mkdir(this.paths.backupRoot, { recursive: true });
    await fs.mkdir(this.paths.stateRoot, { recursive: true });
    this.sourcePath = path.join(this.paths.codexRoot, 'sessions', `${this.sessionId}.jsonl`);
    this.targetPath = this.paths.backupFilePath(this.sourcePath);
    await fs.mkdir(path.dirname(this.sourcePath), { recursive: true });
    await fs.mkdir(path.dirname(this.targetPath), { recursive: true });
    await fs.writeFile(this.sourcePath, Buffer.concat([this.committed, this.localTail]));
    await fs.writeFile(this.targetPath, this.nasData);
    this.cursor = this.makeCursor();
    this.cursors = this.cursorsEnabled ? new Map([[this.sourcePath, this.cursor]]) : new Map();
    await this.writeManifest({
      version: 2,
      codexRoot: this.paths.codexRoot,
      backupRoot: this.paths.backupRoot,
      createdAt: new Date(this.now.getTime() - 100000000).toISOString(),
      updatedAt: new Date(this.now.getTime() - 100000000).toISOString(),
      sessions: this.cursorsEnabled ? { [this.sessionId]: this.makeRecord() } : {},
    });
    const store = new CursorStore({ paths: this.paths });
    await store.open();
    try {
      if (this.cursorsEnabled) await store.upsert(this.cursor);
    } finally {
      await store.close();
    }
    await this.writeAuditState({
      lastCompletedAt: new Date(this.now.getTime() - 86401000).toISOString(),
      lastResult: 'previous',
      repairedCount: 0,
    });
    this.auditor = this.makeAuditor({ instrumentation: this.instrumentation });
  }

  makeAuditor(overrides = {}) {
    return new BackupIntegrityAuditor({
      paths: this.paths,
      chunkSize: this.chunkSize,
      instrumentation: {},
      ...overrides,
    });
  }

  makeCursor(overrides = {}) {
    return {
      sessionId: this.sessionId,
      sourcePath: this.sourcePath,
      backupPath: path.join('sessions', `${this.sessionId}.jsonl`),
      lastByteOffset: this.committed.length,
      lastSourceSize: this.committed.length + this.localTail.length,
      lastSourceModifiedAt: 1770000000,
      lineCount: this.committed.toString('utf8').split('\n').length - 1,
      pendingPartialLine: this.localTail.toString('utf8'),
      status: 'active',
      lastError: null,
      updatedAt: (this.now.getTime() - 100000000) / 1000,
      ...overrides,
    };
  }

  makeRecord(overrides = {}) {
    return {
      sessionId: this.sessionId,
      sourcePath: this.sourcePath,
      backupPath: path.join('sessions', `${this.sessionId}.jsonl`),
      title: 'authoritative',
      firstSeenAt: new Date(this.now.getTime() - 100000000).toISOString(),
      lastBackedUpAt: new Date(this.now.getTime() - 100000000).toISOString(),
      lineCount: this.cursor?.lineCount ?? (this.committed.toString('utf8').split('\n').length - 1),
      bytesBackedUp: this.committed.length,
      contentHash: 'stale-hash',
      status: 'active',
      ...overrides,
    };
  }

  async run(interruptionRequested = () => false, overrides = {}) {
    return this.auditor.runIfDue({
      now: this.now,
      deviceId: this.deviceId,
      cursors: this.cursors,
      interruptionRequested,
      ...overrides,
    });
  }

  async writeManifest(manifest) {
    await writeJson(this.paths.manifestPath, manifest);
  }

  async loadManifest() {
    return readJson(this.paths.manifestPath);
  }

  async writeAuditState(state) {
    await writeJson(this.paths.auditStatePath, state);
  }

  async loadAuditState() {
    return readJson(this.paths.auditStatePath);
  }

  async writeStatus(overrides = {}) {
    const status = {
      agentVersion: '2.0.0',
      enabled: true,
      status: 'running',
      mode: 'polling',
      codexRoot: this.paths.codexRoot,
      backupRoot: this.paths.backupRoot,
      firstRunAt: new Date(this.now.getTime() - 100000000).toISOString(),
      lastStartedAt: new Date(this.now.getTime() - 100000000).toISOString(),
      lastHeartbeatAt: new Date(this.now.getTime() - 100000000).toISOString(),
      lastBackupAt: new Date(this.now.getTime() - 100000000).toISOString(),
      sessionCount: 1,
      lineCount: this.cursor.lineCount,
      bytesBackedUp: this.committed.length,
      autoStartEnabled: false,
      lastError: null,
      repairCount: 0,
      ...overrides,
    };
    await writeJson(this.paths.localStatusPath, status);
    await writeJson(this.paths.remoteStatusPath, status);
  }

  get pendingRepairPath() {
    return path.join(this.paths.stateRoot, 'integrity-repair-pending.json');
  }

  async loadCursor() {
    const store = new CursorStore({ paths: this.paths });
    await store.open();
    try {
      return await store.get(this.sourcePath);
    } finally {
      await store.close();
    }
  }

  async saveCursor(cursor) {
    const store = new CursorStore({ paths: this.paths });
    await store.open();
    try {
      await store.upsert(cursor);
    } finally {
      await store.close();
    }
  }

  async quarantineCopies(sessionId = this.sessionId) {
    const safe = safeComponent(sessionId);
    const directory = path.join(this.paths.repairQuarantineRoot, safe);
    let names;
    try {
      names = await fs.readdir(directory);
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
    const copies = [];
    const ownedPattern = new RegExp(`^repair-${safe}-\\d+-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\\.jsonl$`, 'i');
    for (const name of names.filter((value) => ownedPattern.test(value)).sort()) {
      const filePath = path.join(directory, name);
      const stats = await fs.lstat(filePath);
      if (stats.isFile() && !stats.isSymbolicLink()) {
        copies.push({ filePath, data: await fs.readFile(filePath), stats });
      }
    }
    return copies;
  }

  async seedRetentionCopies(sessionId = this.sessionId, days = [40, 20, 10, 5, 1]) {
    const safe = safeComponent(sessionId);
    const directory = path.join(this.paths.repairQuarantineRoot, safe);
    await fs.mkdir(directory, { recursive: true });
    const owned = [];
    for (let index = 0; index < days.length; index += 1) {
      const day = days[index];
      const date = new Date(this.now.getTime() - day * 86400000);
      const uuid = `00000000-0000-0000-0000-${String(index + 1).padStart(12, '0')}`;
      const filePath = path.join(directory, `repair-${safe}-${day}-${uuid}.jsonl`);
      await fs.writeFile(filePath, `copy-${day}`);
      await fs.utimes(filePath, date, date);
      owned.push({ filePath, date });
    }
    const unrelated = path.join(directory, 'notes.txt');
    await fs.writeFile(unrelated, 'keep');
    const matchingButUnowned = path.join(directory, `repair-${safe}-application-owned-no.jsonl`);
    await fs.writeFile(matchingButUnowned, 'keep-too');
    const formal = path.join(this.paths.sessionsRoot, 'formal.jsonl');
    await fs.mkdir(path.dirname(formal), { recursive: true });
    await fs.writeFile(formal, 'formal');
    return { owned, unrelated, matchingButUnowned, formal };
  }

  async addSession(sessionId, committed, nasData = committed) {
    const sourcePath = path.join(this.paths.codexRoot, 'sessions', `${sessionId}.jsonl`);
    const targetPath = this.paths.backupFilePath(sourcePath);
    await fs.mkdir(path.dirname(sourcePath), { recursive: true });
    await fs.mkdir(path.dirname(targetPath), { recursive: true });
    await fs.writeFile(sourcePath, committed);
    await fs.writeFile(targetPath, nasData);
    const relative = path.join('sessions', `${sessionId}.jsonl`);
    const cursor = this.makeCursor({
      sessionId,
      sourcePath,
      backupPath: relative,
      lastByteOffset: committed.length,
      lastSourceSize: committed.length,
      lineCount: committed.toString('utf8').split('\n').length - 1,
      pendingPartialLine: '',
    });
    this.cursors.set(sourcePath, cursor);
    const manifest = await this.loadManifest();
    manifest.sessions[sessionId] = this.makeRecord({
      sessionId,
      sourcePath,
      backupPath: relative,
      bytesBackedUp: committed.length,
      lineCount: cursor.lineCount,
    });
    await this.writeManifest(manifest);
    await this.saveCursor(cursor);
    return { sourcePath, targetPath, cursor };
  }
}

function safeComponent(value) {
  return String(value).replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'session';
}

test('deterministic schedule matches the shared cross-platform SHA-256 vector', () => {
  assert.equal(dailyOffsetSeconds(DEVICE_ID), 38733);
  assert.equal(overdueWakeDelaySeconds(DEVICE_ID), 676);
  assert.equal(dailyOffsetSeconds(DEVICE_ID.toUpperCase()), 38733);
});

test('deterministic schedule values stay inside the daily and overdue ranges', () => {
  for (let value = 0; value < 256; value += 1) {
    const deviceId = `00000000-0000-0000-0000-${value.toString(16).padStart(12, '0')}`;
    assert.ok(dailyOffsetSeconds(deviceId) >= 0 && dailyOffsetSeconds(deviceId) < 86400);
    assert.ok(overdueWakeDelaySeconds(deviceId) >= 0 && overdueWakeDelaySeconds(deviceId) <= 1800);
  }
});

test('completed audit less than twenty-four hours ago is not due', async (t) => {
  const fixture = await IntegrityFixture.create(t);
  await fixture.writeAuditState({
    lastCompletedAt: new Date(fixture.now.getTime() - 86399000).toISOString(),
    lastResult: 'completed',
    repairedCount: 0,
  });

  assert.deepEqual(await fixture.run(), { outcome: 'not-due', checked: 0, repaired: 0 });
});

test('equal multi-chunk audit stops at the committed offset and ignores a partial tail', async (t) => {
  const committed = multiChunkJSONL();
  const fixture = await IntegrityFixture.create(t, {
    committed,
    localTail: Buffer.from('partial-local-tail'),
    nasData: committed,
  });

  assert.deepEqual(await fixture.run(), { outcome: 'completed', checked: 1, repaired: 0 });
  assert.deepEqual(await fs.readFile(fixture.targetPath), committed);
  assert.equal((await fixture.loadManifest()).sessions[fixture.sessionId].contentHash, sha256(committed));
  assert.equal((await fixture.loadAuditState()).lastCompletedAt, fixture.now.toISOString());
});

test('corruption in every bounded chunk is detected and repaired', async (t) => {
  const committed = multiChunkJSONL();
  for (let chunkIndex = 0; chunkIndex < 3; chunkIndex += 1) {
    const corrupted = Buffer.from(committed);
    corrupted[Math.min(corrupted.length - 2, chunkIndex * 1024 * 1024 + 17)] ^= 0x01;
    const fixture = await IntegrityFixture.create(t, {
      committed,
      nasData: corrupted,
      name: `chunk-${chunkIndex}`,
    });
    assert.deepEqual(await fixture.run(), { outcome: 'completed', checked: 1, repaired: 1 });
    assert.deepEqual(await fs.readFile(fixture.targetPath), committed);
  }
});

test('interruption discards buffered state and restarts the file at byte zero', async (t) => {
  const offsets = [];
  const fixture = await IntegrityFixture.create(t, {
    committed: multiChunkJSONL(),
    instrumentation: { didReadChunk: (_filePath, offset) => offsets.push(offset) },
  });
  const beforeManifest = await fixture.loadManifest();
  const beforeState = await fixture.loadAuditState();

  assert.deepEqual(
    await fixture.run(() => offsets.length > 0),
    { outcome: 'interrupted', checked: 0, repaired: 0 },
  );
  assert.deepEqual(offsets, [0]);
  assert.deepEqual(await fixture.loadManifest(), beforeManifest);
  assert.deepEqual(await fixture.loadAuditState(), beforeState);

  offsets.length = 0;
  assert.deepEqual(await fixture.run(), { outcome: 'completed', checked: 1, repaired: 0 });
  assert.equal(offsets[0], 0);
});

for (const interruptedPhase of ['repairTemporary', 'repairTemporaryVerification', 'quarantineCopy']) {
  test(`interruption during ${interruptedPhase} leaves the formal target untouched`, async (t) => {
    const observations = [];
    const committed = multiChunkJSONL();
    const corrupted = Buffer.from(committed);
    corrupted[0] ^= 0x01;
    const fixture = await IntegrityFixture.create(t, {
      committed,
      nasData: corrupted,
      instrumentation: {
        didStreamChunk: (phase, _filePath, offset) => observations.push({ phase, offset }),
      },
    });
    const beforeManifest = await fixture.loadManifest();
    const beforeState = await fixture.loadAuditState();

    assert.deepEqual(
      await fixture.run(() => observations.some(({ phase }) => phase === interruptedPhase)),
      { outcome: 'interrupted', checked: 0, repaired: 0 },
    );
    assert.deepEqual(
      observations.filter(({ phase }) => phase === interruptedPhase).map(({ offset }) => offset),
      [0],
    );
    assert.deepEqual(await fs.readFile(fixture.targetPath), corrupted);
    assert.deepEqual(await fixture.loadManifest(), beforeManifest);
    assert.deepEqual(await fixture.loadAuditState(), beforeState);
    if (interruptedPhase !== 'quarantineCopy') assert.equal((await fixture.quarantineCopies()).length, 0);
  });
}

test('interruption during installed verification rolls back from verified quarantine', async (t) => {
  const observations = [];
  const fixture = await IntegrityFixture.create(t, {
    committed: multiChunkJSONL(),
    corrupted: true,
    instrumentation: {
      didStreamChunk: (phase, _filePath, offset) => observations.push({ phase, offset }),
    },
  });
  const beforeManifest = await fixture.loadManifest();
  const beforeState = await fixture.loadAuditState();

  assert.deepEqual(
    await fixture.run(() => observations.some(({ phase }) => phase === 'installedVerification')),
    { outcome: 'interrupted', checked: 0, repaired: 0 },
  );
  assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
  assert.deepEqual((await fixture.quarantineCopies())[0].data, fixture.originalNASData);
  assert.deepEqual(await fixture.loadManifest(), beforeManifest);
  assert.deepEqual(await fixture.loadAuditState(), beforeState);
  assert.equal(await exists(fixture.pendingRepairPath), false);
  assert.equal((await fs.readdir(path.dirname(fixture.targetPath))).some((name) => name.includes('.repair-')), false);
});

test('successful repair quarantines old bytes before replacement and commits accounting', async (t) => {
  const order = [];
  const fixture = await IntegrityFixture.create(t, {
    corrupted: true,
    instrumentation: { checkpoint: (value) => order.push(value) },
  });
  await fixture.writeStatus();

  assert.deepEqual(await fixture.run(), { outcome: 'completed', checked: 1, repaired: 1 });
  assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.committed);
  assert.deepEqual((await fixture.quarantineCopies())[0].data, fixture.originalNASData);
  assert.ok(order.indexOf('beforeQuarantineCopy') < order.indexOf('beforeReplace'));
  assert.equal((await fixture.loadManifest()).version, 2);
  assert.equal((await fixture.loadAuditState()).repairedCount, 1);
  const status = await readJson(fixture.paths.localStatusPath);
  assert.equal(status.repairCount, 1);
  assert.equal(status.lastRepairAt, fixture.now.toISOString());
});

test('prepared repair journal flush failure leaves formal target untouched', async (t) => {
  const injected = new Error('prepared journal flush failed');
  const fixture = await IntegrityFixture.create(t, {
    corrupted: true,
    instrumentation: {
      checkpoint: (value) => {
        if (value === 'beforePreparedRepairJournalFlush') throw injected;
      },
    },
  });
  const beforeManifest = await fixture.loadManifest();
  const beforeState = await fixture.loadAuditState();

  await assert.rejects(fixture.run(), injected);
  assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
  assert.equal(await exists(fixture.pendingRepairPath), false);
  assert.deepEqual(await fixture.loadManifest(), beforeManifest);
  assert.deepEqual(await fixture.loadAuditState(), beforeState);
  assert.equal((await fs.readdir(path.dirname(fixture.targetPath))).some((name) => name.includes('.repair-')), false);
});

test('prepared journal with original formal bytes recovers without repair accounting', async (t) => {
  const injected = new Error('crash before replace');
  const fixture = await IntegrityFixture.create(t, {
    corrupted: true,
    instrumentation: {
      checkpoint: (value) => {
        if (value === 'afterPreparedJournalCommitBeforeFormalReplace') throw injected;
      },
    },
  });
  const beforeManifest = await fixture.loadManifest();

  await assert.rejects(fixture.run(), injected);
  assert.equal((await readJson(fixture.pendingRepairPath)).phase, 'prepared');
  assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
  assert.equal((await fs.readdir(path.dirname(fixture.targetPath))).some((name) => name.includes('.repair-')), false);
  await fixture.writeAuditState({
    lastCompletedAt: fixture.now.toISOString(),
    lastResult: 'completed',
    repairedCount: 0,
  });
  assert.deepEqual(
    await fixture.makeAuditor().runIfDue({
      now: fixture.now,
      deviceId: fixture.deviceId,
      cursors: fixture.cursors,
      interruptionRequested: () => false,
    }),
    { outcome: 'not-due', checked: 0, repaired: 0 },
  );
  assert.equal(await exists(fixture.pendingRepairPath), false);
  assert.deepEqual(await fixture.loadManifest(), beforeManifest);
  assert.equal((await fixture.loadAuditState()).repairedCount, 0);
});

test('prepared journal with repaired formal bytes replays repair accounting exactly once', async (t) => {
  const injected = new Error('crash after replace');
  const fixture = await IntegrityFixture.create(t, {
    corrupted: true,
    instrumentation: {
      checkpoint: (value) => {
        if (value === 'afterFormalReplaceBeforeInstalledJournalCommit') throw injected;
      },
    },
  });
  await fixture.writeStatus();

  await assert.rejects(fixture.run(), injected);
  assert.equal((await readJson(fixture.pendingRepairPath)).phase, 'prepared');
  assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.committed);

  const recovered = fixture.makeAuditor();
  assert.deepEqual(
    await recovered.runIfDue({
      now: fixture.now,
      deviceId: fixture.deviceId,
      cursors: fixture.cursors,
      interruptionRequested: () => false,
    }),
    { outcome: 'completed', checked: 1, repaired: 0 },
  );
  assert.equal(await exists(fixture.pendingRepairPath), false);
  assert.equal((await fixture.loadAuditState()).repairedCount, 1);
  assert.equal((await readJson(fixture.paths.localStatusPath)).repairCount, 1);

  assert.deepEqual(
    await recovered.runIfDue({
      now: new Date(fixture.now.getTime() + 1000),
      deviceId: fixture.deviceId,
      cursors: fixture.cursors,
      interruptionRequested: () => false,
    }),
    { outcome: 'not-due', checked: 0, repaired: 0 },
  );
  assert.equal((await fixture.loadAuditState()).repairedCount, 1);
});

for (const checkpoint of [
  'beforeTemporaryFlush',
  'beforeQuarantineCopy',
  'beforeReplace',
  'beforePostReplaceVerification',
  'beforeMetadataCommit',
]) {
  test(`repair failure at ${checkpoint} preserves its durability boundary`, async (t) => {
    const injected = new Error(`injected ${checkpoint}`);
    const fixture = await IntegrityFixture.create(t, {
      corrupted: true,
      instrumentation: {
        checkpoint: (value) => {
          if (value === checkpoint) throw injected;
        },
      },
    });
    const beforeManifest = await fixture.loadManifest();
    const beforeState = await fixture.loadAuditState();

    await assert.rejects(fixture.run(), injected);
    assert.deepEqual(
      await fs.readFile(fixture.targetPath),
      checkpoint === 'beforeMetadataCommit' ? fixture.committed : fixture.originalNASData,
    );
    assert.deepEqual(await fixture.loadManifest(), beforeManifest);
    assert.deepEqual(await fixture.loadAuditState(), beforeState);
    const copies = await fixture.quarantineCopies();
    assert.equal(copies.length, ['beforeTemporaryFlush', 'beforeQuarantineCopy'].includes(checkpoint) ? 0 : 1);
  });
}

for (const checkpoint of [
  'afterManifestCommit',
  'afterCursorCommit',
  'afterAuditStateCommit',
  'afterRuntimeStatusCommit',
]) {
  test(`metadata crash at ${checkpoint} is reconciled idempotently`, async (t) => {
    const injected = new Error(`injected ${checkpoint}`);
    const fixture = await IntegrityFixture.create(t, {
      corrupted: true,
      instrumentation: {
        checkpoint: (value) => {
          if (value === checkpoint) throw injected;
        },
      },
    });
    await fixture.writeStatus();

    await assert.rejects(fixture.run(), injected);
    assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.committed);
    assert.equal(await exists(fixture.pendingRepairPath), true);
    assert.equal((await fixture.loadManifest()).version, 2);

    assert.deepEqual(
      await fixture.makeAuditor().runIfDue({
        now: fixture.now,
        deviceId: fixture.deviceId,
        cursors: fixture.cursors,
        interruptionRequested: () => false,
      }),
      { outcome: 'completed', checked: 1, repaired: 0 },
    );
    assert.equal(await exists(fixture.pendingRepairPath), false);
    assert.equal((await fixture.loadAuditState()).repairedCount, 1);
    assert.equal((await readJson(fixture.paths.localStatusPath)).repairCount, 1);
    assert.equal((await readJson(fixture.paths.localStatusPath)).lastRepairAt, fixture.now.toISOString());
  });
}

test('pending repair replay preserves newer incremental manifest and cursor metadata', async (t) => {
  const injected = new Error('crash after manifest');
  const fixture = await IntegrityFixture.create(t, {
    corrupted: true,
    instrumentation: {
      checkpoint: (value) => {
        if (value === 'afterManifestCommit') throw injected;
      },
    },
  });
  await fixture.writeStatus();
  await assert.rejects(fixture.run(), injected);

  const newerDate = new Date(fixture.now.getTime() + 100000);
  const manifest = await fixture.loadManifest();
  const newerRecord = {
    ...manifest.sessions[fixture.sessionId],
    bytesBackedUp: manifest.sessions[fixture.sessionId].bytesBackedUp + 10,
    contentHash: 'newer-incremental-hash',
    lastBackedUpAt: newerDate.toISOString(),
  };
  manifest.sessions[fixture.sessionId] = newerRecord;
  manifest.updatedAt = newerDate.toISOString();
  await fixture.writeManifest(manifest);
  const cursor = await fixture.loadCursor();
  const newerCursor = {
    ...cursor,
    lastByteOffset: cursor.lastByteOffset + 10,
    updatedAt: newerDate.getTime() / 1000,
  };
  await fixture.saveCursor(newerCursor);
  await fixture.writeAuditState({
    lastCompletedAt: newerDate.toISOString(),
    lastResult: 'completed',
    repairedCount: 0,
  });

  assert.deepEqual(
    await fixture.makeAuditor().runIfDue({
      now: newerDate,
      deviceId: fixture.deviceId,
      cursors: fixture.cursors,
      interruptionRequested: () => false,
    }),
    { outcome: 'not-due', checked: 0, repaired: 0 },
  );
  assert.deepEqual((await fixture.loadManifest()).sessions[fixture.sessionId], newerRecord);
  assert.deepEqual(await fixture.loadCursor(), newerCursor);
  assert.equal((await fixture.loadAuditState()).repairedCount, 1);
  assert.equal((await readJson(fixture.paths.localStatusPath)).lastRepairAt, fixture.now.toISOString());
});

for (const unsafeBackupPath of [
  '\\\\server\\share\\session-a.jsonl',
  '\\\\?\\C:\\session-a.jsonl',
  'C:\\device\\session-a.jsonl',
  'sessions\\session-a.jsonl:alternate',
]) {
  test(`unsafe Windows cursor path ${JSON.stringify(unsafeBackupPath)} never overwrites NAS`, async (t) => {
    const fixture = await IntegrityFixture.create(t, { corrupted: true });
    fixture.cursor = fixture.makeCursor({ backupPath: unsafeBackupPath });
    fixture.cursors = new Map([[fixture.sourcePath, fixture.cursor]]);
    const manifest = await fixture.loadManifest();
    manifest.sessions[fixture.sessionId].backupPath = unsafeBackupPath;
    await fixture.writeManifest(manifest);

    await assert.rejects(fixture.run(), /unsafe|path|cursor/i);
    assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
  });
}

test('junction or symlink escape in the NAS target path is rejected', async (t) => {
  const fixture = await IntegrityFixture.create(t, { corrupted: true });
  const outside = path.join(fixture.root, 'outside');
  const outsideTarget = path.join(outside, `${fixture.sessionId}.jsonl`);
  await fs.mkdir(outside);
  await fs.writeFile(outsideTarget, fixture.originalNASData);
  await fs.rm(fixture.paths.sessionsRoot, { recursive: true, force: true });
  await fs.symlink(outside, fixture.paths.sessionsRoot, process.platform === 'win32' ? 'junction' : 'dir');

  await assert.rejects(fixture.run(), /unsafe|link|path/i);
  assert.deepEqual(await fs.readFile(outsideTarget), fixture.originalNASData);
});

test('missing, linked, escaped, and non-regular local sources never overwrite NAS', async (t) => {
  const cases = ['missing', 'linked', 'escaped', 'non-regular'];
  for (const sourceCase of cases) {
    const fixture = await IntegrityFixture.create(t, { corrupted: true, name: sourceCase });
    if (sourceCase === 'missing') {
      await fs.rm(fixture.sourcePath);
    } else if (sourceCase === 'linked') {
      const outside = path.join(fixture.root, 'linked-source.jsonl');
      await fs.writeFile(outside, fixture.committed);
      await fs.rm(fixture.sourcePath);
      await fs.symlink(outside, fixture.sourcePath);
    } else if (sourceCase === 'escaped') {
      const escaped = path.join(fixture.root, 'escaped.jsonl');
      await fs.writeFile(escaped, fixture.committed);
      fixture.cursor = fixture.makeCursor({ sourcePath: escaped });
      fixture.cursors = new Map([[escaped, fixture.cursor]]);
      const manifest = await fixture.loadManifest();
      manifest.sessions[fixture.sessionId].sourcePath = escaped;
      await fixture.writeManifest(manifest);
    } else {
      await fs.rm(fixture.sourcePath);
      await fs.mkdir(fixture.sourcePath);
    }

    await assert.rejects(fixture.run(), /unsafe|source|path|file|ENOENT/i);
    assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
  }
});

test('structurally invalid committed JSONL never overwrites the formal NAS target', async (t) => {
  const fixture = await IntegrityFixture.create(t, {
    committed: Buffer.from('not-json\n'),
    nasData: Buffer.from('bad-json\n'),
  });

  await assert.rejects(fixture.run(), /invalid|JSONL|JSON/i);
  assert.deepEqual(await fs.readFile(fixture.targetPath), Buffer.from('bad-json\n'));
  assert.equal((await fixture.quarantineCopies()).length, 0);
});

test('invalid UTF-8 in committed JSONL never overwrites the formal NAS target', async (t) => {
  const committed = Buffer.concat([
    Buffer.from('{"value":"'),
    Buffer.from([0xFF]),
    Buffer.from('"}\n'),
  ]);
  const target = Buffer.from('{"value":"different"}\n');
  const fixture = await IntegrityFixture.create(t, { committed, nasData: target });

  await assert.rejects(fixture.run(), /invalid|JSONL|UTF/i);
  assert.deepEqual(await fs.readFile(fixture.targetPath), target);
  assert.equal((await fixture.quarantineCopies()).length, 0);
});

test('failed final status publication does not advance authoritative audit completion state', async (t) => {
  const fixture = await IntegrityFixture.create(t);
  await fixture.writeStatus();
  const stateBefore = await fixture.loadAuditState();
  const originalRename = fs.rename;
  fs.rename = async (source, destination) => {
    if (destination === fixture.paths.remoteStatusPath) throw new Error('injected remote status failure');
    return originalRename.call(fs, source, destination);
  };
  try {
    await assert.rejects(fixture.run(), /injected remote status failure/);
  } finally {
    fs.rename = originalRename;
  }

  assert.deepEqual(await fixture.loadAuditState(), stateBefore);
});

for (const targetState of ['missing', 'unknown']) {
  test(`prepared repair recovery restores verified quarantine when formal target is ${targetState}`, async (t) => {
    const injected = new Error('crash after formal replace');
    const fixture = await IntegrityFixture.create(t, {
      corrupted: true,
      instrumentation: {
        checkpoint: (value) => {
          if (value === 'afterFormalReplaceBeforeInstalledJournalCommit') throw injected;
        },
      },
    });
    await assert.rejects(fixture.run(), injected);
    if (targetState === 'missing') {
      await fs.rm(fixture.targetPath);
    } else {
      await fs.writeFile(fixture.targetPath, Buffer.from('unknown-target\n'));
    }

    await fixture.makeAuditor().recoverPendingRepairIfNeeded({ now: fixture.now });

    assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
    assert.equal((await fixture.loadAuditState()).repairedCount, 0);
    assert.equal(await exists(fixture.pendingRepairPath), false);
  });
}

test('retention expires old copies, caps newest three, and preserves unrelated paths', async (t) => {
  const fixture = await IntegrityFixture.create(t, { cursorsEnabled: false });
  const retention = await fixture.seedRetentionCopies();
  const link = path.join(path.dirname(retention.unrelated), `repair-${fixture.sessionId}-link.jsonl`);
  await fs.symlink(retention.unrelated, link);
  const unrelatedNAS = path.join(fixture.paths.backupRoot, 'other-device-data.bin');
  await fs.writeFile(unrelatedNAS, 'other');

  assert.deepEqual(await fixture.run(), { outcome: 'completed', checked: 0, repaired: 0 });
  const retained = [];
  for (const copy of retention.owned) if (await exists(copy.filePath)) retained.push(copy);
  assert.deepEqual(retained.map(({ date }) => date.toISOString()), retention.owned.slice(-3).map(({ date }) => date.toISOString()));
  assert.equal(await exists(retention.unrelated), true);
  assert.equal(await exists(retention.matchingButUnowned), true);
  assert.equal(await exists(link), true);
  assert.equal(await fs.readFile(retention.formal, 'utf8'), 'formal');
  assert.equal(await fs.readFile(unrelatedNAS, 'utf8'), 'other');
});

for (const phase of ['quarantineVerification', 'formalPreReplacementVerification']) {
  test(`new quarantine enforces newest-three retention before ${phase} interruption`, async (t) => {
    const observations = [];
    const fixture = await IntegrityFixture.create(t, {
      committed: multiChunkJSONL(),
      corrupted: true,
      instrumentation: {
        didStreamChunk: (observed, _filePath, offset) => observations.push({ phase: observed, offset }),
      },
    });
    const retention = await fixture.seedRetentionCopies(fixture.sessionId, [3, 2, 1]);

    assert.deepEqual(
      await fixture.run(() => observations.some(({ phase: observed }) => observed === phase)),
      { outcome: 'interrupted', checked: 0, repaired: 0 },
    );
    assert.equal((await fixture.quarantineCopies()).length, 3);
    assert.equal(await exists(retention.owned[0].filePath), false);
    assert.deepEqual(await fs.readFile(fixture.targetPath), fixture.originalNASData);
    assert.equal(await exists(retention.unrelated), true);
  });
}

test('verified repair enforces retention even when a later file interrupts the audit', async (t) => {
  const observations = [];
  const fixture = await IntegrityFixture.create(t, {
    cursorsEnabled: false,
    instrumentation: {
      didStreamChunk: (phase, filePath, offset) => {
        if (path.basename(filePath) === 'z-later.jsonl') observations.push({ phase, offset });
      },
    },
  });
  const repaired = Buffer.from(jsonLine({ role: 'user', content: 'repair-me' }));
  const corrupted = Buffer.from(repaired);
  corrupted[0] ^= 0x01;
  const first = await fixture.addSession('a-repair', repaired, corrupted);
  const later = multiChunkJSONL();
  await fixture.addSession('z-later', later, later);
  const retention = await fixture.seedRetentionCopies('a-repair');

  const outcome = await fixture.run(() => observations.some(({ phase }) => phase === 'comparison'));
  assert.equal(outcome.outcome, 'interrupted');
  assert.deepEqual(await fs.readFile(first.targetPath), repaired);
  assert.equal((await fixture.loadManifest()).sessions['a-repair'].contentHash, sha256(repaired));
  assert.equal((await fixture.loadAuditState()).repairedCount, 1);
  assert.notEqual((await fixture.loadAuditState()).lastCompletedAt, fixture.now.toISOString());
  assert.ok((await fixture.quarantineCopies('a-repair')).length <= 3);
  for (const copy of retention.owned) {
    if (await exists(copy.filePath)) assert.ok(fixture.now - copy.date <= 30 * 86400000);
  }
  assert.equal(await exists(retention.unrelated), true);
});

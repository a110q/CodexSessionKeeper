'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
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
const {
  emptyVerificationDocument,
  loadVerification,
  saveVerification,
} = require('../../src/backup/verification-store');
const { verifyFullBackupFile } = require('../../src/backup/backup-file-verifier');

const VERIFICATION_CHUNK_SIZE = 4 * 1024 * 1024;

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'incremental-recovery-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const paths = {
    codexRoot: path.join(root, '.codex'),
    backupRoot: path.join(root, 'nas', 'incremental-backups'),
    manifestPath: path.join(root, 'nas', 'incremental-backups', 'manifest.json'),
    verificationPath: path.join(root, 'nas', 'incremental-backups', 'verification.json'),
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
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, bytes);
  const verification = fsSync.existsSync(paths.verificationPath)
    ? await loadVerification(paths.verificationPath)
    : emptyVerificationDocument();
  const chunkHashes = [];
  for (let offset = 0; offset < bytes.length; offset += verification.chunkSize) {
    chunkHashes.push(crypto.createHash('sha256')
      .update(bytes.subarray(offset, offset + verification.chunkSize))
      .digest('hex'));
  }
  verification.sessions[sessionId] = {
    backupPath,
    byteCount: bytes.length,
    lineCount: bytes.reduce((count, byte) => count + (byte === 0x0A ? 1 : 0), 0),
    chunkHashes,
    verifiedAt: '2026-07-08T12:05:00.000Z',
  };
  await saveVerification(paths.verificationPath, verification);
  return {
    ...record(sessionId, backupPath, `${sessionId} title`),
    lineCount: verification.sessions[sessionId].lineCount,
    bytesBackedUp: bytes.length,
    contentHash: crypto.createHash('sha256').update(bytes).digest('hex'),
  };
}

async function withTrackedSourceReadSizes(filePath, operation) {
  const originalOpen = fs.open;
  const readSizes = [];
  const canonicalFilePath = fsSync.realpathSync.native(filePath);
  fs.open = async function (openedPath, ...args) {
    const handle = await originalOpen.call(fs, openedPath, ...args);
    if (path.resolve(String(openedPath)) === path.resolve(canonicalFilePath)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (buffer, offset, length, position) => {
        readSizes.push(length);
        return originalRead(buffer, offset, length, position);
      };
    }
    return handle;
  };
  try {
    return { result: await operation(), readSizes };
  } finally {
    fs.open = originalOpen;
  }
}

function multiChunkJSONL(minimumBytes) {
  const record = `${JSON.stringify({ role: 'user', content: 'x'.repeat(64 * 1024) })}\n`;
  return Buffer.from(record.repeat(Math.ceil(minimumBytes / Buffer.byteLength(record))));
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

test('restore streams a file larger than three verification chunks', async (t) => {
  const { paths } = await makeFixture(t);
  const content = multiChunkJSONL(VERIFICATION_CHUNK_SIZE * 3 + 17);
  const selected = await addBackup(paths, 'multi-chunk', content);
  await writeManifest(paths, { 'multi-chunk': selected });
  const sourcePath = path.join(paths.backupRoot, selected.backupPath);

  const { result, readSizes } = await withTrackedSourceReadSizes(sourcePath, async () => {
    const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['multi-chunk'] });
    return restoreIncrementalSessions({ paths, preflight });
  });

  const recoveredPath = result.recoveredFiles['multi-chunk'];
  const restored = await verifyFullBackupFile({
    filePath: recoveredPath,
    expectedByteCount: content.length,
    expectedLineCount: selected.lineCount,
    expectedContentHash: selected.contentHash,
  });
  assert.ok(restored.chunkHashes.length > 3);
  assert.ok(readSizes.length > 3);
  assert.ok(readSizes.every((size) => size > 0 && size <= VERIFICATION_CHUNK_SIZE));
});

test('restore revalidates every preflight source and never overwrites a destination', async (t) => {
  const { root, paths } = await makeFixture(t);
  const safeContent = '{"role":"user","content":"safe"}\n';
  const selected = await addBackup(paths, 'selected', safeContent);
  await writeManifest(paths, { selected });
  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['selected'] });
  const sourceRoot = path.join(paths.backupRoot, 'sessions');
  const outsideRoot = path.join(root, 'outside');
  await fs.mkdir(outsideRoot);
  await fs.writeFile(path.join(outsideRoot, 'selected.jsonl'), '{"role":"user","content":"outside"}\n');
  await fs.rm(sourceRoot, { recursive: true });
  await fs.symlink(outsideRoot, sourceRoot, process.platform === 'win32' ? 'junction' : 'dir');

  await assert.rejects(
    restoreIncrementalSessions({ paths, preflight }),
    (error) => error.code === 'INVALID_SNAPSHOT_PATH',
  );
  assert.equal(fsSync.existsSync(path.join(paths.codexRoot, 'sessions', 'recovered')), false);

  await fs.rm(sourceRoot, { force: true });
  await fs.mkdir(path.dirname(preflight[0].sourcePath), { recursive: true });
  await fs.writeFile(preflight[0].sourcePath, safeContent);
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

test('preflight rejects same-length tampering and legacy backups without a trusted hash', async (t) => {
  const { paths } = await makeFixture(t);
  const original = '{"role":"user","content":"safe-data"}\n';
  const tampered = '{"role":"user","content":"evil-data"}\n';
  const tamperedRecord = await addBackup(paths, 'tampered', original);
  await writeManifest(paths, { tampered: tamperedRecord });
  await fs.writeFile(path.join(paths.backupRoot, tamperedRecord.backupPath), tampered);

  await assert.rejects(preflightIncrementalRecovery({ paths, sessionIds: ['tampered'] }));

  const untrusted = await addBackup(paths, 'untrusted', '{"role":"user","content":"legacy"}\n');
  const verification = await loadVerification(paths.verificationPath);
  delete verification.sessions.untrusted;
  await saveVerification(paths.verificationPath, verification);
  delete untrusted.contentHash;
  await writeManifest(paths, { untrusted });
  await assert.rejects(preflightIncrementalRecovery({ paths, sessionIds: ['untrusted'] }));
});

test('legacy contentHash backup remains restorable without verification sidecar', async (t) => {
  const { paths } = await makeFixture(t);
  const legacy = await addBackup(paths, 'legacy', '{"role":"user","content":"trusted"}\n');
  const verification = await loadVerification(paths.verificationPath);
  delete verification.sessions.legacy;
  await saveVerification(paths.verificationPath, verification);
  await writeManifest(paths, { legacy });

  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['legacy'] });
  const result = await restoreIncrementalSessions({ paths, preflight });

  assert.equal(result.recoveredFiles.legacy, path.join(paths.codexRoot, 'sessions', 'recovered', 'legacy.jsonl'));
});

test('fresh computer without .codex restores only after preflight succeeds', async (t) => {
  const { paths } = await makeFixture(t);
  const fresh = await addBackup(paths, 'fresh', '{"role":"user","content":"fresh"}\n');
  await writeManifest(paths, { fresh });
  await fs.rm(paths.codexRoot, { recursive: true, force: true });

  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['fresh'] });
  assert.equal(fsSync.existsSync(paths.codexRoot), false);
  const result = await restoreIncrementalSessions({ paths, preflight });

  assert.equal(fsSync.existsSync(result.recoveredFiles.fresh), true);
});

test('staging verification rejects same-path source replacement after preflight', async (t) => {
  const { paths } = await makeFixture(t);
  const replaced = await addBackup(paths, 'replaced', '{"role":"user","content":"original"}\n');
  await writeManifest(paths, { replaced });
  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['replaced'] });
  await fs.writeFile(
    path.join(paths.backupRoot, replaced.backupPath),
    '{"role":"user","content":"modified"}\n',
  );

  await assert.rejects(restoreIncrementalSessions({ paths, preflight }));
  assert.equal(fsSync.existsSync(path.join(paths.codexRoot, 'sessions', 'recovered', 'replaced.jsonl')), false);
});

test('fresh directory creator rejects a symlink or junction race at .codex', async (t) => {
  const { root, paths } = await makeFixture(t);
  const linked = await addBackup(paths, 'linked-root', '{"role":"user","content":"safe"}\n');
  await writeManifest(paths, { 'linked-root': linked });
  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['linked-root'] });
  const outside = path.join(root, 'outside-codex');
  await fs.mkdir(outside);
  await fs.rm(paths.codexRoot, { recursive: true, force: true });
  await fs.symlink(outside, paths.codexRoot, process.platform === 'win32' ? 'junction' : 'dir');

  await assert.rejects(restoreIncrementalSessions({ paths, preflight }));
  assert.equal(fsSync.existsSync(path.join(outside, 'sessions')), false);
});

test('index write failure rolls back every newly published session', async (t) => {
  const { paths } = await makeFixture(t);
  const selected = await addBackup(paths, 'index-failure', '{"role":"user","content":"safe"}\n');
  await writeManifest(paths, { 'index-failure': selected });
  const preflight = await preflightIncrementalRecovery({ paths, sessionIds: ['index-failure'] });
  const indexPath = path.join(paths.codexRoot, 'session_index.jsonl');
  await fs.mkdir(indexPath);

  await assert.rejects(restoreIncrementalSessions({ paths, preflight }));

  assert.equal(fsSync.existsSync(path.join(paths.codexRoot, 'sessions', 'recovered', 'index-failure.jsonl')), false);
  assert.equal((await fs.lstat(indexPath)).isDirectory(), true);
});

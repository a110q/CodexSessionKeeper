const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const {
  durableReplaceWithWriter,
  publishSyncedTemporaryFileIfAbsent,
  replaceFileDurably,
  writeFileDurably,
} = require('./durable-write');
const { verifyFullBackupFile } = require('./backup-file-verifier');
const { assertSafeDestinationPath, assertSafeSourcePath } = require('./restore-filesystem');
const { createSecureRecoveryDirectory } = require('./secure-recovery-directory');
const { loadVerification } = require('./verification-store');
const { MAX_JSONL_LINE_BYTES } = require('../jsonl-policy');

const SHA256_PATTERN = /^[a-f\d]{64}$/i;

function safePathComponent(value) {
  const safe = String(value || '')
    .replace(/[^A-Za-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return safe || 'session';
}

async function exists(filePath) {
  try {
    await fsp.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function existsSync(filePath) {
  try {
    fs.accessSync(filePath);
    return true;
  } catch {
    return false;
  }
}

function backupPathParts(backupPath) {
  return String(backupPath || '').split(/[\\/]+/);
}

function resolveBackupFile(paths, record, { requireExisting = false } = {}) {
  const backupPath = String(record.backupPath || '');
  if (!backupPath) throw new Error(`Backup path for session ${record.sessionId} is empty`);
  if (path.isAbsolute(backupPath)) {
    throw new Error(`Backup path for session ${record.sessionId} is absolute: ${backupPath}`);
  }

  const parts = backupPathParts(backupPath);
  if (parts.some((part) => !part || part === '.')) {
    throw new Error(`Backup path for session ${record.sessionId} is not normalized: ${backupPath}`);
  }
  if (parts.includes('..')) {
    throw new Error(`Backup path for session ${record.sessionId} escapes backup root: ${backupPath}`);
  }

  const filePath = path.join(paths.backupRoot, ...parts);
  const root = path.resolve(paths.backupRoot);
  const resolved = path.resolve(filePath);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    throw new Error(`Backup path for session ${record.sessionId} escapes backup root: ${backupPath}`);
  }

  const resolvedFile = assertSafeSourcePath(filePath, paths.backupRoot, { allowMissing: !requireExisting });
  if (existsSync(filePath)) {
    const stat = fs.lstatSync(filePath);
    if (!stat.isFile() || path.extname(filePath).toLowerCase() !== '.jsonl') {
      throw new Error(`Backup path for session ${record.sessionId} is not a regular JSONL file: ${backupPath}`);
    }
  } else if (requireExisting) {
    throw new Error(`Backup file is missing for session ${record.sessionId}: ${filePath}`);
  }
  return resolvedFile;
}

async function readManifest(paths) {
  const text = await fsp.readFile(paths.manifestPath, 'utf8');
  return JSON.parse(text);
}

async function loadIncrementalBackupCatalog({ paths, currentSessionIds }) {
  const manifest = await readManifest(paths);
  const current = currentSessionIds || new Set();
  const candidates = [];

  for (const record of Object.values(manifest.sessions || {})) {
    let backupFilePath = '';
    let status = current.has(record.sessionId) ? 'existing' : 'missing';
    let error = null;
    try {
      backupFilePath = resolveBackupFile(paths, record);
      if (!await exists(backupFilePath)) {
        status = 'backupFileMissing';
        error = `Backup file is missing for session ${record.sessionId}: ${backupFilePath}`;
      }
    } catch (caught) {
      status = 'invalidBackup';
      error = caught.message || String(caught);
    }

    candidates.push({
      id: record.sessionId,
      sessionId: record.sessionId,
      title: String(record.title || record.sessionId),
      sourcePath: String(record.sourcePath || ''),
      backupPath: String(record.backupPath || ''),
      backupFilePath,
      firstSeenAt: record.firstSeenAt,
      lastBackedUpAt: record.lastBackedUpAt,
      lineCount: Number(record.lineCount || 0),
      bytesBackedUp: Number(record.bytesBackedUp || 0),
      status,
      isRestorable: status === 'missing',
      error,
      backupRecord: { ...record },
    });
  }

  candidates.sort((a, b) => new Date(b.lastBackedUpAt || b.firstSeenAt) - new Date(a.lastBackedUpAt || a.firstSeenAt));
  return {
    backupRoot: paths.backupRoot,
    updatedAt: manifest.updatedAt || null,
    totalCount: candidates.length,
    missingCount: candidates.filter((item) => item.status === 'missing').length,
    existingCount: candidates.filter((item) => item.status === 'existing').length,
    errorCount: candidates.filter((item) => item.status === 'invalidBackup' || item.status === 'backupFileMissing').length,
    candidates,
  };
}

async function preflightIncrementalRecovery({ paths, sessionIds }) {
  const manifest = await readManifest(paths);
  const verification = await loadVerification(
    paths.verificationPath || path.join(paths.backupRoot, 'verification.json'),
  );
  const selected = new Set((sessionIds || []).map(String));
  const records = Object.values(manifest.sessions || {})
    .filter((record) => selected.has(record.sessionId))
    .sort((a, b) => String(a.sessionId).localeCompare(String(b.sessionId)));

  if (!records.length || records.length !== selected.size) {
    throw new Error('No requested sessions were found in the backup manifest.');
  }

  const destinationRoot = paths.codexRoot;
  const seenDestinations = new Set();
  const restorePaths = [];
  for (const record of records) {
    const sourcePath = resolveBackupFile(paths, record, { requireExisting: true });
    const expectedVerification = await validatedRecoveryExpectation({
      sourcePath,
      record,
      verification,
    });
    const filename = `${safePathComponent(record.sessionId)}.jsonl`;
    const destinationPath = path.join(destinationRoot, 'sessions', 'recovered', filename);
    assertSafeDestinationPath(destinationPath, destinationRoot);
    const normalizedDestination = path.resolve(destinationPath);
    if (seenDestinations.has(normalizedDestination)) {
      throw new Error(`Multiple sessions map to the same recovery destination: ${filename}`);
    }
    seenDestinations.add(normalizedDestination);
    restorePaths.push(Object.freeze({
      sessionId: record.sessionId,
      sourcePath,
      destinationPath,
      record: Object.freeze({ ...record }),
      expectedVerification,
    }));
  }

  assertSafeDestinationPath(path.join(destinationRoot, 'session_index.jsonl'), destinationRoot);
  return Object.freeze(restorePaths);
}

async function restoreIncrementalSessions({ paths, preflight }) {
  const restorePaths = Array.isArray(preflight) ? preflight : [];
  if (!restorePaths.length) throw new Error('No preflighted sessions were provided.');

  // Revalidate the complete source and destination set before the first write.
  for (const item of restorePaths) {
    const sourcePath = resolveBackupFile(paths, item.record, { requireExisting: true });
    if (sourcePath !== item.sourcePath) {
      throw new Error(`Backup path for session ${item.sessionId} changed after preflight.`);
    }
    assertSafeDestinationPath(item.destinationPath, paths.codexRoot);
    if (existsSync(item.destinationPath)) {
      throw new Error(`Recovery destination already exists: ${item.destinationPath}`);
    }
  }

  const recoveredRoot = await createSecureRecoveryDirectory(paths.codexRoot);
  const stagingRoot = path.join(recoveredRoot, `.recovery-staging-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  assertSafeDestinationPath(stagingRoot, paths.codexRoot);
  await fsp.mkdir(stagingRoot);
  const staged = [];
  const published = [];
  try {
    for (const item of restorePaths) {
      const stagingPath = path.join(stagingRoot, path.basename(item.destinationPath));
      await stageAndVerifySource({ paths, item, stagingPath });
      staged.push({ item, stagingPath });
    }

    const recoveredFiles = {};
    try {
      for (const { item, stagingPath } of staged) {
        await publishSyncedTemporaryFileIfAbsent(stagingPath, item.destinationPath);
        published.push(item.destinationPath);
        recoveredFiles[item.sessionId] = item.destinationPath;
      }

      const indexPath = path.join(paths.codexRoot, 'session_index.jsonl');
      assertSafeDestinationPath(indexPath, paths.codexRoot);
      const existingLines = await readExistingLines(indexPath);
      const restoredIds = new Set(restorePaths.map((item) => item.sessionId));
      const retained = existingLines.filter((line) => {
        try {
          return !restoredIds.has(String(JSON.parse(line).id || ''));
        } catch {
          return true;
        }
      });
      const recoveredLines = restorePaths.map(({ record, destinationPath }) => JSON.stringify({
        id: record.sessionId,
        title: record.title || record.sessionId,
        thread_name: record.title || record.sessionId,
        rollout_path: destinationPath,
        source_path: record.sourcePath || '',
        backup_path: record.backupPath || '',
        updated_at: record.lastBackedUpAt || record.firstSeenAt,
        line_count: record.lineCount || 0,
        bytes_backed_up: record.bytesBackedUp || 0,
      }));
      const payload = `${[...retained, ...recoveredLines].join('\n')}\n`;
      if (existsSync(indexPath)) await replaceFileDurably(indexPath, payload);
      else await writeFileDurably(indexPath, payload);

      return Object.freeze({
        recoveredFiles: Object.freeze(recoveredFiles),
        records: restorePaths.map((item) => item.record),
      });
    } catch (error) {
      await Promise.allSettled(published.map((destinationPath) => fsp.rm(destinationPath, { force: true })));
      throw error;
    }
  } finally {
    await fsp.rm(stagingRoot, { recursive: true, force: true }).catch(() => {});
  }
}

async function readExistingLines(filePath) {
  try {
    return (await fsp.readFile(filePath, 'utf8')).split(/\r?\n/).filter(Boolean);
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

async function stageAndVerifySource({ paths, item, stagingPath }) {
  const resolved = resolveBackupFile(paths, item.record, { requireExisting: true });
  if (resolved !== item.sourcePath) {
    throw new Error(`Backup path for session ${item.sessionId} changed during restore.`);
  }
  const source = await fsp.open(item.sourcePath, 'r');
  try {
    await durableReplaceWithWriter(stagingPath, async (destination) => {
      const buffer = Buffer.allocUnsafe(item.expectedVerification.chunkSize);
      let position = 0;
      while (true) {
        const { bytesRead } = await source.read(buffer, 0, buffer.length, position);
        if (bytesRead === 0) break;
        await writeAll(destination, buffer.subarray(0, bytesRead));
        position += bytesRead;
      }
    }, {
      verifyTemporary: (temporaryPath) => verifyFullBackupFile({
        filePath: temporaryPath,
        chunkSize: item.expectedVerification.chunkSize,
        maxLineBytes: MAX_JSONL_LINE_BYTES,
        expectedByteCount: item.expectedVerification.byteCount,
        expectedLineCount: item.expectedVerification.lineCount,
        expectedContentHash: item.expectedVerification.contentHash,
        expectedChunkHashes: item.expectedVerification.chunkHashes,
      }),
    });
  } finally {
    await source.close();
  }
}

async function writeAll(handle, data) {
  let offset = 0;
  while (offset < data.length) {
    const { bytesWritten } = await handle.write(data, offset, data.length - offset, null);
    if (bytesWritten <= 0) throw new Error('Unable to write staged recovery file.');
    offset += bytesWritten;
  }
}

async function validatedRecoveryExpectation({ sourcePath, record, verification }) {
  const byteCount = Number(record.bytesBackedUp);
  const lineCount = Number(record.lineCount);
  if (!Number.isSafeInteger(byteCount) || byteCount < 0 || !Number.isSafeInteger(lineCount) || lineCount < 0) {
    throw new Error(`Backup metadata is invalid for session ${record.sessionId}.`);
  }
  const entry = verification.sessions[record.sessionId];
  if (entry) {
    if (entry.backupPath !== record.backupPath
      || entry.byteCount !== byteCount
      || entry.lineCount !== lineCount
      || !Array.isArray(entry.chunkHashes)
      || entry.chunkHashes.length !== Math.ceil(byteCount / verification.chunkSize)
      || !entry.chunkHashes.every((hash) => SHA256_PATTERN.test(String(hash)))) {
      throw new Error(`Backup verification metadata does not match session ${record.sessionId}.`);
    }
    const result = await verifyFullBackupFile({
      filePath: sourcePath,
      chunkSize: verification.chunkSize,
      maxLineBytes: MAX_JSONL_LINE_BYTES,
      expectedByteCount: byteCount,
      expectedLineCount: lineCount,
      expectedChunkHashes: entry.chunkHashes,
    });
    return Object.freeze({
      byteCount,
      lineCount,
      contentHash: result.contentHash,
      chunkSize: verification.chunkSize,
      chunkHashes: Object.freeze([...entry.chunkHashes]),
    });
  }

  if (!SHA256_PATTERN.test(String(record.contentHash || ''))) {
    throw new Error(`Backup has no trusted verification for session ${record.sessionId}.`);
  }
  const result = await verifyFullBackupFile({
    filePath: sourcePath,
    chunkSize: verification.chunkSize,
    maxLineBytes: MAX_JSONL_LINE_BYTES,
    expectedByteCount: byteCount,
    expectedLineCount: lineCount,
    expectedContentHash: record.contentHash,
  });
  return Object.freeze({
    byteCount,
    lineCount,
    contentHash: result.contentHash,
    chunkSize: verification.chunkSize,
    chunkHashes: null,
  });
}

module.exports = {
  loadIncrementalBackupCatalog,
  preflightIncrementalRecovery,
  resolveBackupFile,
  restoreIncrementalSessions,
};

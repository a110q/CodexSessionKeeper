const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { replaceFileDurably, writeFileDurably } = require('./durable-write');
const { assertSafeDestinationPath, assertSafeSourcePath } = require('./restore-filesystem');

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
  const selected = new Set((sessionIds || []).map(String));
  const records = Object.values(manifest.sessions || {})
    .filter((record) => selected.has(record.sessionId))
    .sort((a, b) => String(a.sessionId).localeCompare(String(b.sessionId)));

  if (!records.length || records.length !== selected.size) {
    throw new Error('No requested sessions were found in the backup manifest.');
  }

  const destinationRoot = paths.codexRoot;
  const seenDestinations = new Set();
  const restorePaths = records.map((record) => {
    const sourcePath = resolveBackupFile(paths, record, { requireExisting: true });
    const filename = `${safePathComponent(record.sessionId)}.jsonl`;
    const destinationPath = path.join(destinationRoot, 'sessions', 'recovered', filename);
    assertSafeDestinationPath(destinationPath, destinationRoot);
    const normalizedDestination = path.resolve(destinationPath);
    if (seenDestinations.has(normalizedDestination)) {
      throw new Error(`Multiple sessions map to the same recovery destination: ${filename}`);
    }
    seenDestinations.add(normalizedDestination);
    return Object.freeze({
      sessionId: record.sessionId,
      sourcePath,
      destinationPath,
      record: Object.freeze({ ...record }),
    });
  });

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

  const recoveredRoot = path.join(paths.codexRoot, 'sessions', 'recovered');
  await createSafeDestinationDirectory(recoveredRoot, paths.codexRoot);
  const recoveredFiles = {};
  for (const item of restorePaths) {
    const content = await readValidatedSource(paths, item);
    await writeFileDurably(item.destinationPath, content);
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

  return Object.freeze({ recoveredFiles: Object.freeze(recoveredFiles), records: restorePaths.map((item) => item.record) });
}

async function createSafeDestinationDirectory(directory, root) {
  const relative = path.relative(path.resolve(root), path.resolve(directory));
  let current = path.resolve(root);
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    try {
      await fsp.mkdir(current);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    assertSafeDestinationPath(current, root);
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

async function readValidatedSource(paths, item) {
  const resolved = resolveBackupFile(paths, item.record, { requireExisting: true });
  if (resolved !== item.sourcePath) {
    throw new Error(`Backup path for session ${item.sessionId} changed during restore.`);
  }
  const before = await fsp.lstat(item.sourcePath);
  if (!before.isFile() || before.isSymbolicLink()) {
    throw new Error(`Backup source is not a regular file: ${item.sourcePath}`);
  }
  const handle = await fsp.open(item.sourcePath, 'r');
  try {
    const opened = await handle.stat();
    const stillResolved = resolveBackupFile(paths, item.record, { requireExisting: true });
    if (stillResolved !== item.sourcePath
      || !opened.isFile()
      || (before.ino && opened.ino && (before.ino !== opened.ino || before.dev !== opened.dev))) {
      throw new Error(`Backup source changed during restore: ${item.sourcePath}`);
    }
    return await handle.readFile();
  } finally {
    await handle.close();
  }
}

module.exports = {
  loadIncrementalBackupCatalog,
  preflightIncrementalRecovery,
  resolveBackupFile,
  restoreIncrementalSessions,
};

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

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

function resolveBackupFile(paths, record) {
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

  return filePath;
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

async function uniquePackagePath(paths, createdAt) {
  const packagesRoot = path.join(paths.backupRoot, 'recovery-packages');
  await fsp.mkdir(packagesRoot, { recursive: true });
  const baseName = `incremental-recovery-${createdAt.toISOString().replace(/[:.]/g, '-')}`;
  let candidate = path.join(packagesRoot, baseName);
  let suffix = 2;
  while (existsSync(candidate)) {
    candidate = path.join(packagesRoot, `${baseName}-${suffix}`);
    suffix += 1;
  }
  await fsp.mkdir(candidate, { recursive: true });
  return candidate;
}

async function buildIncrementalRecoveryPackage({ paths, sessionIds, now = () => new Date() }) {
  const manifest = await readManifest(paths);
  const selected = new Set((sessionIds || []).map(String));
  const records = Object.values(manifest.sessions || {})
    .filter((record) => selected.has(record.sessionId))
    .sort((a, b) => String(a.sessionId).localeCompare(String(b.sessionId)));

  if (!records.length) throw new Error('No requested sessions were found in the backup manifest.');

  const createdAt = now();
  const packagePath = await uniquePackagePath(paths, createdAt);
  const dataPath = path.join(packagePath, 'data');
  const recoveredRoot = path.join(dataPath, 'sessions', 'recovered');
  await fsp.mkdir(recoveredRoot, { recursive: true });

  const includedPaths = ['session_index.jsonl', 'sessions'];
  const indexLines = [];
  for (const record of records) {
    const backupFilePath = resolveBackupFile(paths, record);
    const filename = `${safePathComponent(record.sessionId)}.jsonl`;
    const recoveredRelativePath = path.join('sessions', 'recovered', filename);
    await fsp.copyFile(backupFilePath, path.join(recoveredRoot, filename));
    includedPaths.push(recoveredRelativePath.split(path.sep).join('/'));
    indexLines.push(JSON.stringify({
      id: record.sessionId,
      title: record.title || record.sessionId,
      thread_name: record.title || record.sessionId,
      rollout_path: path.join(paths.codexRoot, 'sessions', 'recovered', filename),
      source_path: record.sourcePath || '',
      backup_path: record.backupPath || '',
      updated_at: record.lastBackedUpAt || record.firstSeenAt,
      line_count: record.lineCount || 0,
      bytes_backed_up: record.bytesBackedUp || 0,
    }));
  }

  await fsp.writeFile(path.join(dataPath, 'session_index.jsonl'), `${indexLines.join('\n')}\n`, 'utf8');

  const createdAtString = createdAt.toISOString();
  const snapshot = {
    id: path.basename(packagePath),
    name: `Incremental Recovery ${createdAtString}`,
    createdAt: createdAtString,
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    reason: 'incremental-recovery',
    kind: 'system',
    modelProvider: 'unknown',
    model: 'unknown',
    accountFingerprint: 'none',
    sessionCount: records.length,
    archivedSessionCount: 0,
    sizeBytes: records.reduce((sum, record) => sum + Number(record.bytesBackedUp || 0), 0),
    includedPaths: includedPaths.sort(),
    appVersion: '1.0.13',
  };
  await fsp.writeFile(path.join(packagePath, 'snapshot.json'), JSON.stringify(snapshot, null, 2), 'utf8');

  return { path: packagePath, dataPath, ...snapshot };
}

module.exports = {
  buildIncrementalRecoveryPackage,
  loadIncrementalBackupCatalog,
  resolveBackupFile,
};

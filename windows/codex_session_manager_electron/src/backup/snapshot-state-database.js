const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

const { runSQLite } = require('./live-state-database');

function quoteLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function protectionSnapshotWarning(meta) {
  const includedPaths = new Set(meta?.includedPaths || []);
  if (includedPaths.has('state_5.sqlite')) return '';
  const degraded = (meta?.warnings || []).some((warning) => (
    String(warning).includes('SQLite 索引库')
      && String(warning).includes('降级创建文件型快照')
  ));
  return degraded ? ' 注意：保护快照不包含 SQLite 索引；会话文件保护点仍已创建。' : '';
}

function alreadyExistsError(destinationPath) {
  const error = new Error(`SQLite 快照目标已存在：${destinationPath}`);
  error.code = 'EEXIST';
  return error;
}

async function requireMissingDestination(fileSystem, destinationPath) {
  try {
    await fileSystem.lstat(destinationPath);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  throw alreadyExistsError(destinationPath);
}

async function removeTemporaryFile(fileSystem, temporaryPath) {
  try {
    await fileSystem.rm(temporaryPath, { force: true });
  } catch {
    // Preserve the original SQLite, sync, or publication failure.
  }
}

function createConsistentStateDatabaseSnapshotForTesting(dependencies = {}) {
  const fileSystem = dependencies.fileSystem || fs;
  const sqliteRunner = dependencies.runSQLite || runSQLite;
  const createUniqueId = dependencies.randomUUID || crypto.randomUUID;

  return async function createConsistentStateDatabaseSnapshot({
    sourcePath,
    destinationPath,
    sqlitePath,
    busyTimeoutMs = 5000,
  }) {
    await fileSystem.access(sourcePath);
    await fileSystem.mkdir(path.dirname(destinationPath), { recursive: true });
    await requireMissingDestination(fileSystem, destinationPath);

    const temporaryPath = path.join(
      path.dirname(destinationPath),
      `${path.basename(destinationPath)}.snapshot-${process.pid}-${createUniqueId()}`
    );
    const sqliteOptions = { sqlitePath, busyTimeoutMs };
    try {
      await sqliteRunner(
        sourcePath,
        `VACUUM INTO ${quoteLiteral(temporaryPath)};`,
        sqliteOptions
      );

      const integrityResult = await sqliteRunner(
        temporaryPath,
        'PRAGMA integrity_check;',
        sqliteOptions
      );
      if (String(integrityResult).trim() !== 'ok') {
        throw new Error(`SQLite integrity_check 未通过：${String(integrityResult).trim() || '无结果'}`);
      }

      const handle = await fileSystem.open(temporaryPath, 'r+');
      try {
        await handle.sync();
      } finally {
        await handle.close();
      }

      // A hard link publishes the fully synced database atomically and never
      // overwrites a destination created by another process.
      await fileSystem.link(temporaryPath, destinationPath);
    } catch (error) {
      await removeTemporaryFile(fileSystem, temporaryPath);
      throw error;
    }

    // Once linked, destinationPath is a complete synced snapshot. A failure
    // to remove the extra temporary hard-link must never revoke that snapshot
    // or make callers report a false SQLite downgrade.
    await removeTemporaryFile(fileSystem, temporaryPath);
  };
}

const createConsistentStateDatabaseSnapshot = createConsistentStateDatabaseSnapshotForTesting();

module.exports = {
  createConsistentStateDatabaseSnapshot,
  createConsistentStateDatabaseSnapshotForTesting,
  protectionSnapshotWarning,
};

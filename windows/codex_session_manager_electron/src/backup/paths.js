const path = require('node:path').win32;

function safeSessionId(sessionId) {
  const safe = String(sessionId ?? '')
    .replace(/[^A-Za-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '');

  return safe || 'session';
}

function utcDateParts(firstSeenAt) {
  const date = new Date(firstSeenAt);
  const year = String(date.getUTCFullYear());
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');

  return { day, month, year };
}

function backupPaths(homeDir) {
  const codexRoot = path.join(homeDir, '.codex');
  const vaultRoot = path.join(homeDir, '.codex-session-vault');
  const backupRoot = path.join(vaultRoot, 'incremental-backups');
  const sessionsRoot = path.join(backupRoot, 'sessions');
  const logsRoot = path.join(backupRoot, 'logs');

  function backupFilePath(sessionId, firstSeenAt) {
    const { day, month, year } = utcDateParts(firstSeenAt);

    return path.join(
      sessionsRoot,
      year,
      month,
      day,
      `${safeSessionId(sessionId)}.jsonl`,
    );
  }

  function relativeBackupPath(filePath) {
    const relative = path.relative(path.resolve(backupRoot), path.resolve(filePath));

    if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
      return null;
    }

    return relative;
  }

  return {
    backupFilePath,
    backupRoot,
    codexRoot,
    cursorDatabasePath: path.join(backupRoot, 'cursors.sqlite'),
    logPath: path.join(logsRoot, 'backup-agent.log'),
    logsRoot,
    manifestPath: path.join(backupRoot, 'manifest.json'),
    relativeBackupPath,
    sessionsRoot,
    statusPath: path.join(backupRoot, 'status.json'),
    vaultRoot,
  };
}

module.exports = { backupPaths };

const windowsPath = require('node:path').win32;

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

function backupPaths(input) {
  const options = typeof input === 'object' && input !== null ? input : { homeDir: input };
  const path = options.pathImpl || windowsPath;
  const homeDir = options.homeDir;
  const codexRoot = options.codexRoot || path.join(homeDir, '.codex');
  const vaultRoot = options.vaultRoot || path.join(homeDir, '.codex-session-vault');
  const backupRoot = options.backupRoot || path.join(vaultRoot, 'incremental-backups');
  const stateRoot = options.stateRoot || backupRoot;
  const sessionsRoot = path.join(backupRoot, 'sessions');
  const archivedSessionsRoot = path.join(backupRoot, 'archived_sessions');
  const logsRoot = path.join(stateRoot, 'logs');

  function legacyBackupFilePath(sessionId, firstSeenAt) {
    const { day, month, year } = utcDateParts(firstSeenAt);

    return path.join(
      sessionsRoot,
      year,
      month,
      day,
      `${safeSessionId(sessionId)}.jsonl`,
    );
  }

  function mirroredBackupFilePath(sourcePath) {
    const resolvedSource = path.resolve(sourcePath);
    for (const rootName of ['sessions', 'archived_sessions']) {
      const sourceRoot = path.resolve(codexRoot, rootName);
      const relative = path.relative(sourceRoot, resolvedSource);
      if (relative && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative)) {
        return path.join(backupRoot, rootName, relative);
      }
    }

    throw new Error(`Source path is outside Codex session roots: ${sourcePath}`);
  }

  function backupFilePath(value, firstSeenAt) {
    return firstSeenAt === undefined
      ? mirroredBackupFilePath(value)
      : legacyBackupFilePath(value, firstSeenAt);
  }

  function relativeBackupPath(filePath) {
    const relative = path.relative(path.resolve(backupRoot), path.resolve(filePath));

    if (
      !relative
      || relative === '..'
      || relative.startsWith('..\\')
      || relative.startsWith('../')
      || path.isAbsolute(relative)
    ) {
      return null;
    }

    return relative;
  }

  return {
    auditStatePath: path.join(stateRoot, 'integrity-audit.json'),
    backupFilePath,
    backupRoot,
    archivedSessionsRoot,
    codexRoot,
    cursorDatabasePath: path.join(stateRoot, 'cursors.sqlite'),
    localStatusPath: path.join(stateRoot, 'status.json'),
    logPath: path.join(logsRoot, 'backup-agent.log'),
    logsRoot,
    manifestPath: path.join(backupRoot, 'manifest.json'),
    verificationPath: path.join(backupRoot, 'verification.json'),
    pendingSourcesPath: path.join(stateRoot, 'pending-sources.json'),
    relativeBackupPath,
    repairQuarantineRoot: path.join(backupRoot, 'repair-quarantine'),
    remoteStatusPath: path.join(backupRoot, 'status.json'),
    sessionsRoot,
    statusPath: path.join(backupRoot, 'status.json'),
    stateRoot,
    vaultRoot,
  };
}

module.exports = { backupPaths };

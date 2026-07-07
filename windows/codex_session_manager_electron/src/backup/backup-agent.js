const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const { CursorStore } = require('./cursor-store');
const { AGENT_VERSION } = require('./models');
const { loadOrCreateManifest, saveManifest } = require('./manifest-store');
const { readNewCompleteLines } = require('./session-tailer');
const { sessionIdFromPath, titleFromJsonLine } = require('./session-identity');

const ACTIVE_STATUS = 'active';
const NEWLINE_BYTE = 0x0A;

class BackupAgent {
  constructor({ paths, now = () => new Date(), tailer } = {}) {
    if (!paths) {
      throw new Error('BackupAgent requires paths.');
    }

    this.paths = paths;
    this.now = now;
    this.tailer = tailer || { readNewCompleteLines };
    this.pollingTimer = null;
    this.pollingStartedAt = null;
    this.scanPromise = null;
    this.scanQueued = false;
  }

  startPolling(intervalMs = 10000) {
    if (this.pollingTimer) {
      return;
    }

    this.pollingStartedAt = this.now();
    const tick = () => {
      this.performOneShotScan().catch((error) => {
        this.writeErrorStatus(error).catch(() => {});
      });
    };

    this.pollingTimer = setInterval(tick, intervalMs);
    if (typeof this.pollingTimer.unref === 'function') {
      this.pollingTimer.unref();
    }
    tick();
  }

  stopPolling() {
    if (!this.pollingTimer) {
      return;
    }

    clearInterval(this.pollingTimer);
    this.pollingTimer = null;
  }

  async performOneShotScan() {
    if (this.scanPromise) {
      this.scanQueued = true;
      return this.scanPromise;
    }

    this.scanPromise = this.drainScanQueue();
    try {
      return await this.scanPromise;
    } finally {
      this.scanPromise = null;
    }
  }

  async drainScanQueue() {
    let result;
    do {
      this.scanQueued = false;
      result = await this.performOneShotScanLocked();
    } while (this.scanQueued);

    return result;
  }

  async performOneShotScanLocked() {
    const scanDate = this.now();
    await this.ensureBackupDirectories();

    const manifestExisted = await fileExists(this.paths.manifestPath);
    const cursorStore = new CursorStore({ paths: this.paths });
    await cursorStore.open();

    try {
      const manifest = loadOrCreateManifest(this.paths, scanDate);
      let manifestChanged = !manifestExisted;

      if (manifest.codexRoot !== this.paths.codexRoot) {
        manifest.codexRoot = this.paths.codexRoot;
        manifestChanged = true;
      }
      if (manifest.backupRoot !== this.paths.backupRoot) {
        manifest.backupRoot = this.paths.backupRoot;
        manifestChanged = true;
      }

      const processedSessionIds = new Set();
      const scanErrors = [];
      for (const sourcePath of await this.discoverSessionFiles()) {
        const sessionId = sessionIdFromPath(sourcePath);
        if (!sessionId || processedSessionIds.has(sessionId)) {
          continue;
        }
        processedSessionIds.add(sessionId);

        const result = await this.processSessionFile({
          cursorStore,
          manifest,
          scanDate,
          sessionId,
          sourcePath,
        });
        manifestChanged = manifestChanged || result.manifestChanged;
        if (result.lastError) {
          scanErrors.push(result.lastError);
        }
      }

      if (manifestChanged) {
        manifest.updatedAt = scanDate.toISOString();
        saveManifest(this.paths, manifest);
      }

      const lastError = scanErrors[0] || null;
      await this.writeStatus(manifest, lastError ? 'error' : 'running', lastError, scanDate);
      return manifest;
    } finally {
      await cursorStore.close();
    }
  }

  async ensureBackupDirectories() {
    await fsp.mkdir(this.paths.backupRoot, { recursive: true });
    await fsp.mkdir(this.paths.sessionsRoot, { recursive: true });
    await fsp.mkdir(path.dirname(this.paths.statusPath), { recursive: true });
    await fsp.mkdir(path.dirname(this.paths.logPath), { recursive: true });
  }

  async discoverSessionFiles() {
    const roots = [
      { root: path.join(this.paths.codexRoot, 'sessions'), priority: 0 },
      { root: path.join(this.paths.codexRoot, 'archived_sessions'), priority: 1 },
    ];
    const discovered = [];

    for (const { root, priority } of roots) {
      await walkJsonlFiles(root, priority, discovered);
    }

    return discovered
      .sort((lhs, rhs) => {
        if (lhs.priority !== rhs.priority) {
          return lhs.priority - rhs.priority;
        }
        return lhs.filePath.localeCompare(rhs.filePath);
      })
      .map((entry) => entry.filePath);
  }

  async processSessionFile({ sourcePath, sessionId, scanDate, manifest, cursorStore }) {
    const existingRecord = manifest.sessions[sessionId] || null;
    const currentCursor = await cursorStore.get(sourcePath);
    const baselineCursor = currentCursor
      || await this.migratedCursor(existingRecord, sourcePath, cursorStore);
    const firstSeenAt = existingRecord?.firstSeenAt
      ? new Date(existingRecord.firstSeenAt)
      : scanDate;
    const backupPath = this.backupFilePathFor(sessionId, firstSeenAt, existingRecord, baselineCursor);
    const relativeBackupPath = this.validatedRelativeBackupPath(backupPath);
    const readOffset = baselineCursor?.lastByteOffset ?? 0;
    const lineCountBeforeReadOffset = readOffset > 0 ? baselineCursor?.lineCount ?? 0 : 0;
    const tailResult = await this.readTail(sourcePath, readOffset);
    const sourceMetadata = await metadataFor(sourcePath);
    const recordedLineCount = Math.max(
      Number(existingRecord?.lineCount ?? 0),
      Number(baselineCursor?.lineCount ?? 0),
    );
    const recordedBytesBackedUp = Number(existingRecord?.bytesBackedUp ?? 0);
    const sourcePathMigrated = existingRecord ? existingRecord.sourcePath !== sourcePath : false;
    const firstSeenBackupExists = !existingRecord && !baselineCursor && await fileExists(backupPath);
    const needsBackupStats = this.shouldReadBackupFileStats({
      baselineCursor,
      existingRecord,
      firstSeenBackupExists,
      sourcePathMigrated,
    });
    const backupStatsBeforeAppend = needsBackupStats
      ? await backupFileStats(backupPath)
      : { byteCount: recordedBytesBackedUp, lineCount: recordedLineCount };
    const skippedAlreadyBackedUpLineCount = Math.min(
      tailResult.lines.length,
      Math.max(0, backupStatsBeforeAppend.lineCount - lineCountBeforeReadOffset),
    );
    const linesToAppend = tailResult.lines.slice(skippedAlreadyBackedUpLineCount);
    const appendedLineStats = lineStats(linesToAppend);

    if (linesToAppend.length > 0) {
      await appendLines(backupPath, linesToAppend);
    }

    const backupStatsAfterAppend = {
      byteCount: backupStatsBeforeAppend.byteCount + appendedLineStats.byteCount,
      lineCount: backupStatsBeforeAppend.lineCount + appendedLineStats.lineCount,
    };
    const consumedCompleteLineCount = lineCountBeforeReadOffset + tailResult.lines.length;
    const totalLineCount = Math.max(
      recordedLineCount,
      consumedCompleteLineCount,
      backupStatsAfterAppend.lineCount,
    );
    const totalBytesBackedUp = Math.max(recordedBytesBackedUp, backupStatsAfterAppend.byteCount);
    const titleFromNewLines = firstTitle(tailResult.lines);
    const title = existingRecord?.title
      ?? titleFromNewLines
      ?? await backupTitleIfAlreadyInspectingFile(backupPath, needsBackupStats);
    const lastBackedUpAt = resolveLastBackedUpAt({
      appendedLineCount: linesToAppend.length,
      existingRecord,
      scanDate,
      totalBytesBackedUp,
      totalLineCount,
    });
    const updatedRecord = {
      sessionId,
      sourcePath,
      backupPath: relativeBackupPath,
      title: title ?? null,
      firstSeenAt: firstSeenAt.toISOString(),
      lastBackedUpAt,
      lineCount: totalLineCount,
      bytesBackedUp: totalBytesBackedUp,
      status: ACTIVE_STATUS,
    };
    const manifestChanged = !sameRecord(existingRecord, updatedRecord);

    if (manifestChanged) {
      manifest.sessions[sessionId] = updatedRecord;
    }

    const updatedCursor = {
      sessionId,
      sourcePath,
      backupPath: relativeBackupPath,
      lastByteOffset: tailResult.nextOffset,
      lastSourceSize: sourceMetadata.size,
      lastSourceModifiedAt: sourceMetadata.modifiedAt,
      lineCount: totalLineCount,
      pendingPartialLine: tailResult.pendingPartialLine,
      status: ACTIVE_STATUS,
      lastError: tailResult.blockedError || null,
      updatedAt: scanDate.getTime() / 1000,
    };

    if (!sameCursor(currentCursor, updatedCursor)) {
      await cursorStore.upsert(updatedCursor);
    }

    return {
      manifestChanged,
      lastError: tailResult.blockedError || null,
    };
  }

  async migratedCursor(existingRecord, currentSourcePath, cursorStore) {
    if (!existingRecord || !existingRecord.sourcePath || existingRecord.sourcePath === currentSourcePath) {
      return null;
    }

    return cursorStore.get(existingRecord.sourcePath);
  }

  backupFilePathFor(sessionId, firstSeenAt, existingRecord, baselineCursor) {
    const recordedBackupPath = existingRecord?.backupPath ?? baselineCursor?.backupPath;
    if (recordedBackupPath) {
      if (path.isAbsolute(recordedBackupPath)) {
        return recordedBackupPath;
      }

      return path.join(this.paths.backupRoot, recordedBackupPath);
    }

    return this.paths.backupFilePath(sessionId, firstSeenAt);
  }

  validatedRelativeBackupPath(backupPath) {
    const relativeBackupPath = this.paths.relativeBackupPath(backupPath);
    if (!relativeBackupPath) {
      throw new Error(`Backup path is outside backup root: ${backupPath} is not contained in ${this.paths.backupRoot}.`);
    }

    return relativeBackupPath;
  }

  async readTail(sourcePath, offset) {
    if (typeof this.tailer === 'function') {
      return this.tailer(sourcePath, offset);
    }

    return this.tailer.readNewCompleteLines(sourcePath, offset);
  }

  shouldReadBackupFileStats({
    existingRecord,
    baselineCursor,
    firstSeenBackupExists,
    sourcePathMigrated,
  }) {
    if (firstSeenBackupExists) {
      return true;
    }

    if (!existingRecord) {
      return false;
    }

    if (!baselineCursor) {
      return true;
    }

    const baselineLineCount = baselineCursor?.lineCount;
    const recordedLineCount = Math.max(existingRecord.lineCount ?? 0, baselineLineCount ?? 0);
    if (sourcePathMigrated) {
      if (baselineCursor.lineCount !== existingRecord.lineCount) {
        return true;
      }
    } else if (baselineLineCount != null && baselineLineCount !== existingRecord.lineCount) {
      return true;
    }

    return recordedLineCount > 0 && Number(existingRecord.bytesBackedUp ?? 0) === 0;
  }

  async writeStatus(manifest, status, lastError, date) {
    await fsp.mkdir(path.dirname(this.paths.statusPath), { recursive: true });

    const existingStatus = await loadStatus(this.paths.statusPath);
    const records = Object.values(manifest.sessions || {});
    const snapshot = {
      agentVersion: AGENT_VERSION,
      enabled: true,
      status,
      mode: 'polling',
      codexRoot: this.paths.codexRoot,
      backupRoot: this.paths.backupRoot,
      firstRunAt: existingStatus?.firstRunAt ?? date.toISOString(),
      lastStartedAt: this.pollingStartedAt?.toISOString()
        ?? existingStatus?.lastStartedAt
        ?? date.toISOString(),
      lastHeartbeatAt: date.toISOString(),
      lastBackupAt: maxIsoDate(records.map((record) => record.lastBackedUpAt)),
      sessionCount: records.length,
      lineCount: records.reduce((total, record) => total + Number(record.lineCount ?? 0), 0),
      bytesBackedUp: records.reduce((total, record) => total + Number(record.bytesBackedUp ?? 0), 0),
      autoStartEnabled: false,
      lastError,
    };

    await writeJsonAtomic(this.paths.statusPath, snapshot);
  }

  async writeErrorStatus(error) {
    await this.ensureBackupDirectories();

    const manifest = safeLoadManifest(this.paths, this.now());
    await this.writeStatus(manifest, 'error', error?.message || String(error), this.now());
  }
}

async function walkJsonlFiles(root, priority, discovered) {
  let entries;
  try {
    entries = await fsp.readdir(root, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return;
    }
    throw error;
  }

  entries.sort((lhs, rhs) => lhs.name.localeCompare(rhs.name));
  for (const entry of entries) {
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      await walkJsonlFiles(entryPath, priority, discovered);
    } else if (entry.isFile() && path.extname(entry.name).toLowerCase() === '.jsonl') {
      discovered.push({ filePath: entryPath, priority });
    }
  }
}

async function metadataFor(filePath) {
  const stats = await fsp.stat(filePath);
  return {
    modifiedAt: stats.mtimeMs / 1000,
    size: stats.size,
  };
}

function lineStats(lines) {
  return {
    byteCount: lines.reduce((total, line) => total + Buffer.byteLength(line, 'utf8') + 1, 0),
    lineCount: lines.length,
  };
}

async function appendLines(filePath, lines) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.appendFile(filePath, lines.map((line) => `${line}\n`).join(''), 'utf8');
}

async function backupFileStats(filePath) {
  let stats;
  try {
    stats = await fsp.stat(filePath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return { byteCount: 0, lineCount: 0 };
    }
    throw error;
  }

  let lineCount = 0;
  for await (const chunk of fs.createReadStream(filePath)) {
    for (const byte of chunk) {
      if (byte === NEWLINE_BYTE) {
        lineCount += 1;
      }
    }
  }

  return {
    byteCount: stats.size,
    lineCount,
  };
}

function firstTitle(lines) {
  for (const line of lines) {
    const title = titleFromJsonLine(line);
    if (title) {
      return title;
    }
  }

  return null;
}

async function backupTitleIfAlreadyInspectingFile(filePath, needsBackupStats) {
  if (!needsBackupStats || !await fileExists(filePath)) {
    return null;
  }

  let pending = Buffer.alloc(0);
  for await (const chunk of fs.createReadStream(filePath, { highWaterMark: 64 * 1024 })) {
    let lineStart = 0;
    for (let index = 0; index < chunk.length; index += 1) {
      if (chunk[index] !== NEWLINE_BYTE) {
        continue;
      }

      const line = Buffer.concat([pending, chunk.subarray(lineStart, index)]).toString('utf8');
      const title = titleFromJsonLine(line);
      if (title) {
        return title;
      }
      pending = Buffer.alloc(0);
      lineStart = index + 1;
    }

    pending = Buffer.concat([pending, chunk.subarray(lineStart)]);
  }

  return null;
}

function resolveLastBackedUpAt({
  existingRecord,
  appendedLineCount,
  totalLineCount,
  totalBytesBackedUp,
  scanDate,
}) {
  if (appendedLineCount > 0) {
    return scanDate.toISOString();
  }

  if (!existingRecord?.lastBackedUpAt && (totalLineCount > 0 || totalBytesBackedUp > 0)) {
    return scanDate.toISOString();
  }

  return existingRecord?.lastBackedUpAt ?? null;
}

function sameRecord(lhs, rhs) {
  if (!lhs) {
    return false;
  }

  const keys = [
    'sessionId',
    'sourcePath',
    'backupPath',
    'title',
    'firstSeenAt',
    'lastBackedUpAt',
    'lineCount',
    'bytesBackedUp',
    'status',
  ];

  return keys.every((key) => lhs[key] === rhs[key]);
}

function sameCursor(lhs, rhs) {
  if (!lhs) {
    return false;
  }

  const keys = [
    'sessionId',
    'sourcePath',
    'backupPath',
    'lastByteOffset',
    'lastSourceSize',
    'lastSourceModifiedAt',
    'lineCount',
    'pendingPartialLine',
    'status',
    'lastError',
  ];

  return keys.every((key) => lhs[key] === rhs[key]);
}

function maxIsoDate(values) {
  let winner = null;
  let winnerTime = Number.NEGATIVE_INFINITY;

  for (const value of values) {
    if (!value) {
      continue;
    }

    const time = new Date(value).getTime();
    if (Number.isFinite(time) && time > winnerTime) {
      winner = value;
      winnerTime = time;
    }
  }

  return winner;
}

async function loadStatus(statusPath) {
  try {
    return JSON.parse(await fsp.readFile(statusPath, 'utf8'));
  } catch {
    return null;
  }
}

function safeLoadManifest(paths, now) {
  try {
    return loadOrCreateManifest(paths, now);
  } catch {
    return {
      version: 1,
      codexRoot: paths.codexRoot,
      backupRoot: paths.backupRoot,
      createdAt: now.toISOString(),
      updatedAt: now.toISOString(),
      sessions: {},
    };
  }
}

async function writeJsonAtomic(filePath, value) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;

  try {
    await fsp.writeFile(tempPath, `${JSON.stringify(sortedValue(value), null, 2)}\n`, 'utf8');
    await fsp.rename(tempPath, filePath);
  } catch (error) {
    try {
      await fsp.rm(tempPath, { force: true });
    } catch {
      // Best effort cleanup after a failed temp write.
    }
    throw error;
  }
}

function sortedValue(value) {
  if (Array.isArray(value)) {
    return value.map(sortedValue);
  }

  if (!value || typeof value !== 'object') {
    return value;
  }

  return Object.keys(value).sort().reduce((result, key) => {
    result[key] = sortedValue(value[key]);
    return result;
  }, {});
}

async function fileExists(filePath) {
  try {
    await fsp.access(filePath);
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  BackupAgent,
};

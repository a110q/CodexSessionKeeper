'use strict';

const fsp = require('node:fs/promises');
const path = require('node:path');

const { CursorStore } = require('./cursor-store');
const { replaceFileDurably } = require('./durable-write');
const { AGENT_VERSION, MANIFEST_VERSION } = require('./models');
const { loadOrCreateManifest, saveManifest } = require('./manifest-store');
const { sessionIdFromPath, titleFromJsonLine } = require('./session-identity');
const {
  appendCompleteLines,
  rangesMatch,
  rebuildSessionCompleteLines,
  streamStats,
  targetIsCompletePrefix,
} = require('./session-backup-streamer');

const ACTIVE_STATUS = 'active';

class BackupAgent {
  constructor({
    paths,
    now = () => new Date(),
    tailer,
    validateTarget = defaultValidateTarget,
    fileCommitter = createFileCommitter(),
    onProgress = null,
  } = {}) {
    if (!paths) {
      throw new Error('BackupAgent requires paths.');
    }

    this.paths = paths;
    this.now = now;
    this.tailer = tailer || null;
    this.validateTarget = validateTarget;
    this.fileCommitter = fileCommitter;
    this.onProgress = onProgress;
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
    const tick = () => this.performOneShotScan().catch(() => {});
    this.pollingTimer = setInterval(tick, intervalMs);
    this.pollingTimer.unref?.();
    tick();
  }

  stopPolling() {
    if (this.pollingTimer) {
      clearInterval(this.pollingTimer);
      this.pollingTimer = null;
    }
  }

  stop() {
    this.stopPolling();
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
      try {
        result = await this.performOneShotScanLocked();
      } catch (error) {
        await this.writeLocalErrorStatus(error).catch(() => {});
        throw error;
      }
    } while (this.scanQueued);
    return result;
  }

  async performOneShotScanLocked() {
    const scanDate = this.now();

    // Trust and availability must be established before any NAS mutation.
    await this.validateTarget(this.paths);
    await this.ensureStateDirectories();
    await this.ensureRemoteDirectories();

    const manifestExisted = await fileExists(this.paths.manifestPath);
    const cursorStore = new CursorStore({ paths: this.paths });
    await cursorStore.open();

    try {
      const cursorMap = cursorStore.all();
      const manifest = loadOrCreateManifest(this.paths, scanDate);
      let manifestChanged = !manifestExisted;
      for (const [key, value] of [
        ['version', MANIFEST_VERSION],
        ['codexRoot', this.paths.codexRoot],
        ['backupRoot', this.paths.backupRoot],
      ]) {
        if (manifest[key] !== value) {
          manifest[key] = value;
          manifestChanged = true;
        }
      }

      const sources = await this.discoverSessionFiles();
      const phase = manifestExisted ? 'scanning' : 'seeding';
      this.onProgress?.({
        totalFiles: sources.length,
        completedFiles: 0,
        pendingFiles: sources.length,
        phase,
      });
      const processedSessionIds = new Set();
      const updatedCursors = [];
      const scanErrors = [];
      let completedFiles = 0;
      for (const sourcePath of sources) {
        const sessionId = sessionIdFromPath(sourcePath);
        if (!sessionId || processedSessionIds.has(sessionId)) {
          continue;
        }
        processedSessionIds.add(sessionId);

        const result = await this.processSessionFile({
          currentCursor: cursorMap.get(sourcePath) || null,
          cursorMap,
          manifest,
          scanDate,
          sessionId,
          sourcePath,
        });
        manifestChanged ||= result.manifestChanged;
        if (result.cursor) {
          updatedCursors.push(result.cursor);
          cursorMap.set(sourcePath, result.cursor);
        }
        if (result.lastError) {
          scanErrors.push(result.lastError);
        }
        completedFiles += 1;
        this.onProgress?.({
          totalFiles: sources.length,
          completedFiles,
          pendingFiles: Math.max(1, sources.length - completedFiles),
          phase,
        });
      }

      if (manifestChanged) {
        manifest.updatedAt = scanDate.toISOString();
        await saveManifest(this.paths, manifest);
      }
      await cursorStore.upsertMany(updatedCursors);

      const lastError = scanErrors[0] || null;
      await this.writeStatus(manifest, lastError ? 'error' : 'running', lastError, scanDate);
      await replaceFileDurably(this.paths.pendingSourcesPath, jsonPayload({ pending: [] }));
      this.onProgress?.({
        totalFiles: sources.length,
        completedFiles: sources.length,
        pendingFiles: 0,
        phase,
      });
      return manifest;
    } finally {
      await cursorStore.close();
    }
  }

  async ensureStateDirectories() {
    await fsp.mkdir(this.paths.stateRoot, { recursive: true });
    await fsp.mkdir(this.paths.logsRoot, { recursive: true });
  }

  async ensureRemoteDirectories() {
    await ensureDirectChildDirectory(this.paths.backupRoot, this.paths.sessionsRoot);
    await ensureDirectChildDirectory(this.paths.backupRoot, this.paths.archivedSessionsRoot);
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
      .sort((lhs, rhs) => lhs.priority - rhs.priority || lhs.filePath.localeCompare(rhs.filePath))
      .map((entry) => entry.filePath);
  }

  async processSessionFile({ sourcePath, sessionId, scanDate, manifest, currentCursor, cursorMap }) {
    const sourceStats = await trustedSourceMetadata(sourcePath);
    const existingRecord = manifest.sessions[sessionId] || null;
    const baselineCursor = currentCursor || this.migratedCursor(existingRecord, sourcePath, cursorMap);
    const backupPath = this.backupFilePathFor(sourcePath, existingRecord, baselineCursor);
    const relativeBackupPath = this.validatedRelativeBackupPath(backupPath);
    if (scanIsStrictlyUnchanged({
      sourcePath,
      relativeBackupPath,
      sourceStats,
      record: existingRecord,
      cursor: currentCursor,
    })) {
      return {
        manifestChanged: false,
        cursor: null,
        lastError: currentCursor?.lastError || null,
      };
    }

    const targetState = await this.fileCommitter.inspectTarget(backupPath);
    const recordedLines = Number(baselineCursor?.lineCount ?? existingRecord?.lineCount ?? 0);
    const recordedOffset = Number(baselineCursor?.lastByteOffset ?? 0);
    const metadataAgrees = Boolean(
      baselineCursor
      && sourceStats.size > baselineCursor.lastSourceSize
      && sourceStats.size >= baselineCursor.lastByteOffset
      && existingRecord?.bytesBackedUp === baselineCursor.lastByteOffset
      && existingRecord?.lineCount === baselineCursor.lineCount
    );
    const pathAgrees = Boolean(
      baselineCursor
      && baselineCursor.backupPath === relativeBackupPath
      && existingRecord?.backupPath === relativeBackupPath
      && existingRecord?.sourcePath === sourcePath
    );
    let rebuild = !targetState.exists;
    let readOffset = recordedOffset;
    let baseLineCount = recordedLines;

    if (targetState.exists) {
      if (metadataAgrees && pathAgrees && targetState.byteCount === recordedOffset) {
        rebuild = false;
      } else {
        const canAdoptPrefix = targetState.byteCount <= sourceStats.size
          && ((!baselineCursor && !existingRecord) || targetState.byteCount > recordedOffset);
        if (canAdoptPrefix && await this.fileCommitter.targetIsCompletePrefix(
          backupPath,
          sourcePath,
          targetState.byteCount,
        )) {
          rebuild = false;
          readOffset = targetState.byteCount;
          baseLineCount = (await this.fileCommitter.stats(backupPath)).lineCount;
        } else {
          rebuild = true;
        }
      }
    }

    if (this.tailer) {
      await this.readTail(sourcePath, rebuild ? 0 : readOffset);
    }

    let streamed;
    let finalStats;
    let finalOffset;
    let wroteData;
    let contentHash;
    if (rebuild) {
      streamed = await this.fileCommitter.rebuildCompleteLines(
        sourcePath,
        backupPath,
        this.paths.backupRoot,
      );
      finalOffset = streamed.committedByteCount;
      finalStats = { byteCount: finalOffset, lineCount: streamed.lineCount };
      wroteData = targetState.exists || finalOffset > 0;
      contentHash = streamed.contentHash;
    } else {
      streamed = await this.fileCommitter.appendCompleteLines(
        sourcePath,
        backupPath,
        readOffset,
        this.paths.backupRoot,
      );
      finalOffset = streamed.committedByteCount;
      if (finalOffset > readOffset && !await this.fileCommitter.rangesMatch(
        sourcePath,
        readOffset,
        backupPath,
        readOffset,
        finalOffset - readOffset,
      )) {
        throw new Error(`Backup range verification failed: ${backupPath}`);
      }
      finalStats = {
        byteCount: finalOffset,
        lineCount: baseLineCount + streamed.lineCount,
      };
      wroteData = streamed.appendedByteCount > 0 || readOffset !== recordedOffset;
      contentHash = finalOffset > recordedOffset ? null : existingRecord?.contentHash ?? null;
    }

    const firstSeenAt = existingRecord?.firstSeenAt || scanDate.toISOString();
    const title = existingRecord?.title
      || streamed.firstTitle
      || await firstTitleInBackup(backupPath);
    const updatedRecord = {
      sessionId,
      sourcePath,
      backupPath: relativeBackupPath,
      title: title || null,
      firstSeenAt,
      lastBackedUpAt: wroteData || (!existingRecord?.lastBackedUpAt && finalStats.lineCount > 0)
        ? scanDate.toISOString()
        : existingRecord?.lastBackedUpAt ?? null,
      lineCount: finalStats.lineCount,
      bytesBackedUp: finalStats.byteCount,
      contentHash,
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
      lastByteOffset: finalOffset,
      lastSourceSize: sourceStats.size,
      lastSourceModifiedAt: sourceStats.modifiedAt,
      lineCount: updatedRecord.lineCount,
      pendingPartialLine: streamed.pendingPartialLine,
      status: ACTIVE_STATUS,
      lastError: streamed.blockedError || null,
      updatedAt: scanDate.getTime() / 1000,
    };

    return {
      manifestChanged,
      cursor: sameCursor(currentCursor, updatedCursor)
        ? null
        : updatedCursor,
      lastError: streamed.blockedError || null,
    };
  }

  migratedCursor(existingRecord, sourcePath, cursorMap) {
    if (!existingRecord?.sourcePath || existingRecord.sourcePath === sourcePath) {
      return null;
    }
    return cursorMap.get(existingRecord.sourcePath) || null;
  }

  backupFilePathFor(sourcePath, existingRecord, baselineCursor) {
    const recordedPath = existingRecord?.backupPath ?? baselineCursor?.backupPath;
    if (!recordedPath) {
      return this.paths.backupFilePath(sourcePath);
    }
    return path.isAbsolute(recordedPath) ? recordedPath : path.join(this.paths.backupRoot, recordedPath);
  }

  validatedRelativeBackupPath(backupPath) {
    const relative = this.paths.relativeBackupPath(backupPath);
    if (!relative) {
      throw new Error(`Backup path is outside backup root: ${backupPath} is not contained in ${this.paths.backupRoot}.`);
    }
    return relative;
  }

  async readTail(sourcePath, offset) {
    if (typeof this.tailer === 'function') {
      return this.tailer(sourcePath, offset);
    }
    return this.tailer.readNewCompleteLines(sourcePath, offset);
  }

  async writeStatus(manifest, status, lastError, date) {
    const existingStatus = await loadStatus(this.paths.localStatusPath);
    const records = Object.values(manifest.sessions || {});
    const snapshot = {
      agentVersion: AGENT_VERSION,
      enabled: true,
      status,
      mode: 'polling',
      codexRoot: this.paths.codexRoot,
      backupRoot: this.paths.backupRoot,
      firstRunAt: existingStatus?.firstRunAt ?? date.toISOString(),
      lastStartedAt: this.pollingStartedAt?.toISOString() ?? existingStatus?.lastStartedAt ?? date.toISOString(),
      lastHeartbeatAt: date.toISOString(),
      lastBackupAt: maxIsoDate(records.map((record) => record.lastBackedUpAt)),
      sessionCount: records.length,
      lineCount: records.reduce((total, record) => total + Number(record.lineCount ?? 0), 0),
      bytesBackedUp: records.reduce((total, record) => total + Number(record.bytesBackedUp ?? 0), 0),
      autoStartEnabled: false,
      lastError,
    };

    await replaceFileDurably(this.paths.remoteStatusPath, jsonPayload(snapshot));
    await replaceFileDurably(this.paths.localStatusPath, jsonPayload(snapshot));
  }

  async writeLocalErrorStatus(error) {
    await this.ensureStateDirectories();
    const date = this.now();
    const existing = await loadStatus(this.paths.localStatusPath);
    const snapshot = {
      ...(existing || {}),
      agentVersion: AGENT_VERSION,
      enabled: true,
      status: 'error',
      mode: 'polling',
      codexRoot: this.paths.codexRoot,
      backupRoot: this.paths.backupRoot,
      firstRunAt: existing?.firstRunAt ?? date.toISOString(),
      lastHeartbeatAt: date.toISOString(),
      lastError: error?.message || String(error),
    };
    await replaceFileDurably(this.paths.localStatusPath, jsonPayload(snapshot));
  }

  async pendingSessionCount() {
    await this.ensureStateDirectories();
    const store = new CursorStore({ paths: this.paths });
    await store.open();
    try {
      const pending = [];
      for (const sourcePath of await this.discoverSessionFiles()) {
        const cursor = await store.get(sourcePath);
        const metadata = await trustedSourceMetadata(sourcePath);
        if (!cursor || cursor.lastSourceSize !== metadata.size || cursor.lastSourceModifiedAt !== metadata.modifiedAt) {
          pending.push({ sourcePath, size: metadata.size, modifiedAt: metadata.modifiedAt });
        }
      }
      await replaceFileDurably(this.paths.pendingSourcesPath, jsonPayload({ pending }));
      return pending.length;
    } finally {
      await store.close();
    }
  }
}

function createFileCommitter({ sync = (handle) => handle.sync() } = {}) {
  return {
    async inspectTarget(targetPath) {
      try {
        const stats = await fsp.lstat(targetPath);
        if (!stats.isFile() || stats.isSymbolicLink()) {
          throw new Error(`Backup target is not a trusted regular file: ${targetPath}`);
        }
        return { exists: true, byteCount: stats.size };
      } catch (error) {
        if (error.code === 'ENOENT') return { exists: false, byteCount: 0 };
        throw error;
      }
    },

    async targetIsCompletePrefix(targetPath, sourcePath, targetByteCount) {
      return targetIsCompletePrefix({ sourcePath, targetPath, targetByteCount });
    },

    async stats(targetPath) {
      return streamStats(targetPath);
    },

    async rangesMatch(sourcePath, sourceOffset, targetPath, targetOffset, length) {
      return rangesMatch({ sourcePath, sourceOffset, targetPath, targetOffset, length });
    },

    async appendCompleteLines(sourcePath, targetPath, sourceOffset, backupRoot) {
      await assertContainedTarget(backupRoot, targetPath);
      return appendCompleteLines({ sourcePath, sourceOffset, targetPath, sync });
    },

    async rebuildCompleteLines(sourcePath, targetPath, backupRoot) {
      await ensureContainedParent(backupRoot, targetPath);
      return rebuildSessionCompleteLines({ sourcePath, targetPath, sync });
    },
  };
}

async function defaultValidateTarget(paths) {
  let stats;
  try {
    stats = await fsp.lstat(paths.backupRoot);
  } catch (error) {
    if (error.code === 'ENOENT') {
      throw new Error(`NAS backup root is unavailable or missing: ${paths.backupRoot}`);
    }
    throw error;
  }
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new Error(`NAS backup root is unavailable or unsafe: ${paths.backupRoot}`);
  }
}

async function ensureDirectChildDirectory(root, child) {
  if (path.dirname(child) !== root) {
    throw new Error(`Managed backup directory is not a direct child of backup root: ${child}`);
  }
  try {
    await fsp.mkdir(child);
  } catch (error) {
    if (error.code !== 'EEXIST') {
      throw error;
    }
    const stats = await fsp.lstat(child);
    if (!stats.isDirectory() || stats.isSymbolicLink()) {
      throw new Error(`Managed backup directory is unsafe: ${child}`);
    }
  }
}

async function ensureContainedParent(root, targetPath) {
  const relative = path.relative(path.resolve(root), path.resolve(path.dirname(targetPath)));
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`Backup target is outside backup root: ${targetPath}`);
  }

  let current = path.resolve(root);
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    try {
      await fsp.mkdir(current);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const stats = await fsp.lstat(current);
    if (!stats.isDirectory() || stats.isSymbolicLink()) {
      throw new Error(`Backup target parent is unsafe: ${targetPath}`);
    }
  }
}

async function assertContainedTarget(root, targetPath) {
  await ensureContainedParent(root, targetPath);
  const stats = await fsp.lstat(targetPath);
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw new Error(`Backup target is unsafe: ${targetPath}`);
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

async function trustedSourceMetadata(sourcePath) {
  const stats = await fsp.lstat(sourcePath);
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw new Error(`Session source is not a trusted regular file: ${sourcePath}`);
  }
  return { modifiedAt: stats.mtimeMs / 1000, size: stats.size };
}

async function firstTitleInBackup(filePath) {
  try {
    const content = await readPrefix(filePath, 256 * 1024);
    for (const line of content.toString('utf8').split('\n')) {
      const title = titleFromJsonLine(line);
      if (title) return title;
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return null;
}

async function readPrefix(filePath, byteCount) {
  return readRange(filePath, 0, byteCount);
}

async function readRange(filePath, position, byteCount) {
  if (byteCount <= 0) return Buffer.alloc(0);
  const handle = await fsp.open(filePath, 'r');
  const buffer = Buffer.allocUnsafe(byteCount);
  let offset = 0;
  try {
    while (offset < byteCount) {
      const { bytesRead } = await handle.read(buffer, offset, byteCount - offset, position + offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
  } finally {
    await handle.close();
  }
  return buffer.subarray(0, offset);
}

function scanIsStrictlyUnchanged({
  sourcePath,
  relativeBackupPath,
  sourceStats,
  record,
  cursor,
}) {
  if (!record || !cursor
    || record.sourcePath !== sourcePath
    || cursor.sourcePath !== sourcePath
    || record.backupPath !== relativeBackupPath
    || cursor.backupPath !== relativeBackupPath
    || record.bytesBackedUp !== cursor.lastByteOffset
    || record.lineCount !== cursor.lineCount
    || cursor.lastByteOffset < 0
    || cursor.lastByteOffset > sourceStats.size
    || cursor.lastSourceSize !== sourceStats.size
    || cursor.lastSourceModifiedAt !== sourceStats.modifiedAt) {
    return false;
  }

  const hasUncommittedBytes = sourceStats.size > cursor.lastByteOffset;
  if (hasUncommittedBytes) {
    return Boolean(cursor.pendingPartialLine) || cursor.lastError != null;
  }
  return !cursor.pendingPartialLine && cursor.lastError == null;
}

function sameRecord(lhs, rhs) {
  if (!lhs) return false;
  return ['sessionId', 'sourcePath', 'backupPath', 'title', 'firstSeenAt', 'lastBackedUpAt',
    'lineCount', 'bytesBackedUp', 'contentHash', 'status'].every((key) => lhs[key] === rhs[key]);
}

function sameCursor(lhs, rhs) {
  if (!lhs) return false;
  return ['sessionId', 'sourcePath', 'backupPath', 'lastByteOffset', 'lastSourceSize',
    'lastSourceModifiedAt', 'lineCount', 'pendingPartialLine', 'status', 'lastError']
    .every((key) => lhs[key] === rhs[key]);
}

function maxIsoDate(values) {
  return values.filter(Boolean).sort((a, b) => new Date(b) - new Date(a))[0] || null;
}

async function loadStatus(statusPath) {
  try {
    return JSON.parse(await fsp.readFile(statusPath, 'utf8'));
  } catch {
    return null;
  }
}

function sortedValue(value) {
  if (Array.isArray(value)) return value.map(sortedValue);
  if (!value || typeof value !== 'object') return value;
  return Object.keys(value).sort().reduce((result, key) => {
    result[key] = sortedValue(value[key]);
    return result;
  }, {});
}

function jsonPayload(value) {
  return `${JSON.stringify(sortedValue(value), null, 2)}\n`;
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
  createFileCommitter,
};

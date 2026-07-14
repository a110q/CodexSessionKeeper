'use strict';

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');
const path = require('node:path');

const { CursorStore } = require('./cursor-store');
const { replaceFileDurably, writeFileDurably } = require('./durable-write');
const { AGENT_VERSION, MANIFEST_VERSION } = require('./models');
const { loadOrCreateManifest, saveManifest } = require('./manifest-store');
const { readNewCompleteLines } = require('./session-tailer');
const { sessionIdFromPath, titleFromJsonLine } = require('./session-identity');

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
    this.tailer = tailer || { readNewCompleteLines };
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
    const mappedBackupPath = this.paths.backupFilePath(sourcePath);
    const backupPath = this.backupFilePathFor(sourcePath, existingRecord, baselineCursor);
    const relativeBackupPath = this.validatedRelativeBackupPath(backupPath);
    const mappedRelativePath = this.validatedRelativeBackupPath(mappedBackupPath);
    const targetState = await this.fileCommitter.inspectTarget(backupPath);
    const recordedBytes = Number(existingRecord?.bytesBackedUp ?? 0);
    const recordedLines = Number(existingRecord?.lineCount ?? 0);
    const recordedOffset = Number(baselineCursor?.lastByteOffset ?? 0);
    const pathChanged = Boolean(existingRecord && existingRecord.backupPath !== mappedRelativePath);
    let rebuild = pathChanged || sourceStats.size < recordedOffset;
    let readOffset = recordedOffset;
    let baseLineCount = recordedLines;

    if (targetState.exists && !rebuild) {
      if (targetState.byteCount === recordedBytes) {
        if (existingRecord?.contentHash && recordedOffset > 0) {
          rebuild = await hashPrefix(sourcePath, recordedOffset) !== existingRecord.contentHash
            || !await this.fileCommitter.targetMatchesBoundedFingerprint(
              backupPath,
              sourcePath,
              recordedBytes,
            );
        } else if (targetState.byteCount > 0) {
          rebuild = !await this.fileCommitter.targetIsCompletePrefix(backupPath, sourcePath);
        }
      } else if (
        targetState.byteCount > recordedBytes
        && await this.fileCommitter.targetIsCompletePrefix(backupPath, sourcePath)
      ) {
        readOffset = targetState.byteCount;
        baseLineCount = (await this.fileCommitter.stats(backupPath)).lineCount;
      } else {
        rebuild = true;
      }
    } else if (!targetState.exists && (recordedOffset > 0 || recordedBytes > 0)) {
      rebuild = true;
    }

    let tailResult;
    let finalStats;
    let wroteData;
    if (rebuild) {
      tailResult = await this.readTail(sourcePath, 0);
      finalStats = await this.fileCommitter.rebuildCompleteLines(
        backupPath,
        tailResult.lines,
        this.paths.backupRoot,
      );
      wroteData = true;
    } else {
      tailResult = await this.readTail(sourcePath, readOffset);
      if (targetState.exists) {
        finalStats = await this.fileCommitter.appendAndSynchronize(
          backupPath,
          tailResult.lines,
          this.paths.backupRoot,
        );
      } else {
        finalStats = await this.fileCommitter.commitInitial(
          backupPath,
          tailResult.lines,
          this.paths.backupRoot,
        );
      }
      wroteData = tailResult.lines.length > 0 || targetState.byteCount !== recordedBytes;
    }

    const finalOffset = tailResult.nextOffset;
    const contentHash = finalOffset > 0 ? await hashPrefix(sourcePath, finalOffset) : null;
    const firstSeenAt = existingRecord?.firstSeenAt || scanDate.toISOString();
    const title = existingRecord?.title
      || firstTitle(tailResult.lines)
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
      lineCount: rebuild || !targetState.exists
        ? finalStats.lineCount
        : Math.max(baseLineCount + tailResult.lines.length, baseLineCount),
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
      pendingPartialLine: tailResult.pendingPartialLine,
      status: ACTIVE_STATUS,
      lastError: tailResult.blockedError || null,
      updatedAt: scanDate.getTime() / 1000,
    };

    return {
      manifestChanged,
      cursor: sameCursor(currentCursor, updatedCursor)
        ? null
        : updatedCursor,
      lastError: tailResult.blockedError || null,
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
  const lineBuffer = (lines) => Buffer.from(lines.length ? `${lines.join('\n')}\n` : '', 'utf8');

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

    async targetIsCompletePrefix(targetPath, sourcePath) {
      const target = await fsp.readFile(targetPath);
      const sourcePrefix = await readPrefix(sourcePath, target.length);
      return target.equals(sourcePrefix) && (target.length === 0 || target[target.length - 1] === 0x0A);
    },

    async targetMatchesBoundedFingerprint(targetPath, sourcePath, byteCount) {
      if (byteCount === 0) return true;
      const window = Math.min(64 * 1024, byteCount);
      const [targetFirst, sourceFirst, targetLast, sourceLast] = await Promise.all([
        readRange(targetPath, 0, window),
        readRange(sourcePath, 0, window),
        readRange(targetPath, byteCount - window, window),
        readRange(sourcePath, byteCount - window, window),
      ]);
      return targetFirst.equals(sourceFirst) && targetLast.equals(sourceLast);
    },

    async stats(targetPath) {
      const content = await fsp.readFile(targetPath);
      return {
        byteCount: content.length,
        lineCount: countNewlines(content),
      };
    },

    async commitInitial(targetPath, lines, backupRoot) {
      const content = lineBuffer(lines);
      if (content.length > 0) {
        await ensureContainedParent(backupRoot, targetPath);
        await writeFileDurably(targetPath, content, { sync });
      }
      return { byteCount: content.length, lineCount: lines.length };
    },

    async appendAndSynchronize(targetPath, lines, backupRoot) {
      const before = await this.stats(targetPath);
      if (lines.length === 0) return before;
      await assertContainedTarget(backupRoot, targetPath);
      const content = lineBuffer(lines);
      const handle = await fsp.open(targetPath, 'a');
      try {
        await handle.writeFile(content);
        await sync(handle);
      } finally {
        await handle.close();
      }
      return {
        byteCount: before.byteCount + content.length,
        lineCount: before.lineCount + lines.length,
      };
    },

    async rebuildCompleteLines(targetPath, lines, backupRoot) {
      const content = lineBuffer(lines);
      await ensureContainedParent(backupRoot, targetPath);
      if (await fileExists(targetPath)) {
        await replaceFileDurably(targetPath, content, { sync });
      } else if (content.length > 0) {
        await writeFileDurably(targetPath, content, { sync });
      }
      return { byteCount: content.length, lineCount: lines.length };
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

function firstTitle(lines) {
  for (const line of lines) {
    const title = titleFromJsonLine(line);
    if (title) {
      return title;
    }
  }
  return null;
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

async function hashPrefix(filePath, byteCount) {
  const handle = await fsp.open(filePath, 'r');
  const hash = crypto.createHash('sha256');
  let offset = 0;
  try {
    while (offset < byteCount) {
      const buffer = Buffer.allocUnsafe(Math.min(1024 * 1024, byteCount - offset));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, offset);
      if (bytesRead === 0) break;
      hash.update(buffer.subarray(0, bytesRead));
      offset += bytesRead;
    }
  } finally {
    await handle.close();
  }
  if (offset !== byteCount) {
    throw new Error(`Source file became shorter while hashing: ${filePath}`);
  }
  return hash.digest('hex');
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

function countNewlines(content) {
  let total = 0;
  for (const byte of content) {
    if (byte === 0x0A) total += 1;
  }
  return total;
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

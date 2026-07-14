'use strict';

const fsp = require('node:fs/promises');
const path = require('node:path');

const { CursorStore } = require('./cursor-store');
const { replaceFileDurably } = require('./durable-write');
const {
  BackupIntegrityAuditor,
  dailyOffsetSeconds,
  overdueWakeDelaySeconds,
} = require('./integrity-auditor');
const { AGENT_VERSION, MANIFEST_VERSION } = require('./models');
const { loadOrCreateManifest, saveManifest } = require('./manifest-store');
const { sessionIdFromPath } = require('./session-identity');
const {
  appendCompleteLines,
  rangesMatch,
  rebuildSessionCompleteLines,
  verifyCompletePrefix,
} = require('./session-backup-streamer');

const ACTIVE_STATUS = 'active';
const AUDIT_INTERVAL_MS = 86400 * 1000;

class BackupAgent {
  constructor({
    paths,
    now = () => new Date(),
    validateTarget = defaultValidateTarget,
    fileCommitter = createFileCommitter(),
    initialStatus = null,
    onProgress = null,
    onStatus = null,
    instrumentation = {},
    deviceId = null,
    integrityAuditorFactory = (auditorPaths) => new BackupIntegrityAuditor({ paths: auditorPaths }),
    auditDelayProvider = auditDelayMilliseconds,
    auditTimerScheduler = setTimeout,
    cancelAuditTimer = clearTimeout,
    scheduleInterval = setInterval,
    cancelInterval = clearInterval,
  } = {}) {
    if (!paths) {
      throw new Error('BackupAgent requires paths.');
    }

    this.paths = paths;
    this.now = now;
    this.validateTarget = validateTarget;
    this.fileCommitter = fileCommitter;
    this.cachedStatus = initialStatus ? { ...initialStatus } : null;
    this.auditLastCompletedAt = initialStatus?.lastAuditAt ?? null;
    this.onProgress = onProgress;
    this.onStatus = onStatus;
    this.instrumentation = instrumentation;
    this.deviceId = deviceId;
    this.integrityAuditorFactory = integrityAuditorFactory;
    this.auditDelayProvider = auditDelayProvider;
    this.auditTimerScheduler = auditTimerScheduler;
    this.cancelAuditTimer = cancelAuditTimer;
    this.scheduleInterval = scheduleInterval;
    this.cancelInterval = cancelInterval;
    this.pollingTimer = null;
    this.pollingStartedAt = null;
    this.pollingGeneration = 0;
    this.scanPromise = null;
    this.scanQueued = false;
    this.auditPromise = null;
    this.auditScanDeferred = null;
    this.auditInterruptionEpoch = 0;
    this.auditTimer = null;
    this.auditTimerGeneration = 0;
    this.startupOrphanCleanupComplete = false;
    this.stopped = false;
  }

  startPolling(intervalMs = 30000) {
    if (this.stopped || this.pollingTimer) {
      return;
    }

    this.pollingStartedAt = this.now();
    this.pollingGeneration += 1;
    const generation = this.pollingGeneration;
    const tick = () => {
      if (this.stopped || generation !== this.pollingGeneration) return Promise.resolve(null);
      return this.requestImmediateScan('timer').catch(() => {});
    };
    this.pollingTimer = this.scheduleInterval(tick, intervalMs);
    this.pollingTimer.unref?.();
  }

  stopPolling() {
    this.pollingGeneration += 1;
    if (this.pollingTimer) {
      this.cancelInterval(this.pollingTimer);
      this.pollingTimer = null;
    }
  }

  stop() {
    if (this.stopped) return;
    this.stopped = true;
    this.scanQueued = false;
    this.requestAuditInterruption();
    this.stopAuditTimer();
    this.stopPolling();
  }

  async stopAndAwaitQuiescence(timeoutMs = 100) {
    this.stop();
    const active = [this.scanPromise, this.auditPromise].filter(Boolean);
    if (active.length === 0) return true;
    let timeout;
    try {
      return await Promise.race([
        Promise.allSettled(active).then(() => true),
        new Promise((resolve) => {
          timeout = setTimeout(() => resolve(false), Math.max(0, timeoutMs));
          timeout.unref?.();
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  requestImmediateScan(trigger) {
    if (this.stopped) return Promise.resolve(null);
    this.instrumentation.scanRequested?.(trigger);
    const scan = this.performOneShotScan();
    return scan.finally(() => {
      if (this.stopped) return;
      if (trigger === 'wake') this.scheduleAudit(true);
      else this.ensureAuditScheduled();
    });
  }

  async performOneShotScan() {
    if (this.stopped) return null;
    this.requestAuditInterruption();
    if (this.auditPromise) {
      if (!this.auditScanDeferred) this.auditScanDeferred = deferredPromise();
      return this.auditScanDeferred.promise;
    }
    return this.startOneShotScan();
  }

  async startOneShotScan() {
    if (this.stopped) return null;
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

  async performIntegrityAuditIfDue(deviceId, scheduledBaselineEpoch = null) {
    if (this.stopped) return interruptedAuditOutcome();
    if (this.auditPromise) return this.auditPromise;
    let baselineEpoch = scheduledBaselineEpoch;
    if (baselineEpoch === null) {
      await this.performOneShotScan();
      baselineEpoch = this.auditInterruptionEpoch;
    } else {
      if (baselineEpoch !== this.auditInterruptionEpoch) return interruptedAuditOutcome();
      await this.startOneShotScan();
    }
    if (this.stopped || baselineEpoch !== this.auditInterruptionEpoch) {
      return interruptedAuditOutcome();
    }
    if (this.auditPromise) return this.auditPromise;
    this.auditPromise = this.performIntegrityAuditLocked(deviceId, baselineEpoch);
    try {
      return await this.auditPromise;
    } finally {
      this.auditPromise = null;
      const deferred = this.auditScanDeferred;
      this.auditScanDeferred = null;
      if (deferred) {
        if (this.stopped) deferred.resolve(null);
        else this.startOneShotScan().then(deferred.resolve, deferred.reject);
      }
    }
  }

  ensureAuditScheduled() {
    if (this.stopped || !this.deviceId || this.auditTimer || this.auditPromise) return;
    this.scheduleAudit(false);
  }

  scheduleAudit(replacingExisting) {
    if (this.stopped || !this.deviceId) return;
    if (!replacingExisting && this.auditTimer) return;
    const previousTimer = this.auditTimer;
    this.auditTimer = null;
    this.auditTimerGeneration += 1;
    const generation = this.auditTimerGeneration;
    const delay = normalizedTimerDelay(this.auditDelayProvider(
      this.now(),
      this.auditLastCompletedAt,
      this.deviceId,
    ));
    const action = () => {
      const work = this.runScheduledAudit(generation);
      void work.catch(() => {});
      return work;
    };
    const timer = this.auditTimerScheduler(action, delay);
    this.auditTimer = timer;
    timer?.unref?.();
    if (previousTimer) this.cancelAuditTimer(previousTimer);
  }

  async runScheduledAudit(generation) {
    if (this.stopped || generation !== this.auditTimerGeneration) return null;
    this.auditTimer = null;
    const baselineEpoch = this.auditInterruptionEpoch;
    try {
      this.instrumentation.auditWillStart?.();
      const outcome = await this.performIntegrityAuditIfDue(this.deviceId, baselineEpoch);
      this.instrumentation.auditDidFinish?.(outcome);
      return outcome;
    } finally {
      if (!this.stopped && generation === this.auditTimerGeneration) {
        this.scheduleAudit(true);
      }
    }
  }

  stopAuditTimer() {
    this.auditTimerGeneration += 1;
    const timer = this.auditTimer;
    this.auditTimer = null;
    if (timer) this.cancelAuditTimer(timer);
  }

  async performIntegrityAuditLocked(deviceId, baselineEpoch) {
    if (this.stopped || this.auditInterruptionEpoch !== baselineEpoch) {
      return interruptedAuditOutcome();
    }
    const cursorStore = new CursorStore({ paths: this.paths });
    await cursorStore.open();
    try {
      const outcome = await this.integrityAuditorFactory(this.paths).runIfDue({
        now: this.now(),
        deviceId,
        cursors: cursorStore.all(),
        interruptionRequested: () => this.auditInterruptionEpoch !== baselineEpoch,
      });
      if (outcome?.outcome !== 'interrupted') {
        await this.publishPersistedStatusIfAvailable();
      }
      return outcome;
    } catch (error) {
      await this.writeLocalErrorStatus(error).catch(() => {});
      throw error;
    } finally {
      await cursorStore.close();
    }
  }

  async drainScanQueue() {
    let result;
    for (let scanIndex = 0; scanIndex < 2 && !this.stopped; scanIndex += 1) {
      this.scanQueued = false;
      try {
        result = await this.performOneShotScanLocked();
      } catch (error) {
        await this.writeLocalErrorStatus(error).catch(() => {});
        throw error;
      }
      if (!this.scanQueued || scanIndex === 1) break;
    }
    this.scanQueued = false;
    return result;
  }

  async performOneShotScanLocked() {
    const scanDate = this.now();

    // Trust and availability must be established before any NAS mutation.
    await this.validateTarget(this.paths);
    await this.ensureStateDirectories();
    await this.ensureRemoteDirectories();

    const integrityAuditor = this.integrityAuditorFactory(this.paths);
    await integrityAuditor.recoverPendingRepairIfNeeded({
      now: scanDate,
      cleanupOrphans: !this.startupOrphanCleanupComplete,
    });
    this.startupOrphanCleanupComplete = true;
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
      let interrupted = false;
      let remainingSources = [];
      for (let sourceIndex = 0; sourceIndex < sources.length; sourceIndex += 1) {
        if (this.stopped) {
          interrupted = true;
          remainingSources = sources.slice(sourceIndex);
          break;
        }
        const sourcePath = sources[sourceIndex];
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
          pendingFiles: Math.max(0, sources.length - completedFiles),
          phase,
        });
        if (this.stopped && sourceIndex + 1 < sources.length) {
          interrupted = true;
          remainingSources = sources.slice(sourceIndex + 1);
          break;
        }
      }

      if (manifestChanged) {
        manifest.updatedAt = scanDate.toISOString();
        await saveManifest(this.paths, manifest);
      }
      await cursorStore.upsertMany(updatedCursors);

      if (interrupted) {
        const pending = await this.pendingRecordsForSources(remainingSources);
        await replaceFileDurably(this.paths.pendingSourcesPath, jsonPayload({ pending }));
        this.onProgress?.({
          totalFiles: sources.length,
          completedFiles,
          pendingFiles: pending.length,
          phase,
        });
        await this.writeStatus(manifest, 'waiting', null, scanDate);
        return manifest;
      }

      const lastError = scanErrors[0] || null;
      this.onProgress?.({
        totalFiles: sources.length,
        completedFiles: sources.length,
        pendingFiles: 0,
        phase,
      });
      await this.writeStatus(manifest, lastError ? 'error' : 'running', lastError, scanDate);
      await replaceFileDurably(this.paths.pendingSourcesPath, jsonPayload({ pending: [] }));
      if (scanErrors.length === 0) {
        await integrityAuditor.recordInitialSeedCompleted(scanDate);
        this.auditLastCompletedAt ??= scanDate.toISOString();
      }
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

  async pendingRecordsForSources(sourcePaths) {
    const pending = [];
    for (const sourcePath of sourcePaths) {
      const metadata = await trustedSourceMetadata(sourcePath);
      pending.push({
        sourcePath,
        size: metadata.size,
        modifiedAt: metadata.modifiedAt,
      });
    }
    return pending;
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
    let adoptedPrefix = null;
    const freshPrefixSeed = !baselineCursor && !existingRecord;

    if (targetState.exists) {
      if (metadataAgrees && pathAgrees && targetState.byteCount === recordedOffset) {
        rebuild = false;
      } else {
        const canAdoptPrefix = targetState.byteCount <= sourceStats.size
          && ((!baselineCursor && !existingRecord) || targetState.byteCount > recordedOffset);
        const prefix = canAdoptPrefix
          ? await this.fileCommitter.verifyCompletePrefix(
            backupPath,
            sourcePath,
            targetState.byteCount,
          )
          : null;
        if (prefix?.matches) {
          if (targetState.byteCount > recordedOffset) {
            await this.fileCommitter.synchronizeTarget(backupPath, this.paths.backupRoot);
          }
          rebuild = false;
          adoptedPrefix = prefix;
          readOffset = targetState.byteCount;
          baseLineCount = prefix.lineCount;
        } else {
          rebuild = true;
        }
      }
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
      const adoptedCompleteSeed = freshPrefixSeed
        && adoptedPrefix
        && streamed.appendedByteCount === 0
        && finalOffset === adoptedPrefix.byteCount;
      if (adoptedCompleteSeed) {
        contentHash = adoptedPrefix.contentHash;
      } else {
        contentHash = finalOffset > recordedOffset ? null : existingRecord?.contentHash ?? null;
      }
    }

    const firstSeenAt = existingRecord?.firstSeenAt || scanDate.toISOString();
    const title = existingRecord?.title
      || adoptedPrefix?.firstTitle
      || streamed.firstTitle
      || null;
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

  async writeStatus(manifest, status, lastError, date) {
    const existingStatus = this.cachedStatus || await loadStatus(this.paths.localStatusPath);
    const auditState = await loadStatus(this.paths.auditStatePath);
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
      lastAuditAt: auditState?.lastCompletedAt ?? existingStatus?.lastAuditAt,
      lastAuditResult: auditState?.lastResult ?? existingStatus?.lastAuditResult,
      lastRepairAt: existingStatus?.lastRepairAt,
      repairCount: auditState?.repairedCount ?? existingStatus?.repairCount,
    };

    await replaceFileDurably(this.paths.remoteStatusPath, jsonPayload(snapshot));
    await replaceFileDurably(this.paths.localStatusPath, jsonPayload(snapshot));
    this.publishStatus(snapshot);
  }

  async writeLocalErrorStatus(error) {
    await this.ensureStateDirectories();
    const date = this.now();
    const existing = this.cachedStatus || await loadStatus(this.paths.localStatusPath);
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
    this.publishStatus(snapshot);
  }

  publishStatus(status) {
    const published = JSON.parse(JSON.stringify(status));
    this.cachedStatus = published;
    this.auditLastCompletedAt = published.lastAuditAt ?? this.auditLastCompletedAt;
    this.onStatus?.({ ...published });
  }

  async publishPersistedStatusIfAvailable() {
    const status = await loadStatus(this.paths.localStatusPath);
    if (status) this.publishStatus(status);
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

  requestAuditInterruption() {
    this.auditInterruptionEpoch += 1;
    this.instrumentation.auditInterruptionSet?.();
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

    async verifyCompletePrefix(targetPath, sourcePath, targetByteCount) {
      return verifyCompletePrefix({ sourcePath, targetPath, targetByteCount });
    },

    async synchronizeTarget(targetPath, backupRoot) {
      await assertContainedTarget(backupRoot, targetPath);
      const handle = await fsp.open(targetPath, 'r+');
      try {
        await sync(handle);
      } finally {
        await handle.close();
      }
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

function deferredPromise() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function interruptedAuditOutcome() {
  return { outcome: 'interrupted', checked: 0, repaired: 0 };
}

function auditDelayMilliseconds(now, lastAuditAt, deviceId) {
  const current = validDate(now);
  const lastAudit = lastAuditAt == null ? null : validDate(lastAuditAt);
  const overdueDelay = overdueWakeDelaySeconds(deviceId) * 1000;
  if (!lastAudit || current.getTime() - lastAudit.getTime() >= AUDIT_INTERVAL_MS) {
    return overdueDelay;
  }

  const startOfUtcDay = Math.floor(current.getTime() / AUDIT_INTERVAL_MS) * AUDIT_INTERVAL_MS;
  const earliestAllowed = lastAudit.getTime() + AUDIT_INTERVAL_MS;
  let candidate = startOfUtcDay + (dailyOffsetSeconds(deviceId) * 1000);
  while (candidate <= current.getTime() || candidate < earliestAllowed) {
    candidate += AUDIT_INTERVAL_MS;
  }
  return candidate - current.getTime();
}

function validDate(value) {
  const date = value instanceof Date ? new Date(value) : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`Invalid audit date: ${String(value)}`);
  return date;
}

function normalizedTimerDelay(value) {
  return Math.max(0, Number.isFinite(Number(value)) ? Number(value) : 0);
}

module.exports = {
  BackupAgent,
  auditDelayMilliseconds,
  createFileCommitter,
};

'use strict';

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');
const path = require('node:path');

const { CursorStore } = require('./cursor-store');
const {
  durableReplaceWithWriter,
  publishSyncedTemporaryFileIfAbsent,
  replaceFileDurably,
} = require('./durable-write');
const { loadOrCreateManifest, saveManifest } = require('./manifest-store');
const { INTEGRITY_REPAIR_JOURNAL_VERSION } = require('./models');
const { assertSafeDestinationPath, assertSafeSourcePath } = require('./restore-filesystem');
const { rebuildSessionCompleteLines } = require('./session-backup-streamer');
const { sessionIdFromPath } = require('./session-identity');

const MAXIMUM_CHUNK_SIZE = 1024 * 1024;
const DEFAULT_CHUNK_SIZE = MAXIMUM_CHUNK_SIZE;
const MAXIMUM_LINE_BYTES = 32 * 1024 * 1024;
const AUDIT_INTERVAL_MS = 86400 * 1000;
const RETENTION_INTERVAL_MS = 30 * AUDIT_INTERVAL_MS;
const MAXIMUM_QUARANTINE_COPIES = 3;
const INTERRUPTED_CODE = 'INTEGRITY_AUDIT_INTERRUPTED';
const FATAL_UTF8_DECODER = new TextDecoder('utf-8', { fatal: true });

function digestWord(deviceId, start) {
  const digest = crypto.createHash('sha256').update(String(deviceId).toLowerCase(), 'utf8').digest();
  return digest.readBigUInt64BE(start);
}

function dailyOffsetSeconds(deviceId) {
  return Number(digestWord(deviceId, 0) % 86400n);
}

function overdueWakeDelaySeconds(deviceId) {
  return Number(digestWord(deviceId, 8) % 1801n);
}

class BackupIntegrityAuditor {
  constructor({
    paths,
    chunkSize = DEFAULT_CHUNK_SIZE,
    sync = (handle) => handle.sync(),
    directorySync = syncParentDirectory,
    instrumentation = {},
    cursorStoreFactory = (storePaths) => new CursorStore({ paths: storePaths }),
  } = {}) {
    if (!paths) throw new Error('BackupIntegrityAuditor requires paths.');
    this.paths = paths;
    this.chunkSize = normalizeChunkSize(chunkSize);
    this.sync = sync;
    this.directorySync = async (directory) => {
      try {
        await directorySync(directory);
      } catch (error) {
        if (!isUnsupportedDirectorySyncError(error)) throw error;
      }
    };
    this.instrumentation = instrumentation;
    this.cursorStoreFactory = cursorStoreFactory;
  }

  async runIfDue({
    now,
    deviceId,
    cursors,
    interruptionRequested = () => false,
  } = {}) {
    const auditDate = dateValue(now);
    void deviceId;
    let state = await this.loadAuditState();
    const pendingRepair = await this.loadPendingRepair();
    if (!pendingRepair && completedWithinInterval(state, auditDate)) {
      await this.validateBackupRoot();
      await this.cleanupOrphanTemporaryFiles();
      return outcome('not-due');
    }

    await this.validateBackupRoot();
    if (!pendingRepair) await this.cleanupQuarantine(auditDate);
    let manifest = loadOrCreateManifest(this.paths, auditDate);
    if (pendingRepair) {
      ({ manifest, state } = await this.resolvePendingRepair({ pendingRepair, manifest, state }));
      await this.cleanupQuarantine(auditDate);
    }
    await this.cleanupOrphanTemporaryFiles();
    if (completedWithinInterval(state, auditDate)) return outcome('not-due');

    const bufferedHashes = new Map();
    let checked = 0;
    let repaired = 0;
    const orderedCursors = normalizedCursors(cursors);
    const currentCursorsBySession = new Map(orderedCursors.flatMap((cursor) => {
      const record = manifest.sessions?.[cursor.sessionId];
      return record
        && cursor.sourcePath === record.sourcePath
        && cursor.backupPath === record.backupPath
        && cursor.lastByteOffset === record.bytesBackedUp
        ? [[cursor.sessionId, cursor]]
        : [];
    }));
    const staleCursorSourcePaths = new Set(orderedCursors.flatMap((cursor) => {
      const record = manifest.sessions?.[cursor.sessionId];
      return record
        && currentCursorsBySession.has(cursor.sessionId)
        && this.isProvenStaleCursor(cursor, record)
        ? [cursor.sourcePath]
        : [];
    }));
    try {
      for (const cursor of orderedCursors) {
        if (staleCursorSourcePaths.has(cursor.sourcePath)) continue;
        this.requireNotInterrupted(interruptionRequested);
        const record = manifest.sessions?.[cursor.sessionId];
        if (!record) throw new Error(`Integrity audit has no manifest record for session: ${cursor.sessionId}`);
        const file = await this.validate(cursor, record);
        const comparison = await this.compareCommittedPrefix(file, interruptionRequested);
        if (comparison.matches) {
          bufferedHashes.set(cursor.sessionId, comparison.hash);
        } else {
          const repair = await this.repair({
            file,
            now: auditDate,
            manifest,
            state,
            interruptionRequested,
          });
          manifest = repair.manifest;
          state = repair.state;
          bufferedHashes.delete(cursor.sessionId);
          repaired += 1;
        }
        checked += 1;
      }
      this.requireNotInterrupted(interruptionRequested);
    } catch (error) {
      if (isInterrupted(error)) return outcome('interrupted', checked, repaired);
      throw error;
    }

    let manifestChanged = false;
    for (const [sessionId, hash] of bufferedHashes) {
      const record = manifest.sessions[sessionId];
      if (record.contentHash === hash) continue;
      manifest.sessions[sessionId] = { ...record, contentHash: hash };
      manifestChanged = true;
    }
    if (manifestChanged) {
      manifest.updatedAt = auditDate.toISOString();
      await saveManifest(this.paths, manifest);
    }
    if (staleCursorSourcePaths.size > 0) {
      const store = this.cursorStoreFactory(this.paths);
      await store.open();
      try {
        await store.upsertMany([], {
          deletingSourcePaths: [...staleCursorSourcePaths],
        });
      } finally {
        await store.close();
      }
    }

    await this.cleanupQuarantine(auditDate);
    state = {
      ...state,
      lastCompletedAt: auditDate.toISOString(),
      lastResult: 'completed',
    };
    await this.updatePersistedStatus({
      lastAuditAt: auditDate,
      lastAuditResult: state.lastResult,
      repairCount: state.repairedCount,
    });
    await this.saveAuditState(state);
    return outcome('completed', checked, repaired);
  }

  async recordInitialSeedCompleted(at) {
    const date = dateValue(at);
    const state = await this.loadAuditState();
    if (state.lastCompletedAt) return;
    await this.saveAuditState({
      ...state,
      lastCompletedAt: date.toISOString(),
      lastResult: 'seeded',
    });
  }

  async recoverPendingRepairIfNeeded({ now, cleanupOrphans = true } = {}) {
    const pendingRepair = await this.loadPendingRepair();
    const auditDate = dateValue(now);
    await this.validateBackupRoot();
    if (pendingRepair) {
      const manifest = loadOrCreateManifest(this.paths, auditDate);
      const state = await this.loadAuditState();
      await this.resolvePendingRepair({ pendingRepair, manifest, state });
      await this.cleanupQuarantine(auditDate);
    }
    if (pendingRepair || cleanupOrphans) await this.cleanupOrphanTemporaryFiles();
  }

  async validateBackupRoot() {
    const stats = await fsp.lstat(this.paths.backupRoot).catch((error) => {
      if (error.code === 'ENOENT') {
        throw new Error(`NAS backup root is unavailable or missing: ${this.paths.backupRoot}`);
      }
      throw error;
    });
    if (!stats.isDirectory() || stats.isSymbolicLink()) {
      throw new Error(`NAS backup root is unavailable or unsafe: ${this.paths.backupRoot}`);
    }
    assertSafeSourcePath(this.paths.backupRoot, path.dirname(this.paths.backupRoot));
  }

  isProvenStaleCursor(cursor, record) {
    if (cursor.sessionId !== record.sessionId
      || cursor.sourcePath === record.sourcePath
      || cursor.backupPath !== record.backupPath) return false;
    try {
      validateWindowsSourceNamespace(cursor.sourcePath);
      const sourcePath = path.resolve(cursor.sourcePath);
      const sourceRoot = sourceRootFor(this.paths, sourcePath);
      assertSafeSourcePath(sourcePath, sourceRoot, { allowMissing: true });
      if (sessionIdFromPath(sourcePath) !== cursor.sessionId) return false;

      const relativeBackupPath = validateRelativeBackupPath(cursor.backupPath);
      if (!['sessions', 'archived_sessions'].includes(relativeBackupPath.split('/')[0])) return false;
      const currentBackupPath = validateRelativeBackupPath(record.backupPath);
      if (relativeBackupPath !== currentBackupPath) return false;

      const targetPath = path.resolve(this.paths.backupRoot, ...relativeBackupPath.split('/'));
      if (validateRelativeBackupPath(this.paths.relativeBackupPath(targetPath)) !== relativeBackupPath) {
        return false;
      }
      assertSafeDestinationPath(targetPath, this.paths.backupRoot);
      return true;
    } catch {
      return false;
    }
  }

  async validate(cursor, record) {
    if (!Number.isSafeInteger(cursor.lastByteOffset) || cursor.lastByteOffset < 0
      || cursor.sessionId !== record.sessionId
      || cursor.sourcePath !== record.sourcePath
      || cursor.backupPath !== record.backupPath
      || cursor.lastByteOffset !== record.bytesBackedUp) {
      throw new Error(`Integrity audit rejected unsafe cursor metadata: ${cursor.sourcePath}`);
    }

    validateWindowsSourceNamespace(cursor.sourcePath);
    const relativeBackupPath = validateRelativeBackupPath(cursor.backupPath);
    if (!['sessions', 'archived_sessions'].includes(relativeBackupPath.split('/')[0])) {
      throw new Error(`Integrity audit rejected unsafe cursor metadata: ${cursor.backupPath}`);
    }
    const sourcePath = path.resolve(cursor.sourcePath);
    const sourceRoot = sourceRootFor(this.paths, sourcePath);
    assertSafeSourcePath(sourcePath, sourceRoot);
    const sourceStats = await fsp.lstat(sourcePath);
    if (!sourceStats.isFile() || sourceStats.isSymbolicLink() || sourceStats.size < cursor.lastByteOffset) {
      throw new Error(`Integrity audit rejected unsafe source: ${sourcePath}`);
    }

    const targetPath = path.resolve(this.paths.backupRoot, ...relativeBackupPath.split('/'));
    const canonicalRelative = validateRelativeBackupPath(this.paths.relativeBackupPath(targetPath));
    if (canonicalRelative !== relativeBackupPath) {
      throw new Error(`Integrity audit rejected unsafe cursor metadata: ${cursor.backupPath}`);
    }
    assertSafeDestinationPath(targetPath, this.paths.backupRoot);
    const targetParent = path.dirname(targetPath);
    assertSafeSourcePath(targetParent, this.paths.backupRoot);
    const parentStats = await fsp.lstat(targetParent);
    if (!parentStats.isDirectory() || parentStats.isSymbolicLink()) {
      throw new Error(`Integrity audit rejected unsafe target parent: ${targetParent}`);
    }
    let targetStats = null;
    try {
      targetStats = await fsp.lstat(targetPath);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (targetStats) {
      assertSafeSourcePath(targetPath, this.paths.backupRoot);
      if (!targetStats.isFile() || targetStats.isSymbolicLink()) {
        throw new Error(`Integrity audit rejected unsafe target: ${targetPath}`);
      }
    }
    return {
      cursor,
      record,
      sourcePath,
      targetPath,
      targetExists: Boolean(targetStats),
      targetByteCount: targetStats?.size ?? 0,
    };
  }

  async compareCommittedPrefix(file, interruptionRequested) {
    if (!file.targetExists || file.targetByteCount !== file.cursor.lastByteOffset) {
      return { matches: false };
    }
    const sourceHandle = await fsp.open(file.sourcePath, 'r');
    let targetHandle;
    const digest = crypto.createHash('sha256');
    try {
      targetHandle = await fsp.open(file.targetPath, 'r');
      let offset = 0;
      while (offset < file.cursor.lastByteOffset) {
        this.requireNotInterrupted(interruptionRequested);
        const count = Math.min(this.chunkSize, file.cursor.lastByteOffset - offset);
        const [source, target] = await Promise.all([
          readExactly(sourceHandle, offset, count),
          readExactly(targetHandle, offset, count),
        ]);
        await this.didReadChunk(file.sourcePath, offset, source.length);
        await this.didStreamChunk('comparison', file.sourcePath, offset, source.length);
        this.requireNotInterrupted(interruptionRequested);
        if (source.length !== count || target.length !== count || !source.equals(target)) {
          return { matches: false };
        }
        digest.update(source);
        offset += count;
      }
      this.requireNotInterrupted(interruptionRequested);
      return { matches: true, hash: digest.digest('hex') };
    } finally {
      await targetHandle?.close().catch(() => {});
      await sourceHandle.close().catch(() => {});
    }
  }

  async repair({ file, now, manifest, state, interruptionRequested }) {
    const currentRecord = requiredRecord(manifest, file.cursor.sessionId);
    const revalidated = await this.validate(file.cursor, currentRecord);
    const repairTemporary = path.join(
      path.dirname(revalidated.targetPath),
      `.${path.basename(revalidated.targetPath)}.repair-${crypto.randomUUID()}`,
    );
    let quarantine;
    let repairHash;
    try {
      const rebuilt = await rebuildSessionCompleteLines({
        sourcePath: revalidated.sourcePath,
        targetPath: repairTemporary,
        maximumOffset: revalidated.cursor.lastByteOffset,
        chunkSize: this.chunkSize,
        interruptionRequested,
        onChunk: async (offset, length) => {
          await this.didStreamChunk('repairTemporary', revalidated.sourcePath, offset, length);
        },
        sync: async (handle) => {
          await this.checkpoint('beforeTemporaryFlush');
          await this.sync(handle);
        },
      });
      if (rebuilt.committedByteCount !== revalidated.cursor.lastByteOffset
        || rebuilt.pendingPartialLine || rebuilt.blockedError) {
        throw new Error(`Integrity repair rejected structurally invalid committed JSONL: ${revalidated.sourcePath}`);
      }
      repairHash = rebuilt.contentHash;
      await this.verifyFile(repairTemporary, {
        expectedByteCount: revalidated.cursor.lastByteOffset,
        expectedHash: repairHash,
        phase: 'repairTemporaryVerification',
        interruptionRequested,
        validateJSON: true,
      });

      if (!revalidated.targetExists) {
        return await this.installMissingTarget({
          file: revalidated,
          repairTemporary,
          repairHash,
          now,
          manifest,
          state,
          interruptionRequested,
        });
      }

      await this.checkpoint('beforeQuarantineCopy');
      quarantine = await this.quarantineCurrentTarget({
        targetPath: revalidated.targetPath,
        sessionId: revalidated.cursor.sessionId,
        now,
        interruptionRequested,
      });
      await this.checkpoint('beforeReplace');
      await this.verifyFile(revalidated.targetPath, {
        expectedByteCount: quarantine.byteCount,
        expectedHash: quarantine.hash,
        phase: 'formalPreReplacementVerification',
        interruptionRequested,
      });
      this.requireNotInterrupted(interruptionRequested);
    } catch (error) {
      await fsp.rm(repairTemporary, { force: true }).catch(() => {});
      throw error;
    }

    const quarantineBackupPath = this.paths.relativeBackupPath(quarantine.filePath);
    if (!quarantineBackupPath) throw new Error(`Unsafe quarantine path: ${quarantine.filePath}`);
    const repairTemporaryBackupPath = this.paths.relativeBackupPath(repairTemporary);
    if (!repairTemporaryBackupPath) throw new Error(`Unsafe repair temporary path: ${repairTemporary}`);
    let pendingRepair = {
      version: INTEGRITY_REPAIR_JOURNAL_VERSION,
      phase: 'prepared',
      sessionId: revalidated.cursor.sessionId,
      sourcePath: revalidated.cursor.sourcePath,
      backupPath: revalidated.cursor.backupPath,
      byteCount: revalidated.cursor.lastByteOffset,
      contentHash: repairHash,
      originalByteCount: quarantine.byteCount,
      originalContentHash: quarantine.hash,
      quarantineBackupPath,
      repairTemporaryBackupPath,
      repairedAt: now.toISOString(),
      repairedCount: Number(state.repairedCount || 0) + 1,
    };
    try {
      await this.savePendingRepair(pendingRepair);
      await this.checkpoint('afterPreparedJournalCommitBeforeFormalReplace');
      if (interruptionRequested()) {
        await this.removePendingRepair();
        throw interruptedError();
      }

      await fsp.rename(repairTemporary, revalidated.targetPath);
      await this.directorySync(path.dirname(revalidated.targetPath));
      await this.checkpoint('afterFormalReplaceBeforeInstalledJournalCommit');
    } catch (error) {
      await fsp.rm(repairTemporary, { force: true }).catch(() => {});
      throw error;
    }
    try {
      await this.checkpoint('beforePostReplaceVerification');
      await this.verifyFile(revalidated.targetPath, {
        expectedByteCount: revalidated.cursor.lastByteOffset,
        expectedHash: repairHash,
        phase: 'installedVerification',
        interruptionRequested,
      });
    } catch (error) {
      try {
        await this.restore(quarantine, revalidated.targetPath);
        await this.removePendingRepair();
      } catch {
        throw new Error(`Integrity repair rollback failed: ${revalidated.targetPath}`);
      }
      throw error;
    }

    pendingRepair = { ...pendingRepair, phase: 'installed' };
    await this.savePendingRepair(pendingRepair);
    await this.cleanupQuarantine(now, quarantine.filePath);
    await this.checkpoint('beforeMetadataCommit');
    const committed = await this.commitRepairMetadata({ pendingRepair, manifest, state });
    await this.removePendingRepair();
    return committed;
  }

  async installMissingTarget({
    file,
    repairTemporary,
    repairHash,
    now,
    manifest,
    state,
    interruptionRequested,
  }) {
    this.requireNotInterrupted(interruptionRequested);
    assertSafeDestinationPath(file.targetPath, this.paths.backupRoot);
    const targetParent = path.dirname(file.targetPath);
    assertSafeSourcePath(targetParent, this.paths.backupRoot);
    const parentStats = await fsp.lstat(targetParent);
    if (!parentStats.isDirectory() || parentStats.isSymbolicLink()) {
      throw new Error(`Integrity audit rejected unsafe target parent: ${targetParent}`);
    }
    try {
      await fsp.lstat(file.targetPath);
      throw new Error(`Integrity audit refused to replace newly-created target: ${file.targetPath}`);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }

    await this.checkpoint('beforeReplace');
    let installed = false;
    try {
      await publishSyncedTemporaryFileIfAbsent(repairTemporary, file.targetPath);
      installed = true;
      await this.directorySync(targetParent);
      await this.checkpoint('afterFormalReplaceBeforeInstalledJournalCommit');
      await this.checkpoint('beforePostReplaceVerification');
      await this.verifyFile(file.targetPath, {
        expectedByteCount: file.cursor.lastByteOffset,
        expectedHash: repairHash,
        phase: 'installedVerification',
        interruptionRequested,
      });
    } catch (error) {
      if (installed) {
        await fsp.rm(file.targetPath, { force: true }).catch(() => {});
        await this.directorySync(targetParent);
      }
      throw error;
    }

    await this.checkpoint('beforeMetadataCommit');
    return this.commitRepairValues({
      sessionId: file.cursor.sessionId,
      sourcePath: file.cursor.sourcePath,
      backupPath: file.cursor.backupPath,
      byteCount: file.cursor.lastByteOffset,
      contentHash: repairHash,
      repairedAt: now,
      repairedCount: Number(state.repairedCount || 0) + 1,
      manifest,
      state,
    });
  }

  async quarantineCurrentTarget({ targetPath, sessionId, now, interruptionRequested }) {
    await this.ensureTrustedDirectory(this.paths.repairQuarantineRoot, this.paths.backupRoot);
    const safeSessionId = safePathComponent(sessionId);
    const sessionRoot = path.join(this.paths.repairQuarantineRoot, safeSessionId);
    await this.ensureTrustedDirectory(sessionRoot, this.paths.repairQuarantineRoot);
    const filePath = path.join(
      sessionRoot,
      `repair-${safeSessionId}-${Math.floor(now.getTime() / 1000)}-${crypto.randomUUID().toLowerCase()}.jsonl`,
    );
    assertSafeSourcePath(targetPath, this.paths.backupRoot);
    const stats = await fsp.lstat(targetPath);
    if (!stats.isFile() || stats.isSymbolicLink()) throw new Error(`Unsafe target: ${targetPath}`);
    const sourceHandle = await fsp.open(targetPath, 'r');
    const digest = crypto.createHash('sha256');
    try {
      await durableReplaceWithWriter(filePath, async (handle) => {
        let offset = 0;
        while (offset < stats.size) {
          this.requireNotInterrupted(interruptionRequested);
          const count = Math.min(this.chunkSize, stats.size - offset);
          const chunk = await readExactly(sourceHandle, offset, count);
          if (chunk.length !== count) throw new Error(`Integrity verification failed: ${targetPath}`);
          await writeAll(handle, chunk);
          digest.update(chunk);
          await this.didStreamChunk('quarantineCopy', targetPath, offset, chunk.length);
          this.requireNotInterrupted(interruptionRequested);
          offset += chunk.length;
        }
      }, { sync: this.sync });
    } finally {
      await sourceHandle.close().catch(() => {});
    }
    await this.directorySync(path.dirname(filePath));
    const quarantine = { filePath, byteCount: stats.size, hash: digest.digest('hex') };
    let verificationError;
    try {
      await this.verifyFile(filePath, {
        expectedByteCount: quarantine.byteCount,
        expectedHash: quarantine.hash,
        phase: 'quarantineVerification',
        interruptionRequested,
      });
    } catch (error) {
      verificationError = error;
    }
    await this.cleanupQuarantine(now, filePath);
    if (verificationError) throw verificationError;
    return quarantine;
  }

  async restore(quarantine, targetPath) {
    assertSafeSourcePath(quarantine.filePath, this.paths.repairQuarantineRoot);
    const sourceHandle = await fsp.open(quarantine.filePath, 'r');
    try {
      await durableReplaceWithWriter(targetPath, async (handle) => {
        let offset = 0;
        while (offset < quarantine.byteCount) {
          const count = Math.min(this.chunkSize, quarantine.byteCount - offset);
          const chunk = await readExactly(sourceHandle, offset, count);
          if (chunk.length !== count) throw new Error(`Integrity restore failed: ${targetPath}`);
          await writeAll(handle, chunk);
          offset += chunk.length;
        }
      }, { sync: this.sync });
    } finally {
      await sourceHandle.close().catch(() => {});
    }
    await this.directorySync(path.dirname(targetPath));
    await this.verifyFile(targetPath, {
      expectedByteCount: quarantine.byteCount,
      expectedHash: quarantine.hash,
    });
  }

  async verifyFile(filePath, {
    expectedByteCount,
    expectedHash,
    phase = null,
    interruptionRequested = () => false,
    validateJSON = false,
  }) {
    const validationRoot = isDescendant(filePath, this.paths.backupRoot)
      ? this.paths.backupRoot
      : path.dirname(filePath);
    assertSafeSourcePath(filePath, validationRoot);
    const stats = await fsp.lstat(filePath);
    if (!stats.isFile() || stats.isSymbolicLink() || stats.size !== expectedByteCount) {
      throw new Error(`Integrity verification failed: ${filePath}`);
    }
    const hash = await this.hashFile(filePath, expectedByteCount, {
      phase,
      interruptionRequested,
      validateJSON,
    });
    if (hash !== expectedHash) throw new Error(`Integrity verification failed: ${filePath}`);
  }

  async hashFile(filePath, byteCount, { phase, interruptionRequested, validateJSON }) {
    const handle = await fsp.open(filePath, 'r');
    const digest = crypto.createHash('sha256');
    let pending = Buffer.alloc(0);
    try {
      let offset = 0;
      while (offset < byteCount) {
        this.requireNotInterrupted(interruptionRequested);
        const count = Math.min(this.chunkSize, byteCount - offset);
        const chunk = await readExactly(handle, offset, count);
        if (chunk.length !== count) throw new Error(`Integrity verification failed: ${filePath}`);
        digest.update(chunk);
        if (validateJSON) pending = validateJSONLChunk(chunk, pending, filePath);
        if (phase) await this.didStreamChunk(phase, filePath, offset, chunk.length);
        this.requireNotInterrupted(interruptionRequested);
        offset += chunk.length;
      }
      if (validateJSON && pending.length !== 0) {
        throw new Error(`Integrity repair rejected structurally invalid committed JSONL: ${filePath}`);
      }
      return digest.digest('hex');
    } finally {
      await handle.close().catch(() => {});
    }
  }

  async resolvePendingRepair({ pendingRepair, manifest, state }) {
    const record = requiredRecord(manifest, pendingRepair.sessionId);
    if (record.sourcePath !== pendingRepair.sourcePath || record.backupPath !== pendingRepair.backupPath) {
      throw new Error(`Integrity audit rejected unsafe cursor metadata: ${pendingRepair.sourcePath}`);
    }
    const targetPath = this.trustedPendingPath(
      pendingRepair.backupPath,
      [this.paths.sessionsRoot, this.paths.archivedSessionsRoot],
    );
    const targetState = await this.pendingTargetState(pendingRepair, targetPath);
    if (targetState === 'installed') {
      const installed = { ...pendingRepair, phase: 'installed' };
      if (pendingRepair.phase !== 'installed') await this.savePendingRepair(installed);
      ({ manifest, state } = await this.commitRepairMetadata({
        pendingRepair: installed,
        manifest,
        state,
      }));
    } else if (targetState === 'unknown') {
      const metadataAdvanced = await this.repairMetadataWasAdvanced(pendingRepair, manifest);
      if (metadataAdvanced) {
        ({ manifest, state } = await this.commitRepairMetadata({ pendingRepair, manifest, state }));
      } else {
        const quarantinePath = this.trustedPendingPath(
          pendingRepair.quarantineBackupPath,
          [this.paths.repairQuarantineRoot],
        );
        await this.verifyFile(quarantinePath, {
          expectedByteCount: pendingRepair.originalByteCount,
          expectedHash: pendingRepair.originalContentHash,
        });
        await this.restore({
          filePath: quarantinePath,
          byteCount: pendingRepair.originalByteCount,
          hash: pendingRepair.originalContentHash,
        }, targetPath);
      }
    }
    await this.removePendingRepair();
    return { manifest, state };
  }

  async pendingTargetState(pendingRepair, targetPath) {
    if (await this.fileMatches(targetPath, pendingRepair.byteCount, pendingRepair.contentHash)) {
      return 'installed';
    }
    if (await this.fileMatches(targetPath, pendingRepair.originalByteCount, pendingRepair.originalContentHash)) {
      return 'original';
    }
    return 'unknown';
  }

  async fileMatches(filePath, byteCount, hash) {
    try {
      await fsp.lstat(filePath);
    } catch (error) {
      if (error.code === 'ENOENT') return false;
      throw error;
    }
    try {
      await this.verifyFile(filePath, { expectedByteCount: byteCount, expectedHash: hash });
      return true;
    } catch (error) {
      if (/Integrity verification failed/.test(error.message) || error.code === 'ENOENT') return false;
      throw error;
    }
  }

  async repairMetadataWasAdvanced(pendingRepair, manifest) {
    const record = manifest.sessions?.[pendingRepair.sessionId];
    if (record?.lastBackedUpAt && new Date(record.lastBackedUpAt) > new Date(pendingRepair.repairedAt)) {
      return true;
    }
    const store = this.cursorStoreFactory(this.paths);
    await store.open();
    try {
      const cursor = await store.get(pendingRepair.sourcePath);
      return Boolean(cursor && cursor.updatedAt > new Date(pendingRepair.repairedAt).getTime() / 1000);
    } finally {
      await store.close();
    }
  }

  trustedPendingPath(relativePath, allowedRoots) {
    const normalized = validateRelativeBackupPath(relativePath);
    const candidate = path.resolve(this.paths.backupRoot, ...normalized.split('/'));
    const canonical = validateRelativeBackupPath(this.paths.relativeBackupPath(candidate));
    if (canonical !== normalized || !allowedRoots.some((root) => isDescendant(candidate, root))) {
      throw new Error(`Integrity audit rejected unsafe cursor metadata: ${relativePath}`);
    }
    assertSafeDestinationPath(candidate, allowedRoots.find((root) => isDescendant(candidate, root)));
    return candidate;
  }

  async commitRepairMetadata({ pendingRepair, manifest, state }) {
    return this.commitRepairValues({
      sessionId: pendingRepair.sessionId,
      sourcePath: pendingRepair.sourcePath,
      backupPath: pendingRepair.backupPath,
      byteCount: pendingRepair.byteCount,
      contentHash: pendingRepair.contentHash,
      repairedAt: new Date(pendingRepair.repairedAt),
      repairedCount: pendingRepair.repairedCount,
      manifest,
      state,
    });
  }

  async commitRepairValues({
    sessionId,
    sourcePath,
    backupPath,
    byteCount,
    contentHash,
    repairedAt,
    repairedCount,
    manifest,
    state,
  }) {
    const repairedAtDate = dateValue(repairedAt);
    let record = requiredRecord(manifest, sessionId);
    if (record.sourcePath !== sourcePath || record.backupPath !== backupPath) {
      throw new Error(`Integrity audit rejected unsafe cursor metadata: ${sourcePath}`);
    }
    const notAdvanced = record.bytesBackedUp === byteCount
      && (!record.lastBackedUpAt || new Date(record.lastBackedUpAt) <= repairedAtDate);
    if (notAdvanced) {
      record = {
        ...record,
        contentHash,
        lastBackedUpAt: repairedAtDate.toISOString(),
      };
    }
    manifest.sessions[sessionId] = record;
    manifest.updatedAt = maxIso(manifest.updatedAt, repairedAtDate.toISOString());
    await saveManifest(this.paths, manifest);
    await this.checkpoint('afterManifestCommit');

    const store = this.cursorStoreFactory(this.paths);
    await store.open();
    try {
      const cursor = await store.get(sourcePath);
      if (!cursor || cursor.sessionId !== sessionId || cursor.backupPath !== backupPath) {
        throw new Error(`Integrity audit rejected unsafe cursor metadata: ${sourcePath}`);
      }
      const repairedAtSeconds = repairedAtDate.getTime() / 1000;
      if (cursor.lastByteOffset === byteCount && cursor.updatedAt <= repairedAtSeconds) {
        await store.upsert({ ...cursor, updatedAt: repairedAtSeconds, lastError: null });
      }
    } finally {
      await store.close();
    }
    await this.checkpoint('afterCursorCommit');

    state = {
      ...state,
      repairedCount: Math.max(Number(state.repairedCount || 0), repairedCount),
      lastResult: 'repaired',
    };
    await this.saveAuditState(state);
    await this.checkpoint('afterAuditStateCommit');
    await this.updatePersistedStatus({
      lastRepairAt: repairedAtDate,
      repairCount: state.repairedCount,
    });
    await this.checkpoint('afterRuntimeStatusCommit');
    return { manifest, state };
  }

  async ensureTrustedDirectory(directory, root) {
    assertSafeDestinationPath(directory, root);
    try {
      await fsp.mkdir(directory);
      await this.directorySync(path.dirname(directory));
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    assertSafeSourcePath(directory, root);
    const stats = await fsp.lstat(directory);
    if (!stats.isDirectory() || stats.isSymbolicLink()) throw new Error(`Unsafe directory: ${directory}`);
  }

  async cleanupQuarantine(now, protectedPath = null) {
    let rootStats;
    try {
      rootStats = await fsp.lstat(this.paths.repairQuarantineRoot);
    } catch (error) {
      if (error.code === 'ENOENT') return;
      throw error;
    }
    if (!rootStats.isDirectory() || rootStats.isSymbolicLink()) {
      throw new Error(`Unsafe repair quarantine root: ${this.paths.repairQuarantineRoot}`);
    }
    assertSafeSourcePath(this.paths.repairQuarantineRoot, this.paths.backupRoot);
    const entries = await fsp.readdir(this.paths.repairQuarantineRoot, { withFileTypes: true });
    for (const entry of entries) {
      const sessionDirectory = path.join(this.paths.repairQuarantineRoot, entry.name);
      const directoryStats = await fsp.lstat(sessionDirectory);
      if (!directoryStats.isDirectory() || directoryStats.isSymbolicLink()) continue;
      const prefix = `repair-${entry.name}-`;
      const owned = [];
      for (const name of await fsp.readdir(sessionDirectory)) {
        const filePath = path.join(sessionDirectory, name);
        const stats = await fsp.lstat(filePath);
        if (!stats.isFile() || stats.isSymbolicLink() || !isOwnedQuarantineFilename(name, prefix)) continue;
        owned.push({ filePath, modifiedAt: stats.mtimeMs });
      }
      owned.sort((left, right) => {
        if (left.filePath === protectedPath) return -1;
        if (right.filePath === protectedPath) return 1;
        return right.modifiedAt - left.modifiedAt || right.filePath.localeCompare(left.filePath);
      });
      for (let index = 0; index < owned.length; index += 1) {
        const copy = owned[index];
        if (copy.filePath === protectedPath) continue;
        if (index >= MAXIMUM_QUARANTINE_COPIES || now.getTime() - copy.modifiedAt > RETENTION_INTERVAL_MS) {
          await fsp.rm(copy.filePath);
        }
      }
    }
  }

  async cleanupOrphanTemporaryFiles() {
    const protectedPaths = new Set();
    const pendingRepair = await this.loadPendingRepair();
    if (pendingRepair) {
      for (const [relativePath, allowedRoots] of [
        [pendingRepair.backupPath, [this.paths.sessionsRoot, this.paths.archivedSessionsRoot]],
        [pendingRepair.quarantineBackupPath, [this.paths.repairQuarantineRoot]],
        [pendingRepair.repairTemporaryBackupPath, [this.paths.sessionsRoot, this.paths.archivedSessionsRoot]],
      ]) {
        if (!relativePath) continue;
        protectedPaths.add(pathKey(this.trustedPendingPath(relativePath, allowedRoots)));
      }
    }

    for (const root of [this.paths.sessionsRoot, this.paths.archivedSessionsRoot]) {
      let stats;
      try {
        stats = await fsp.lstat(root);
      } catch (error) {
        if (error.code === 'ENOENT') continue;
        throw error;
      }
      if (!stats.isDirectory() || stats.isSymbolicLink()) {
        throw new Error(`Unsafe formal session root: ${root}`);
      }
      assertSafeSourcePath(root, this.paths.backupRoot);
      await this.cleanupOrphanTemporaryFilesInDirectory(root, root, protectedPaths);
    }
  }

  async cleanupOrphanTemporaryFilesInDirectory(directory, root, protectedPaths) {
    let removedEntry = false;
    for (const entry of await fsp.readdir(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      const ownedTemporaryName = isOwnedOrphanTemporaryFilename(entry.name);
      if (entry.isSymbolicLink() || (entry.isFile() && !ownedTemporaryName)) continue;
      const stats = await fsp.lstat(entryPath).catch((error) => {
        if (error.code === 'ENOENT') return null;
        throw error;
      });
      if (!stats || stats.isSymbolicLink()) continue;
      if (stats.isDirectory()) {
        assertSafeSourcePath(entryPath, root);
        await this.cleanupOrphanTemporaryFilesInDirectory(entryPath, root, protectedPaths);
        continue;
      }
      if (!stats.isFile()
        || !ownedTemporaryName
        || protectedPaths.has(pathKey(entryPath))) {
        continue;
      }
      assertSafeSourcePath(entryPath, root);
      try {
        await fsp.rm(entryPath);
        removedEntry = true;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
    if (removedEntry) await this.directorySync(directory);
  }

  async loadAuditState() {
    try {
      const state = JSON.parse(await fsp.readFile(this.paths.auditStatePath, 'utf8'));
      const repairedCount = Number(state.repairedCount ?? 0);
      if (!Number.isSafeInteger(repairedCount) || repairedCount < 0) throw new Error('Invalid audit state.');
      if (state.lastCompletedAt && !isValidDate(state.lastCompletedAt)) throw new Error('Invalid audit state.');
      return {
        lastCompletedAt: state.lastCompletedAt || null,
        lastResult: state.lastResult ?? null,
        repairedCount,
      };
    } catch (error) {
      if (error.code === 'ENOENT') return { lastCompletedAt: null, lastResult: null, repairedCount: 0 };
      throw error;
    }
  }

  async saveAuditState(state) {
    await fsp.mkdir(path.dirname(this.paths.auditStatePath), { recursive: true });
    await replaceFileDurably(this.paths.auditStatePath, jsonPayload(state), { sync: this.sync });
  }

  get pendingRepairPath() {
    return path.join(path.dirname(this.paths.auditStatePath), 'integrity-repair-pending.json');
  }

  async loadPendingRepair() {
    let pending;
    try {
      pending = JSON.parse(await fsp.readFile(this.pendingRepairPath, 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error;
    }
    const valid = pending.version === INTEGRITY_REPAIR_JOURNAL_VERSION
      && ['prepared', 'installed'].includes(pending.phase)
      && typeof pending.sessionId === 'string'
      && typeof pending.sourcePath === 'string'
      && typeof pending.backupPath === 'string'
      && typeof pending.quarantineBackupPath === 'string'
      && (pending.repairTemporaryBackupPath == null
        || typeof pending.repairTemporaryBackupPath === 'string')
      && Number.isSafeInteger(pending.byteCount) && pending.byteCount >= 0
      && Number.isSafeInteger(pending.originalByteCount) && pending.originalByteCount >= 0
      && isSHA256(pending.contentHash) && isSHA256(pending.originalContentHash)
      && isValidDate(pending.repairedAt)
      && Number.isSafeInteger(pending.repairedCount) && pending.repairedCount > 0;
    if (!valid) throw new Error(`Integrity audit rejected unsafe repair journal: ${pending.sourcePath || ''}`);
    validateRelativeBackupPath(pending.backupPath);
    validateRelativeBackupPath(pending.quarantineBackupPath);
    if (pending.repairTemporaryBackupPath) {
      validateRelativeBackupPath(pending.repairTemporaryBackupPath);
    }
    return pending;
  }

  async savePendingRepair(pendingRepair) {
    await fsp.mkdir(path.dirname(this.pendingRepairPath), { recursive: true });
    await replaceFileDurably(this.pendingRepairPath, jsonPayload(pendingRepair), {
      sync: async (handle) => {
        if (pendingRepair.phase === 'prepared') {
          await this.checkpoint('beforePreparedRepairJournalFlush');
        }
        await this.sync(handle);
      },
    });
    await this.directorySync(path.dirname(this.pendingRepairPath));
  }

  async removePendingRepair() {
    try {
      await fsp.rm(this.pendingRepairPath);
      await this.directorySync(path.dirname(this.pendingRepairPath));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }

  async updatePersistedStatus({
    lastAuditAt = null,
    lastAuditResult = null,
    lastRepairAt = null,
    repairCount = 0,
  }) {
    let status;
    try {
      status = JSON.parse(await fsp.readFile(this.paths.localStatusPath, 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return;
      throw error;
    }
    if (lastAuditAt) status.lastAuditAt = lastAuditAt.toISOString();
    if (lastAuditResult) status.lastAuditResult = lastAuditResult;
    if (lastRepairAt) status.lastRepairAt = maxIso(status.lastRepairAt, lastRepairAt.toISOString());
    status.repairCount = Math.max(Number(status.repairCount || 0), Number(repairCount || 0));
    const payload = jsonPayload(status);
    await replaceFileDurably(this.paths.localStatusPath, payload, { sync: this.sync });
    try {
      const stats = await fsp.lstat(this.paths.remoteStatusPath);
      if (stats.isFile() && !stats.isSymbolicLink()) {
        await replaceFileDurably(this.paths.remoteStatusPath, payload, { sync: this.sync });
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }

  requireNotInterrupted(interruptionRequested) {
    if (interruptionRequested()) throw interruptedError();
  }

  async didReadChunk(...args) {
    await this.instrumentation.didReadChunk?.(...args);
  }

  async didStreamChunk(...args) {
    await this.instrumentation.didStreamChunk?.(...args);
  }

  async checkpoint(value) {
    await this.instrumentation.checkpoint?.(value);
  }
}

function outcome(value, checked = 0, repaired = 0) {
  return { outcome: value, checked, repaired };
}

function normalizedCursors(cursors) {
  const values = cursors instanceof Map
    ? Array.from(cursors.values())
    : Array.isArray(cursors)
      ? cursors
      : Object.values(cursors || {});
  return values.sort((left, right) => (
    left.sessionId.localeCompare(right.sessionId) || left.sourcePath.localeCompare(right.sourcePath)
  ));
}

function completedWithinInterval(state, now) {
  if (!state.lastCompletedAt) return false;
  return now.getTime() - new Date(state.lastCompletedAt).getTime() < AUDIT_INTERVAL_MS;
}

function normalizeChunkSize(value) {
  const parsed = Number(value);
  return Math.min(MAXIMUM_CHUNK_SIZE, Math.max(1, Number.isFinite(parsed) ? Math.floor(parsed) : DEFAULT_CHUNK_SIZE));
}

function dateValue(value) {
  const date = value instanceof Date ? new Date(value) : new Date(value ?? Date.now());
  if (Number.isNaN(date.getTime())) throw new Error(`Invalid audit date: ${String(value)}`);
  return date;
}

function isValidDate(value) {
  return !Number.isNaN(new Date(value).getTime());
}

function sourceRootFor(paths, sourcePath) {
  for (const name of ['sessions', 'archived_sessions']) {
    const root = path.resolve(paths.codexRoot, name);
    if (isDescendant(sourcePath, root)) return root;
  }
  throw new Error(`Integrity audit rejected unsafe source path: ${sourcePath}`);
}

function isDescendant(candidate, root) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return Boolean(relative)
    && relative !== '..'
    && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative);
}

function validateRelativeBackupPath(value) {
  if (typeof value !== 'string' || !value || value.includes('\0')) {
    throw new Error(`Integrity audit rejected unsafe path: ${String(value)}`);
  }
  if (/^(?:[\\/]{2}|[A-Za-z]:)/.test(value)) {
    throw new Error(`Integrity audit rejected unsafe path: ${value}`);
  }
  const components = value.replaceAll('\\', '/').split('/');
  if (components.some((component) => !component || component === '.' || component === '..' || component.includes(':'))) {
    throw new Error(`Integrity audit rejected unsafe path: ${value}`);
  }
  return components.join('/');
}

function validateWindowsSourceNamespace(value, { pathImpl = path.win32 } = {}) {
  if (typeof value !== 'string' || !value || value.includes('\0')) {
    throw new Error(`Integrity audit rejected unsafe Windows source namespace: ${String(value)}`);
  }
  const windowsSeparators = value.replaceAll('/', '\\');
  const namespacePath = value.startsWith('\\')
    || value.startsWith('//')
    || windowsSeparators.startsWith('\\\\')
    || windowsSeparators.startsWith('\\??\\');
  const firstColon = value.indexOf(':');
  const validDriveColon = firstColon === 1
    && /^[A-Za-z]:[\\/]/.test(value)
    && pathImpl.isAbsolute(value)
    && value.indexOf(':', firstColon + 1) === -1;
  if (namespacePath || (firstColon !== -1 && !validDriveColon)) {
    throw new Error(`Integrity audit rejected unsafe Windows source namespace: ${value}`);
  }
  return value;
}

function validateJSONLChunk(chunk, pending, filePath) {
  let combined = pending.length ? Buffer.concat([pending, chunk]) : chunk;
  let start = 0;
  for (let index = 0; index < combined.length; index += 1) {
    if (combined[index] !== 0x0A) continue;
    const line = combined.subarray(start, index);
    if (line.length > MAXIMUM_LINE_BYTES) throw invalidJSONLError(filePath);
    let value;
    try {
      value = JSON.parse(FATAL_UTF8_DECODER.decode(line));
    } catch {
      throw invalidJSONLError(filePath);
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalidJSONLError(filePath);
    start = index + 1;
  }
  combined = combined.subarray(start);
  if (combined.length > MAXIMUM_LINE_BYTES) throw invalidJSONLError(filePath);
  return Buffer.from(combined);
}

function invalidJSONLError(filePath) {
  return new Error(`Integrity repair rejected structurally invalid committed JSONL: ${filePath}`);
}

async function readExactly(handle, position, byteCount) {
  const buffer = Buffer.allocUnsafe(byteCount);
  let offset = 0;
  while (offset < byteCount) {
    const { bytesRead } = await handle.read(buffer, offset, byteCount - offset, position + offset);
    if (bytesRead === 0) break;
    offset += bytesRead;
  }
  return buffer.subarray(0, offset);
}

async function writeAll(handle, buffer) {
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesWritten } = await handle.write(buffer, offset, buffer.length - offset);
    if (bytesWritten === 0) throw new Error('Unable to make progress writing integrity data.');
    offset += bytesWritten;
  }
}

function interruptedError() {
  const error = new Error('Integrity audit interrupted.');
  error.code = INTERRUPTED_CODE;
  return error;
}

function isInterrupted(error) {
  return error?.code === INTERRUPTED_CODE;
}

function requiredRecord(manifest, sessionId) {
  const record = manifest.sessions?.[sessionId];
  if (!record) throw new Error(`Integrity audit has no manifest record for session: ${sessionId}`);
  return record;
}

function safePathComponent(value) {
  const safe = String(value).replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
  return safe || 'session';
}

function isOwnedQuarantineFilename(name, prefix) {
  if (!name.endsWith('.jsonl')) return false;
  const stem = name.slice(0, -'.jsonl'.length);
  if (!stem.startsWith(prefix)) return false;
  const suffix = stem.slice(prefix.length);
  const match = suffix.match(/^(\d+)-([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i);
  return Boolean(match);
}

function isOwnedOrphanTemporaryFilename(name) {
  const uuid = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}';
  const durableSuffix = '\\.tmp-\\d+-\\d+-[0-9a-f]+';
  return new RegExp(`^\\.[^/\\\\]+\\.jsonl(?:\\.repair-${uuid}|${durableSuffix})$`, 'i').test(name)
    || new RegExp(`^\\.\\.[^/\\\\]+\\.jsonl\\.repair-${uuid}${durableSuffix}$`, 'i').test(name);
}

function pathKey(value) {
  const resolved = path.resolve(value);
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
}

function isSHA256(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

function maxIso(left, right) {
  if (!left) return right || null;
  if (!right) return left;
  return new Date(left) >= new Date(right) ? left : right;
}

async function syncParentDirectory(directory) {
  let handle;
  try {
    handle = await fsp.open(directory, 'r');
    await handle.sync();
  } finally {
    await handle?.close().catch(() => {});
  }
}

function isUnsupportedDirectorySyncError(error) {
  return [
    'EACCES',
    'EBADF',
    'EISDIR',
    'EINVAL',
    'ENOSYS',
    'ENOTSUP',
    'EOPNOTSUPP',
    'EPERM',
    'ERR_METHOD_NOT_IMPLEMENTED',
  ].includes(error?.code);
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

module.exports = {
  BackupIntegrityAuditor,
  dailyOffsetSeconds,
  overdueWakeDelaySeconds,
  validateWindowsSourceNamespace,
};

'use strict';

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');
const { TextDecoder } = require('node:util');

const { DEFAULT_VERIFICATION_CHUNK_SIZE } = require('./verification-store');
const { createBoundedLineAccumulator } = require('./jsonl-line-accumulator');
const {
  ISOLATED_VERIFICATION_THRESHOLD_BYTES,
  runIsolatedBackupVerification,
} = require('./isolated-backup-verifier');
const { MAX_JSONL_LINE_BYTES } = require('../jsonl-policy');

const DEFAULT_MAX_LINE_BYTES = MAX_JSONL_LINE_BYTES;

class BackupFileVerificationError extends Error {}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

async function readExactly(handle, buffer, count, position) {
  let offset = 0;
  while (offset < count) {
    const { bytesRead } = await handle.read(buffer, offset, count - offset, position + offset);
    if (bytesRead === 0) break;
    offset += bytesRead;
  }
  return buffer.subarray(0, offset);
}

function createJSONLValidator(maxLineBytes) {
  const pending = createBoundedLineAccumulator(maxLineBytes);
  let lineCount = 0;
  const decoder = new TextDecoder('utf-8', { fatal: true });
  function validateLine(line) {
    if (line.length > maxLineBytes) throw new BackupFileVerificationError(`JSONL line exceeds ${maxLineBytes} bytes.`);
    if (line.length > 0) {
      try {
        JSON.parse(decoder.decode(line));
      } catch {
        throw new BackupFileVerificationError(`Invalid JSONL at line ${lineCount + 1}.`);
      }
    }
    lineCount += 1;
  }
  return {
    consume(data) {
      let start = 0;
      for (let index = data.indexOf(0x0A); index >= 0; index = data.indexOf(0x0A, start)) {
        const segment = data.subarray(start, index);
        const lineLength = pending.length + segment.length;
        if (lineLength > maxLineBytes) throw new BackupFileVerificationError(`JSONL line exceeds ${maxLineBytes} bytes.`);
        let line = segment;
        if (pending.length > 0) {
          pending.append(segment);
          line = pending.view();
        }
        validateLine(line);
        pending.reset();
        start = index + 1;
      }
      if (start < data.length) {
        const segment = data.subarray(start);
        if (!pending.append(segment)) throw new BackupFileVerificationError(`JSONL line exceeds ${maxLineBytes} bytes.`);
      }
    },
    finish(byteCount) {
      if (byteCount > 0 && pending.length > 0) throw new BackupFileVerificationError('Backup has an incomplete JSONL tail.');
      return lineCount;
    },
  };
}

async function verifyFullBackupFileInProcess({
  filePath,
  chunkSize = DEFAULT_VERIFICATION_CHUNK_SIZE,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
  expectedByteCount = null,
  expectedLineCount = null,
  expectedContentHash = null,
  expectedChunkHashes = null,
}) {
  const stats = await fsp.lstat(filePath);
  if (!stats.isFile() || stats.isSymbolicLink()) throw new BackupFileVerificationError(`Untrusted backup file: ${filePath}`);
  if (expectedByteCount !== null && stats.size !== expectedByteCount) {
    throw new BackupFileVerificationError(`Backup length mismatch: expected ${expectedByteCount}, got ${stats.size}.`);
  }
  const digest = crypto.createHash('sha256');
  const chunkHashes = [];
  const jsonl = createJSONLValidator(maxLineBytes);
  const scratch = stats.size > 0
    ? Buffer.allocUnsafe(Math.min(chunkSize, stats.size))
    : null;
  const handle = await fsp.open(filePath, 'r');
  try {
    let position = 0;
    while (position < stats.size) {
      const count = Math.min(chunkSize, stats.size - position);
      const chunk = await readExactly(handle, scratch, count, position);
      if (chunk.length !== count) throw new BackupFileVerificationError('Backup changed while verifying.');
      digest.update(chunk);
      chunkHashes.push(sha256(chunk));
      jsonl.consume(chunk);
      position += chunk.length;
    }
  } finally {
    await handle.close();
  }
  const lineCount = jsonl.finish(stats.size);
  const contentHash = digest.digest('hex');
  if (expectedLineCount !== null && lineCount !== expectedLineCount) {
    throw new BackupFileVerificationError(`Backup line count mismatch: expected ${expectedLineCount}, got ${lineCount}.`);
  }
  if (expectedContentHash !== null && contentHash.toLowerCase() !== String(expectedContentHash).toLowerCase()) {
    throw new BackupFileVerificationError('Backup SHA-256 mismatch.');
  }
  if (expectedChunkHashes !== null) {
    if (expectedChunkHashes.length !== chunkHashes.length) throw new BackupFileVerificationError('Backup chunk count mismatch.');
    for (let index = 0; index < chunkHashes.length; index += 1) {
      if (String(expectedChunkHashes[index]).toLowerCase() !== chunkHashes[index]) {
        throw new BackupFileVerificationError(`Backup chunk SHA-256 mismatch at chunk ${index + 1}.`);
      }
    }
  }
  return { byteCount: stats.size, lineCount, contentHash, chunkHashes };
}

async function verifyAppendSourceAnchors({
  sourcePath,
  previous,
  chunkSize = DEFAULT_VERIFICATION_CHUNK_SIZE,
  onRead = null,
}) {
  if (!previous
    || !Number.isSafeInteger(chunkSize)
    || chunkSize <= 0
    || !Number.isSafeInteger(previous.byteCount)
    || previous.byteCount < 0
    || !Array.isArray(previous.chunkHashes)
    || previous.chunkHashes.length !== Math.ceil(previous.byteCount / chunkSize)
    || !previous.chunkHashes.every((hash) => /^[a-f\d]{64}$/i.test(String(hash)))) {
    throw new BackupFileVerificationError('Invalid previous backup verification state.');
  }
  if (previous.byteCount === 0) return true;

  const stats = await fsp.lstat(sourcePath);
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw new BackupFileVerificationError(`Untrusted source file: ${sourcePath}`);
  }
  if (stats.size < previous.byteCount) return false;

  const lastIndex = previous.chunkHashes.length - 1;
  const anchorIndexes = [...new Set([0, Math.floor(lastIndex / 2), lastIndex])];
  const scratch = Buffer.allocUnsafe(Math.min(chunkSize, previous.byteCount));
  const source = await fsp.open(sourcePath, 'r');
  try {
    for (const chunkIndex of anchorIndexes) {
      const position = chunkIndex * chunkSize;
      const count = Math.min(chunkSize, previous.byteCount - position);
      const chunk = await readExactly(source, scratch, count, position);
      onRead?.({ chunkIndex, byteCount: chunk.length, position });
      if (chunk.length !== count
        || sha256(chunk) !== String(previous.chunkHashes[chunkIndex]).toLowerCase()) {
        return false;
      }
    }
    return true;
  } finally {
    await source.close();
  }
}

async function verifyChangedBackupChunksInProcess({
  sourcePath,
  targetPath,
  previous,
  backupPath,
  committedByteCount,
  lineCount,
  verifiedAt,
  chunkSize = DEFAULT_VERIFICATION_CHUNK_SIZE,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
}) {
  if (!previous
    || previous.byteCount < 0
    || committedByteCount < previous.byteCount
    || lineCount < previous.lineCount
    || previous.chunkHashes.length !== Math.ceil(previous.byteCount / chunkSize)) {
    throw new BackupFileVerificationError('Invalid previous backup verification state.');
  }
  const [sourceStats, targetStats] = await Promise.all([fsp.lstat(sourcePath), fsp.lstat(targetPath)]);
  if (!sourceStats.isFile() || sourceStats.isSymbolicLink() || !targetStats.isFile() || targetStats.isSymbolicLink()) {
    throw new BackupFileVerificationError('Untrusted source or backup file.');
  }
  if (sourceStats.size < committedByteCount || targetStats.size !== committedByteCount) {
    throw new BackupFileVerificationError('Backup length mismatch while verifying changed chunks.');
  }
  const firstChangedChunk = Math.floor(previous.byteCount / chunkSize);
  const startOffset = firstChangedChunk * chunkSize;
  const chunkHashes = previous.chunkHashes.slice(0, firstChangedChunk);
  const jsonl = createJSONLValidator(maxLineBytes);
  const scratchSize = Math.min(chunkSize, committedByteCount - startOffset);
  const sourceScratch = scratchSize > 0 ? Buffer.allocUnsafe(scratchSize) : null;
  const targetScratch = scratchSize > 0 ? Buffer.allocUnsafe(scratchSize) : null;
  const source = await fsp.open(sourcePath, 'r');
  const target = await fsp.open(targetPath, 'r');
  try {
    let position = startOffset;
    while (position < committedByteCount) {
      const count = Math.min(chunkSize, committedByteCount - position);
      const [sourceChunk, targetChunk] = await Promise.all([
        readExactly(source, sourceScratch, count, position),
        readExactly(target, targetScratch, count, position),
      ]);
      if (sourceChunk.length !== count || targetChunk.length !== count || !sourceChunk.equals(targetChunk)) {
        throw new BackupFileVerificationError(`Backup chunk mismatch at chunk ${chunkHashes.length + 1}.`);
      }
      chunkHashes.push(sha256(targetChunk));
      const appendedStart = Math.max(previous.byteCount, position);
      if (appendedStart < position + count) jsonl.consume(targetChunk.subarray(appendedStart - position));
      position += count;
    }
  } finally {
    await Promise.allSettled([source.close(), target.close()]);
  }
  const appendedLineCount = jsonl.finish(committedByteCount - previous.byteCount);
  if (previous.lineCount + appendedLineCount !== lineCount) {
    throw new BackupFileVerificationError('Backup line count mismatch while verifying changed chunks.');
  }
  return {
    backupPath,
    byteCount: committedByteCount,
    lineCount,
    chunkHashes,
    verifiedAt: verifiedAt instanceof Date ? verifiedAt.toISOString() : String(verifiedAt),
  };
}

async function verifyFullBackupFile(options) {
  const {
    signal = null,
    isolationRunner = runIsolatedBackupVerification,
    ...payload
  } = options;
  const stats = await fsp.lstat(payload.filePath);
  if (stats.size >= ISOLATED_VERIFICATION_THRESHOLD_BYTES) {
    try {
      return await isolationRunner({ operation: 'verifyFull', payload, signal });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new BackupFileVerificationError(error?.message || String(error));
    }
  }
  return verifyFullBackupFileInProcess(payload);
}

async function verifyChangedBackupChunks(options) {
  const {
    signal = null,
    isolationRunner = runIsolatedBackupVerification,
    ...payload
  } = options;
  const chunkSize = payload.chunkSize ?? DEFAULT_VERIFICATION_CHUNK_SIZE;
  const previousBytes = Number(payload.previous?.byteCount);
  const committedBytes = Number(payload.committedByteCount);
  const startOffset = Number.isSafeInteger(previousBytes)
      && Number.isSafeInteger(committedBytes)
      && Number.isSafeInteger(chunkSize)
      && chunkSize > 0
    ? Math.floor(previousBytes / chunkSize) * chunkSize
    : committedBytes;
  const changedBytes = Number.isSafeInteger(committedBytes)
    ? Math.max(0, committedBytes - startOffset)
    : 0;
  if (changedBytes >= ISOLATED_VERIFICATION_THRESHOLD_BYTES) {
    try {
      return await isolationRunner({ operation: 'verifyChangedChunks', payload, signal });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new BackupFileVerificationError(error?.message || String(error));
    }
  }
  return verifyChangedBackupChunksInProcess(payload);
}

module.exports = {
  BackupFileVerificationError,
  DEFAULT_MAX_LINE_BYTES,
  verifyAppendSourceAnchors,
  verifyChangedBackupChunks,
  verifyChangedBackupChunksInProcess,
  verifyFullBackupFile,
  verifyFullBackupFileInProcess,
};

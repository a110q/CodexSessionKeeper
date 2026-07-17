'use strict';

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');
const { TextDecoder } = require('node:util');

const { DEFAULT_VERIFICATION_CHUNK_SIZE } = require('./verification-store');

const DEFAULT_MAX_LINE_BYTES = 32 * 1024 * 1024;

class BackupFileVerificationError extends Error {}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

async function readExactly(handle, count, position) {
  const buffer = Buffer.allocUnsafe(count);
  let offset = 0;
  while (offset < count) {
    const { bytesRead } = await handle.read(buffer, offset, count - offset, position + offset);
    if (bytesRead === 0) break;
    offset += bytesRead;
  }
  return buffer.subarray(0, offset);
}

function createJSONLValidator(maxLineBytes) {
  let pending = [];
  let pendingLength = 0;
  let lineCount = 0;
  const decoder = new TextDecoder('utf-8', { fatal: true });
  function validateLine() {
    if (pendingLength > maxLineBytes) throw new BackupFileVerificationError(`JSONL line exceeds ${maxLineBytes} bytes.`);
    if (pendingLength > 0) {
      try {
        JSON.parse(decoder.decode(Buffer.concat(pending, pendingLength)));
      } catch {
        throw new BackupFileVerificationError(`Invalid JSONL at line ${lineCount + 1}.`);
      }
    }
    pending = [];
    pendingLength = 0;
    lineCount += 1;
  }
  return {
    consume(data) {
      let start = 0;
      for (let index = 0; index < data.length; index += 1) {
        if (data[index] !== 0x0A) continue;
        if (start < index) {
          const segment = data.subarray(start, index);
          pending.push(segment);
          pendingLength += segment.length;
        }
        validateLine();
        start = index + 1;
      }
      if (start < data.length) {
        const segment = data.subarray(start);
        pending.push(segment);
        pendingLength += segment.length;
        if (pendingLength > maxLineBytes) throw new BackupFileVerificationError(`JSONL line exceeds ${maxLineBytes} bytes.`);
      }
    },
    finish(byteCount) {
      if (byteCount > 0 && pendingLength > 0) throw new BackupFileVerificationError('Backup has an incomplete JSONL tail.');
      return lineCount;
    },
  };
}

async function verifyFullBackupFile({
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
  const handle = await fsp.open(filePath, 'r');
  const digest = crypto.createHash('sha256');
  const chunkHashes = [];
  const jsonl = createJSONLValidator(maxLineBytes);
  try {
    let position = 0;
    while (position < stats.size) {
      const count = Math.min(chunkSize, stats.size - position);
      const chunk = await readExactly(handle, count, position);
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
  const source = await fsp.open(sourcePath, 'r');
  try {
    for (const chunkIndex of anchorIndexes) {
      const position = chunkIndex * chunkSize;
      const count = Math.min(chunkSize, previous.byteCount - position);
      const chunk = await readExactly(source, count, position);
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

async function verifyChangedBackupChunks({
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
  const source = await fsp.open(sourcePath, 'r');
  const target = await fsp.open(targetPath, 'r');
  try {
    let position = startOffset;
    while (position < committedByteCount) {
      const count = Math.min(chunkSize, committedByteCount - position);
      const [sourceChunk, targetChunk] = await Promise.all([
        readExactly(source, count, position),
        readExactly(target, count, position),
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

module.exports = {
  BackupFileVerificationError,
  DEFAULT_MAX_LINE_BYTES,
  verifyAppendSourceAnchors,
  verifyChangedBackupChunks,
  verifyFullBackupFile,
};

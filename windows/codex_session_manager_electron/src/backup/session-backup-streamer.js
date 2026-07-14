'use strict';

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');

const { durableReplaceWithWriter } = require('./durable-write');
const { titleFromJsonLine } = require('./session-identity');

const NEWLINE_BYTE = 0x0A;
const DEFAULT_CHUNK_SIZE = 1024 * 1024;
const MAXIMUM_CHUNK_SIZE = 1024 * 1024;
const DEFAULT_MAX_LINE_BYTES = 32 * 1024 * 1024;
const MAX_PENDING_PARTIAL_BYTES = 64 * 1024;
const NEWLINE = Buffer.from([NEWLINE_BYTE]);

function normalizedChunkSize(chunkSize) {
  const parsed = Number(chunkSize ?? DEFAULT_CHUNK_SIZE);
  return Math.min(MAXIMUM_CHUNK_SIZE, Math.max(1, Number.isFinite(parsed) ? Math.floor(parsed) : DEFAULT_CHUNK_SIZE));
}

function normalizedLineLimit(maxLineBytes) {
  const parsed = Number(maxLineBytes ?? DEFAULT_MAX_LINE_BYTES);
  return Math.max(0, Number.isFinite(parsed) ? Math.floor(parsed) : DEFAULT_MAX_LINE_BYTES);
}

async function writeAll(handle, buffer, position = null) {
  let written = 0;
  while (written < buffer.length) {
    const writePosition = position === null ? null : position + written;
    const { bytesWritten } = await handle.write(
      buffer,
      written,
      buffer.length - written,
      writePosition,
    );
    if (bytesWritten === 0) {
      throw new Error('Unable to make progress while writing streamed backup data.');
    }
    written += bytesWritten;
  }
}

async function scanCompleteRecords({
  sourceHandle,
  sourcePath,
  startOffset = 0,
  maximumByteCount = null,
  chunkSize,
  maxLineBytes,
  interruptionRequested = () => false,
  onChunk = null,
  onRecord,
}) {
  const boundedChunkSize = normalizedChunkSize(chunkSize);
  const lineLimit = normalizedLineLimit(maxLineBytes);
  let position = startOffset;
  let remaining = maximumByteCount;
  let committedByteCount = 0;
  let lineCount = 0;
  let pendingChunks = [];
  let pendingLength = 0;
  let blockedError = null;
  let firstTitle = null;

  readLoop: while (remaining === null || remaining > 0) {
    if (interruptionRequested()) throw interruptedError();
    const requested = remaining === null
      ? boundedChunkSize
      : Math.min(boundedChunkSize, remaining);
    if (requested <= 0) break;
    const buffer = Buffer.allocUnsafe(requested);
    const { bytesRead } = await sourceHandle.read(buffer, 0, requested, position);
    if (bytesRead === 0) break;
    const chunk = buffer.subarray(0, bytesRead);
    await onChunk?.(position, bytesRead);
    if (interruptionRequested()) throw interruptedError();
    position += bytesRead;
    if (remaining !== null) remaining -= bytesRead;

    let segmentStart = 0;
    for (let index = 0; index < chunk.length; index += 1) {
      if (chunk[index] !== NEWLINE_BYTE) continue;
      if (segmentStart < index) {
        const segment = chunk.subarray(segmentStart, index);
        pendingChunks.push(segment);
        pendingLength += segment.length;
      }
      if (pendingLength > lineLimit) {
        blockedError = blockedErrorMessage(sourcePath, lineLimit, startOffset + committedByteCount);
        pendingChunks = [];
        pendingLength = 0;
        break readLoop;
      }

      const line = pendingLength === 0
        ? Buffer.alloc(0)
        : Buffer.concat(pendingChunks, pendingLength);
      if (firstTitle === null) {
        firstTitle = titleFromJsonLine(line.toString('utf8'));
      }
      await onRecord(line);
      committedByteCount += line.length + 1;
      lineCount += 1;
      pendingChunks = [];
      pendingLength = 0;
      segmentStart = index + 1;
    }

    if (segmentStart < chunk.length) {
      const segment = chunk.subarray(segmentStart);
      pendingChunks.push(segment);
      pendingLength += segment.length;
      if (pendingLength > lineLimit) {
        blockedError = blockedErrorMessage(sourcePath, lineLimit, startOffset + committedByteCount);
        pendingChunks = [];
        pendingLength = 0;
        break;
      }
    }
  }

  let pendingPartialLine = '';
  if (!blockedError && pendingLength > 0) {
    if (pendingLength <= MAX_PENDING_PARTIAL_BYTES) {
      pendingPartialLine = Buffer.concat(pendingChunks, pendingLength).toString('utf8');
    } else {
      pendingPartialLine = '\0';
    }
  }

  return {
    committedByteCount,
    lineCount,
    pendingPartialLine,
    blockedError,
    firstTitle,
  };
}

async function rebuildSessionCompleteLines({
  sourcePath,
  targetPath,
  maximumOffset = null,
  chunkSize = DEFAULT_CHUNK_SIZE,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
  interruptionRequested = () => false,
  onChunk = null,
  sync = (handle) => handle.sync(),
}) {
  if (maximumOffset !== null && (!Number.isSafeInteger(maximumOffset) || maximumOffset < 0)) {
    throw new Error(`Invalid maximum source offset: ${maximumOffset}`);
  }

  const sourceHandle = await fsp.open(sourcePath, 'r');
  const digest = crypto.createHash('sha256');
  let scanResult;
  try {
    await durableReplaceWithWriter(targetPath, async (targetHandle) => {
      scanResult = await scanCompleteRecords({
        sourceHandle,
        sourcePath,
        maximumByteCount: maximumOffset,
        chunkSize,
        maxLineBytes,
        interruptionRequested,
        onChunk,
        onRecord: async (line) => {
          if (line.length > 0) {
            await writeAll(targetHandle, line);
            digest.update(line);
          }
          await writeAll(targetHandle, NEWLINE);
          digest.update(NEWLINE);
        },
      });
    }, { sync });
  } finally {
    await sourceHandle.close();
  }

  return {
    ...scanResult,
    contentHash: digest.digest('hex'),
  };
}

function interruptedError() {
  const error = new Error('Integrity audit interrupted.');
  error.code = 'INTEGRITY_AUDIT_INTERRUPTED';
  return error;
}

async function rebuildCompleteLines(options) {
  const result = await rebuildSessionCompleteLines(options);
  return {
    committedByteCount: result.committedByteCount,
    lineCount: result.lineCount,
    contentHash: result.contentHash,
  };
}

async function appendCompleteLines({
  sourcePath,
  sourceOffset,
  targetPath,
  chunkSize = DEFAULT_CHUNK_SIZE,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
  sync = (handle) => handle.sync(),
}) {
  if (!Number.isSafeInteger(sourceOffset) || sourceOffset < 0) {
    throw new Error(`Invalid source offset: ${sourceOffset}`);
  }

  const sourceHandle = await fsp.open(sourcePath, 'r');
  let targetHandle;
  try {
    targetHandle = await fsp.open(targetPath, 'r+');
    const targetStats = await targetHandle.stat();
    if (targetStats.size !== sourceOffset) {
      throw new Error(`Backup target size changed during append: ${targetPath}`);
    }
    let writePosition = sourceOffset;
    const scanResult = await scanCompleteRecords({
      sourceHandle,
      sourcePath,
      startOffset: sourceOffset,
      chunkSize,
      maxLineBytes,
      onRecord: async (line) => {
        if (line.length > 0) {
          await writeAll(targetHandle, line, writePosition);
          writePosition += line.length;
        }
        await writeAll(targetHandle, NEWLINE, writePosition);
        writePosition += 1;
      },
    });
    if (scanResult.committedByteCount > 0) {
      await sync(targetHandle);
    }
    return {
      ...scanResult,
      appendedByteCount: scanResult.committedByteCount,
      committedByteCount: sourceOffset + scanResult.committedByteCount,
    };
  } finally {
    await targetHandle?.close().catch(() => {});
    await sourceHandle.close();
  }
}

async function readExactly(handle, position, byteCount) {
  const buffer = Buffer.allocUnsafe(byteCount);
  let offset = 0;
  while (offset < byteCount) {
    const { bytesRead } = await handle.read(
      buffer,
      offset,
      byteCount - offset,
      position + offset,
    );
    if (bytesRead === 0) break;
    offset += bytesRead;
  }
  return buffer.subarray(0, offset);
}

async function rangesMatch({
  sourcePath,
  sourceOffset,
  targetPath,
  targetOffset,
  length,
  chunkSize = DEFAULT_CHUNK_SIZE,
}) {
  for (const [name, value] of Object.entries({ sourceOffset, targetOffset, length })) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`Invalid ${name}: ${value}`);
    }
  }
  if (length === 0) return true;

  const boundedChunkSize = normalizedChunkSize(chunkSize);
  const sourceHandle = await fsp.open(sourcePath, 'r');
  let targetHandle;
  try {
    targetHandle = await fsp.open(targetPath, 'r');
    let compared = 0;
    while (compared < length) {
      const requested = Math.min(boundedChunkSize, length - compared);
      const [source, target] = await Promise.all([
        readExactly(sourceHandle, sourceOffset + compared, requested),
        readExactly(targetHandle, targetOffset + compared, requested),
      ]);
      if (source.length !== requested || target.length !== requested || !source.equals(target)) {
        return false;
      }
      compared += requested;
    }
    return true;
  } finally {
    await targetHandle?.close().catch(() => {});
    await sourceHandle.close();
  }
}

async function verifyCompletePrefix({
  sourcePath,
  targetPath,
  targetByteCount,
  chunkSize = DEFAULT_CHUNK_SIZE,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
}) {
  if (!Number.isSafeInteger(targetByteCount) || targetByteCount < 0) {
    throw new Error(`Invalid target byte count: ${targetByteCount}`);
  }
  if (targetByteCount === 0) {
    return {
      matches: true,
      byteCount: 0,
      lineCount: 0,
      contentHash: crypto.createHash('sha256').digest('hex'),
      firstTitle: null,
    };
  }

  const boundedChunkSize = normalizedChunkSize(chunkSize);
  const lineLimit = normalizedLineLimit(maxLineBytes);
  const digest = crypto.createHash('sha256');
  const sourceHandle = await fsp.open(sourcePath, 'r');
  let targetHandle;
  let compared = 0;
  let lineCount = 0;
  let pendingChunks = [];
  let pendingLength = 0;
  let firstTitle = null;
  try {
    targetHandle = await fsp.open(targetPath, 'r');
    while (compared < targetByteCount) {
      const requested = Math.min(boundedChunkSize, targetByteCount - compared);
      const [source, target] = await Promise.all([
        readExactly(sourceHandle, compared, requested),
        readExactly(targetHandle, compared, requested),
      ]);
      if (source.length !== requested || target.length !== requested || !source.equals(target)) {
        return { matches: false };
      }
      digest.update(target);

      let segmentStart = 0;
      for (let index = 0; index < target.length; index += 1) {
        if (target[index] !== NEWLINE_BYTE) continue;
        if (segmentStart < index) {
          const segment = target.subarray(segmentStart, index);
          pendingChunks.push(segment);
          pendingLength += segment.length;
        }
        if (pendingLength > lineLimit) return { matches: false };
        const line = pendingLength === 0
          ? Buffer.alloc(0)
          : Buffer.concat(pendingChunks, pendingLength);
        if (firstTitle === null) firstTitle = titleFromJsonLine(line.toString('utf8'));
        lineCount += 1;
        pendingChunks = [];
        pendingLength = 0;
        segmentStart = index + 1;
      }
      if (segmentStart < target.length) {
        const segment = target.subarray(segmentStart);
        pendingChunks.push(segment);
        pendingLength += segment.length;
        if (pendingLength > lineLimit) return { matches: false };
      }
      compared += requested;
    }

    if (pendingLength !== 0) return { matches: false };
    return {
      matches: true,
      byteCount: targetByteCount,
      lineCount,
      contentHash: digest.digest('hex'),
      firstTitle,
    };
  } finally {
    await targetHandle?.close().catch(() => {});
    await sourceHandle.close();
  }
}

function blockedErrorMessage(filePath, maxLineBytes, lineOffset) {
  return `Session JSONL line exceeds maximum JSONL line size of ${maxLineBytes} bytes at offset ${lineOffset}: ${filePath}`;
}

module.exports = {
  appendCompleteLines,
  rebuildCompleteLines,
  rebuildSessionCompleteLines,
  rangesMatch,
  verifyCompletePrefix,
};

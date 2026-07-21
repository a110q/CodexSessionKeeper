'use strict';

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');

const { durableReplaceWithWriter } = require('./durable-write');
const { titleFromJsonLine } = require('./session-identity');
const { MAX_JSONL_LINE_BYTES } = require('../jsonl-policy');

const NEWLINE_BYTE = 0x0A;
const DEFAULT_CHUNK_SIZE = 1024 * 1024;
const MAXIMUM_CHUNK_SIZE = 1024 * 1024;
const DEFAULT_WRITE_BUFFER_SIZE = 1024 * 1024;
const DEFAULT_MAX_LINE_BYTES = MAX_JSONL_LINE_BYTES;
const MAX_PENDING_PARTIAL_BYTES = 64 * 1024;
const MAX_TITLE_RECORD_BYTES = 64 * 1024;
const MAX_TITLE_SCAN_BYTES = 256 * 1024;
const MAX_TITLE_SCAN_RECORDS = 256;

function normalizedChunkSize(chunkSize) {
  const parsed = Number(chunkSize ?? DEFAULT_CHUNK_SIZE);
  return Math.min(MAXIMUM_CHUNK_SIZE, Math.max(1, Number.isFinite(parsed) ? Math.floor(parsed) : DEFAULT_CHUNK_SIZE));
}

function normalizedLineLimit(maxLineBytes) {
  const parsed = Number(maxLineBytes ?? DEFAULT_MAX_LINE_BYTES);
  return Math.max(0, Number.isFinite(parsed) ? Math.floor(parsed) : DEFAULT_MAX_LINE_BYTES);
}

function createTitleScanner() {
  let title = null;
  let parsedBytes = 0;
  let recordCount = 0;
  let exhausted = false;
  return {
    finishRecord(line, recordByteCount, captureOverflow) {
      if (title !== null || exhausted || recordCount >= MAX_TITLE_SCAN_RECORDS) return;
      recordCount += 1;
      if (captureOverflow || recordByteCount > MAX_TITLE_RECORD_BYTES) return;
      if (parsedBytes + recordByteCount > MAX_TITLE_SCAN_BYTES) {
        exhausted = true;
        return;
      }
      parsedBytes += recordByteCount;
      title = titleFromJsonLine(line.toString('utf8'));
    },
    get title() {
      return title;
    },
  };
}

function createRecordBoundaryScanner({
  sourcePath,
  startOffset = 0,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
}) {
  const lineLimit = normalizedLineLimit(maxLineBytes);
  const partial = Buffer.allocUnsafe(Math.min(
    MAX_PENDING_PARTIAL_BYTES,
    Math.max(1, lineLimit),
  ));
  const titleScanner = createTitleScanner();
  let committedByteCount = 0;
  let lineCount = 0;
  let currentLineBytes = 0;
  let partialLength = 0;
  let partialOverflow = false;
  let blockedError = null;

  function consume(chunk) {
    for (let index = 0; index < chunk.length; index += 1) {
      const byte = chunk[index];
      if (byte === NEWLINE_BYTE) {
        titleScanner.finishRecord(
          partial.subarray(0, partialLength),
          currentLineBytes,
          partialOverflow,
        );
        committedByteCount += currentLineBytes + 1;
        lineCount += 1;
        currentLineBytes = 0;
        partialLength = 0;
        partialOverflow = false;
        continue;
      }

      currentLineBytes += 1;
      if (currentLineBytes > lineLimit) {
        blockedError = blockedErrorMessage(
          sourcePath,
          lineLimit,
          startOffset + committedByteCount,
        );
        return false;
      }
      if (partialLength < partial.length) {
        partial[partialLength] = byte;
        partialLength += 1;
      } else {
        partialOverflow = true;
      }
    }
    return true;
  }

  function result() {
    return Object.freeze({
      committedByteCount,
      lineCount,
      pendingPartialLine: blockedError || currentLineBytes === 0
        ? ''
        : partialOverflow
          ? '\0'
          : partial.subarray(0, partialLength).toString('utf8'),
      blockedError,
      firstTitle: titleScanner.title,
    });
  }

  return { consume, result };
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

function createBufferedBackupWriter({
  bufferSize = DEFAULT_WRITE_BUFFER_SIZE,
  writeChunk,
}) {
  if (!Number.isSafeInteger(bufferSize) || bufferSize <= 0) {
    throw new Error(`Invalid backup write buffer size: ${bufferSize}`);
  }
  const buffer = Buffer.allocUnsafe(bufferSize);
  let bufferedLength = 0;

  async function flush() {
    if (bufferedLength === 0) return;
    await writeChunk(buffer.subarray(0, bufferedLength));
    bufferedLength = 0;
  }

  async function append(data) {
    let sourceOffset = 0;
    while (sourceOffset < data.length) {
      const count = Math.min(buffer.length - bufferedLength, data.length - sourceOffset);
      data.copy(buffer, bufferedLength, sourceOffset, sourceOffset + count);
      bufferedLength += count;
      sourceOffset += count;
      if (bufferedLength === buffer.length) await flush();
    }
  }

  async function appendByte(byte) {
    buffer[bufferedLength] = byte;
    bufferedLength += 1;
    if (bufferedLength === buffer.length) await flush();
  }

  return { append, appendByte, flush };
}

async function scanCompleteRecordBoundaries({
  sourceHandle,
  sourcePath,
  startOffset = 0,
  maximumByteCount = null,
  chunkSize,
  maxLineBytes,
  interruptionRequested = () => false,
  onChunk = null,
}) {
  const boundedChunkSize = normalizedChunkSize(chunkSize);
  let position = startOffset;
  let remaining = maximumByteCount;
  let scannerBuffer = null;
  const scanner = createRecordBoundaryScanner({ sourcePath, startOffset, maxLineBytes });

  while (remaining === null || remaining > 0) {
    if (interruptionRequested()) throw interruptedError();
    const requested = remaining === null
      ? boundedChunkSize
      : Math.min(boundedChunkSize, remaining);
    if (requested <= 0) break;
    scannerBuffer ||= Buffer.allocUnsafe(boundedChunkSize);
    const { bytesRead } = await sourceHandle.read(scannerBuffer, 0, requested, position);
    if (bytesRead === 0) break;
    const chunk = scannerBuffer.subarray(0, bytesRead);
    await onChunk?.(position, bytesRead, chunk);
    if (interruptionRequested()) throw interruptedError();
    position += bytesRead;
    if (remaining !== null) remaining -= bytesRead;
    if (!scanner.consume(chunk)) break;
  }

  return scanner.result();
}

async function copyCompleteByteRange({
  sourceHandle,
  startOffset,
  byteCount,
  chunkSize = DEFAULT_CHUNK_SIZE,
  writeChunk,
  interruptionRequested = () => false,
}) {
  const boundedChunkSize = normalizedChunkSize(chunkSize);
  const scratch = Buffer.allocUnsafe(boundedChunkSize);
  const digest = crypto.createHash('sha256');
  let copied = 0;

  while (copied < byteCount) {
    if (interruptionRequested()) throw interruptedError();
    const requested = Math.min(boundedChunkSize, byteCount - copied);
    const { bytesRead } = await sourceHandle.read(
      scratch,
      0,
      requested,
      startOffset + copied,
    );
    if (bytesRead !== requested) {
      throw new Error(
        `Source changed during streamed backup: expected ${requested}, got ${bytesRead}.`,
      );
    }
    const chunk = scratch.subarray(0, bytesRead);
    await writeChunk(chunk);
    digest.update(chunk);
    copied += bytesRead;
  }

  return Object.freeze({
    copiedByteCount: copied,
    contentHash: digest.digest('hex'),
  });
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
  verifyTemporary = null,
}) {
  if (maximumOffset !== null && (!Number.isSafeInteger(maximumOffset) || maximumOffset < 0)) {
    throw new Error(`Invalid maximum source offset: ${maximumOffset}`);
  }

  const sourceHandle = await fsp.open(sourcePath, 'r');
  try {
    const scanResult = await scanCompleteRecordBoundaries({
      sourceHandle,
      sourcePath,
      maximumByteCount: maximumOffset,
      chunkSize,
      maxLineBytes,
      interruptionRequested,
      onChunk,
    });
    let copyResult = null;
    await durableReplaceWithWriter(targetPath, async (targetHandle) => {
      const bufferedWriter = createBufferedBackupWriter({
        writeChunk: (chunk) => writeAll(targetHandle, chunk),
      });
      copyResult = await copyCompleteByteRange({
        sourceHandle,
        startOffset: 0,
        byteCount: scanResult.committedByteCount,
        chunkSize,
        interruptionRequested,
        writeChunk: (chunk) => bufferedWriter.append(chunk),
      });
      await bufferedWriter.flush();
    }, {
      sync,
      verifyTemporary: verifyTemporary
        ? (temporaryPath) => verifyTemporary(temporaryPath, {
          ...scanResult,
          contentHash: copyResult.contentHash,
        })
        : null,
    });

    return {
      ...scanResult,
      contentHash: copyResult.contentHash,
    };
  } finally {
    await sourceHandle.close();
  }
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
    const scanResult = await scanCompleteRecordBoundaries({
      sourceHandle,
      sourcePath,
      startOffset: sourceOffset,
      chunkSize,
      maxLineBytes,
    });
    targetHandle = await fsp.open(targetPath, 'r+');
    const targetStats = await targetHandle.stat();
    if (targetStats.size !== sourceOffset) {
      throw new Error(`Backup target size changed during append: ${targetPath}`);
    }
    let writePosition = sourceOffset;
    const bufferedWriter = createBufferedBackupWriter({
      writeChunk: async (chunk) => {
        await writeAll(targetHandle, chunk, writePosition);
        writePosition += chunk.length;
      },
    });
    await copyCompleteByteRange({
      sourceHandle,
      startOffset: sourceOffset,
      byteCount: scanResult.committedByteCount,
      chunkSize,
      writeChunk: (chunk) => bufferedWriter.append(chunk),
    });
    await bufferedWriter.flush();
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
  const digest = crypto.createHash('sha256');
  const scanner = createRecordBoundaryScanner({ sourcePath: targetPath, maxLineBytes });
  const sourceHandle = await fsp.open(sourcePath, 'r');
  let targetHandle;
  let compared = 0;
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
      if (!scanner.consume(target)) return { matches: false };
      compared += requested;
    }

    const scanResult = scanner.result();
    if (scanResult.blockedError || scanResult.pendingPartialLine !== '') {
      return { matches: false };
    }
    return {
      matches: true,
      byteCount: targetByteCount,
      lineCount: scanResult.lineCount,
      contentHash: digest.digest('hex'),
      firstTitle: scanResult.firstTitle,
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

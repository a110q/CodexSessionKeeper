const fs = require('node:fs');

const NEWLINE_BYTE = 0x0A;
const DEFAULT_MAX_LINE_BYTES = 32 * 1024 * 1024;
const MAX_PENDING_PARTIAL_BYTES = 64 * 1024;

function readNewCompleteLines(
  filePath,
  offset,
  maxReadBytes = 1024 * 1024,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
) {
  const fileSize = fs.statSync(filePath).size;
  const requestedOffset = Math.max(0, Number(offset) || 0);
  const startOffset = requestedOffset > fileSize ? 0 : requestedOffset;
  const chunkSize = Math.max(0, Number(maxReadBytes) || 0);
  const lineLimit = Math.max(0, Number(maxLineBytes) || 0);

  if (chunkSize === 0) {
    return {
      lines: [],
      nextOffset: startOffset,
      pendingPartialLine: '',
      blockedError: null,
    };
  }

  const fd = fs.openSync(filePath, 'r');
  const lines = [];
  let currentLineChunks = [];
  let currentLineLength = 0;
  let scannedByteCount = 0;
  let consumedByteCount = 0;
  let position = startOffset;
  let blockedError = null;

  try {
    while (position < fileSize) {
      const bytesToRead = Math.min(chunkSize, fileSize - position);
      const buffer = Buffer.allocUnsafe(bytesToRead);
      const bytesRead = fs.readSync(fd, buffer, 0, bytesToRead, position);
      if (bytesRead === 0) {
        break;
      }

      const chunk = buffer.subarray(0, bytesRead);
      position += bytesRead;

      let lineStart = 0;
      for (let index = 0; index < chunk.length; index += 1) {
        if (chunk[index] !== NEWLINE_BYTE) {
          continue;
        }

        if (lineStart < index) {
          const part = chunk.subarray(lineStart, index);
          currentLineChunks.push(part);
          currentLineLength += part.length;
        }
        if (currentLineLength > lineLimit) {
          blockedError = blockedErrorMessage(filePath, lineLimit, startOffset + consumedByteCount);
          break;
        }

        lines.push(Buffer.concat(currentLineChunks, currentLineLength).toString('utf8'));
        currentLineChunks = [];
        currentLineLength = 0;
        consumedByteCount = scannedByteCount + index + 1;
        lineStart = index + 1;
      }

      if (blockedError) {
        break;
      }

      if (lineStart < chunk.length) {
        const part = chunk.subarray(lineStart);
        currentLineChunks.push(part);
        currentLineLength += part.length;
        if (currentLineLength > lineLimit) {
          blockedError = blockedErrorMessage(filePath, lineLimit, startOffset + consumedByteCount);
          break;
        }
      }

      scannedByteCount += bytesRead;
    }
  } finally {
    fs.closeSync(fd);
  }

  if (scannedByteCount === 0 && lines.length === 0 && !blockedError) {
    return {
      lines: [],
      nextOffset: startOffset,
      pendingPartialLine: '',
      blockedError: null,
    };
  }

  const pendingPartialLine = !blockedError
    && currentLineLength > 0
    && currentLineLength <= MAX_PENDING_PARTIAL_BYTES
    ? Buffer.concat(currentLineChunks, currentLineLength).toString('utf8')
    : '';

  return {
    lines,
    nextOffset: startOffset + consumedByteCount,
    pendingPartialLine,
    blockedError,
  };
}

function blockedErrorMessage(filePath, maxLineBytes, lineOffset) {
  return `Session JSONL line exceeds maximum JSONL line size of ${maxLineBytes} bytes at offset ${lineOffset}: ${filePath}`;
}

module.exports = {
  readNewCompleteLines,
};

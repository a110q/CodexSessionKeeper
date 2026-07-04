const fs = require('node:fs');

const NEWLINE_BYTE = 0x0A;

function readNewCompleteLines(filePath, offset, maxReadBytes = 1024 * 1024) {
  const fileSize = fs.statSync(filePath).size;
  const requestedOffset = Math.max(0, Number(offset) || 0);
  const startOffset = requestedOffset > fileSize ? 0 : requestedOffset;
  const chunkSize = Math.max(0, Number(maxReadBytes) || 0);

  if (chunkSize === 0) {
    return {
      lines: [],
      nextOffset: startOffset,
      pendingPartialLine: '',
    };
  }

  const fd = fs.openSync(filePath, 'r');
  const chunks = [];
  let totalBytesRead = 0;
  let position = startOffset;

  try {
    while (position < fileSize) {
      const bytesToRead = Math.min(chunkSize, fileSize - position);
      const buffer = Buffer.allocUnsafe(bytesToRead);
      const bytesRead = fs.readSync(fd, buffer, 0, bytesToRead, position);
      if (bytesRead === 0) {
        break;
      }

      const chunk = buffer.subarray(0, bytesRead);
      chunks.push(chunk);
      totalBytesRead += bytesRead;
      position += bytesRead;

      if (chunk.includes(NEWLINE_BYTE)) {
        break;
      }
    }
  } finally {
    fs.closeSync(fd);
  }

  if (totalBytesRead === 0) {
    return {
      lines: [],
      nextOffset: startOffset,
      pendingPartialLine: '',
    };
  }

  const data = Buffer.concat(chunks, totalBytesRead);
  const lines = [];
  let lineStart = 0;
  let consumedByteCount = 0;

  for (let index = 0; index < data.length; index += 1) {
    if (data[index] !== NEWLINE_BYTE) {
      continue;
    }

    lines.push(data.subarray(lineStart, index).toString('utf8'));
    consumedByteCount = index + 1;
    lineStart = index + 1;
  }

  return {
    lines,
    nextOffset: startOffset + consumedByteCount,
    pendingPartialLine: lineStart < data.length
      ? data.subarray(lineStart).toString('utf8')
      : '',
  };
}

module.exports = {
  readNewCompleteLines,
};

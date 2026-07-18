'use strict';

const EMPTY_BUFFER = Buffer.alloc(0);
const INITIAL_CAPACITY_BYTES = 64 * 1024;

function createBoundedLineAccumulator(maxLineBytes) {
  if (!Number.isSafeInteger(maxLineBytes) || maxLineBytes < 0) {
    throw new Error(`Invalid maximum JSONL line size: ${maxLineBytes}`);
  }
  let buffer = null;
  let length = 0;
  function ensureCapacity(requiredLength) {
    if (buffer?.length >= requiredLength) return;
    let capacity = buffer?.length || Math.min(
      maxLineBytes,
      Math.max(INITIAL_CAPACITY_BYTES, requiredLength),
    );
    while (capacity < requiredLength) {
      capacity = Math.min(maxLineBytes, Math.max(requiredLength, capacity * 2));
    }
    const replacement = Buffer.allocUnsafe(capacity);
    if (length > 0) buffer.copy(replacement, 0, 0, length);
    buffer = replacement;
  }
  return {
    append(data) {
      const nextLength = length + data.length;
      if (nextLength > maxLineBytes) return false;
      if (data.length > 0) {
        ensureCapacity(nextLength);
        data.copy(buffer, length);
      }
      length = nextLength;
      return true;
    },
    reset() {
      buffer = null;
      length = 0;
    },
    view() {
      return length === 0 ? EMPTY_BUFFER : buffer.subarray(0, length);
    },
    get length() {
      return length;
    },
  };
}

module.exports = { createBoundedLineAccumulator };

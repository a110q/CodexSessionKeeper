const fs = require('node:fs');
const { ensureRecoveredThreadsInStateDatabase } = require('./live-state-database');
const { createBoundedLineAccumulator } = require('./jsonl-line-accumulator');
const { MAX_JSONL_LINE_BYTES } = require('../jsonl-policy');

const MAX_RECOVERED_METADATA_LINES = 400;
const MAX_RECOVERED_PREVIEW_CHARS = 4096;

function collapseWhitespace(value) {
  return String(value || '').split(/\s+/).filter(Boolean).join(' ');
}

function normalizedTitle(value) {
  const normalized = collapseWhitespace(value);
  return normalized ? normalized.slice(0, 180) : '';
}

function parseDateMs(value) {
  const ms = Date.parse(value || '');
  return Number.isFinite(ms) ? ms : null;
}

function firstUserMessageContent(object) {
  if (object.role === 'user') return object.content;
  const payload = object.payload || {};
  if (payload.type === 'user_message') return payload.message || payload.content;
  if (payload.role === 'user') return payload.content;
  return '';
}

function independentString(value) {
  const codeUnits = new Uint16Array(value.length);
  for (let index = 0; index < value.length; index += 1) codeUnits[index] = value.charCodeAt(index);
  return String.fromCharCode(...codeUnits);
}

function boundedCollapsedText(value, maximumChars) {
  const parts = typeof value === 'string'
    ? [value]
    : Array.isArray(value)
      ? value.map((item) => item && (item.text || item.content || '')).filter(Boolean)
      : [];
  let output = '';
  partsLoop: for (const part of parts) {
    const text = String(part);
    const words = /\S+/g;
    let match;
    while ((match = words.exec(text)) !== null) {
      if (output.length > 0) output += ' ';
      const remaining = maximumChars - output.length;
      if (remaining <= 0) break partsLoop;
      output += match[0].slice(0, remaining);
      if (output.length === maximumChars) break partsLoop;
    }
  }
  return independentString(output);
}

async function extractRecoveredThreadMetadata(
  record,
  recoveredPath,
  codexRoot,
  { maxLineBytes = MAX_JSONL_LINE_BYTES, readBufferBytes = 1024 * 1024 } = {},
) {
  let firstTimestamp = null;
  let lastTimestamp = null;
  let userMessage = '';
  let provider = '';
  let model = '';
  let cwd = '';
  let source = '';
  let sandboxPolicy = '';
  let approvalMode = '';
  let reasoningEffort = '';
  let cliVersion = '';
  let memoryMode = '';

  for await (const line of recoveredJsonlLines(recoveredPath, MAX_RECOVERED_METADATA_LINES, {
    maxLineBytes,
    readBufferBytes,
  })) {
    let object;
    try {
      object = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = object.payload || {};
    const timestamp = parseDateMs(object.timestamp);
    if (timestamp !== null) {
      if (firstTimestamp === null) firstTimestamp = timestamp;
      lastTimestamp = timestamp;
    }
    provider ||= object.model_provider || payload.model_provider || '';
    model ||= object.model || payload.model || '';
    cwd ||= object.cwd || payload.cwd || '';
    source ||= object.source || payload.source || '';
    sandboxPolicy ||= object.sandbox_policy || payload.sandbox_policy || '';
    approvalMode ||= object.approval_mode || payload.approval_mode || '';
    reasoningEffort ||= object.reasoning_effort || payload.reasoning_effort || '';
    cliVersion ||= object.cli_version || payload.cli_version || '';
    memoryMode ||= object.memory_mode || payload.memory_mode || '';
    if (!userMessage) {
      userMessage = boundedCollapsedText(firstUserMessageContent(object), MAX_RECOVERED_PREVIEW_CHARS);
    }
  }

  const createdMs = firstTimestamp ?? parseDateMs(record.firstSeenAt) ?? 0;
  const updatedMs = lastTimestamp ?? parseDateMs(record.lastBackedUpAt || record.firstSeenAt) ?? createdMs;
  const title = normalizedTitle(record.title) || normalizedTitle(userMessage) || String(record.sessionId);

  return {
    id: String(record.sessionId),
    rolloutPath: recoveredPath,
    createdAt: Math.floor(createdMs / 1000),
    updatedAt: Math.floor(updatedMs / 1000),
    source: normalizedTitle(source) || 'recovered',
    modelProvider: normalizedTitle(provider) || 'unknown',
    cwd: cwd || '',
    title,
    sandboxPolicy,
    approvalMode,
    tokensUsed: 0,
    hasUserEvent: userMessage ? 1 : 0,
    archived: 0,
    archivedAt: null,
    firstUserMessage: userMessage,
    model: normalizedTitle(model) || 'unknown',
    preview: userMessage,
    recencyAt: Math.floor(updatedMs / 1000),
    createdAtMs: createdMs,
    updatedAtMs: updatedMs,
    recencyAtMs: updatedMs,
    threadSource: 'recovered',
    reasoningEffort: reasoningEffort || null,
    cliVersion: cliVersion || '',
    memoryMode: memoryMode || 'enabled',
    gitSHA: null,
    gitBranch: null,
    gitOriginURL: null,
    agentNickname: null,
    agentRole: null,
    agentPath: null,
    codexRoot,
  };
}

async function* recoveredJsonlLines(
  filePath,
  limit = 400,
  { maxLineBytes = MAX_JSONL_LINE_BYTES, readBufferBytes = 1024 * 1024 } = {},
) {
  const lineLimit = Number.isSafeInteger(maxLineBytes) && maxLineBytes >= 0
    ? maxLineBytes
    : MAX_JSONL_LINE_BYTES;
  const bufferSize = Number.isSafeInteger(readBufferBytes) && readBufferBytes > 0
    ? readBufferBytes
    : 1024 * 1024;
  const buffer = Buffer.allocUnsafe(bufferSize);
  const handle = await fs.promises.open(filePath, 'r');
  let lineCount = 0;
  const pending = createBoundedLineAccumulator(lineLimit);
  let position = 0;
  try {
    while (lineCount < limit) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
      if (bytesRead === 0) break;
      const chunk = buffer.subarray(0, bytesRead);
      position += bytesRead;
      let start = 0;
      for (let index = 0; index < chunk.length; index += 1) {
        if (chunk[index] !== 0x0A) continue;
        const segment = chunk.subarray(start, index);
        const lineLength = pending.length + segment.length;
        if (lineLength > lineLimit) {
          throw new Error(`Recovered JSONL line exceeds ${lineLimit} bytes.`);
        }
        let line = '';
        if (lineLength > 0) {
          if (pending.length > 0) {
            pending.append(segment);
            line = pending.view().toString('utf8');
          } else {
            line = segment.toString('utf8');
          }
        }
        pending.reset();
        start = index + 1;
        if (lineLength > 0) {
          lineCount += 1;
          yield line;
          if (lineCount === limit) return;
        }
      }
      if (start < chunk.length) {
        if (!pending.append(chunk.subarray(start))) {
          throw new Error(`Recovered JSONL line exceeds ${lineLimit} bytes.`);
        }
      }
    }
    if (pending.length > 0 && lineCount < limit) {
      const line = pending.view().toString('utf8');
      pending.reset();
      yield line;
    }
  } finally {
    await handle.close();
  }
}

module.exports = {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
};

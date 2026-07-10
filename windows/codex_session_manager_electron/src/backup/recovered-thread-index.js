const fs = require('node:fs');
const { ensureRecoveredThreadsInStateDatabase } = require('./live-state-database');

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

function textContent(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map((item) => item && (item.text || item.content || '')).filter(Boolean).join(' ');
  }
  return '';
}

function firstUserMessage(object) {
  if (object.role === 'user') return textContent(object.content);
  const payload = object.payload || {};
  if (payload.type === 'user_message') return textContent(payload.message || payload.content);
  if (payload.role === 'user') return textContent(payload.content);
  return '';
}

async function extractRecoveredThreadMetadata(record, recoveredPath, codexRoot) {
  const text = await fs.promises.readFile(recoveredPath, 'utf8');
  const lines = text.split(/\n/).filter((line) => line.trim()).slice(0, 400);
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

  for (const line of lines) {
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
    if (!userMessage) userMessage = collapseWhitespace(firstUserMessage(object));
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

module.exports = {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
};

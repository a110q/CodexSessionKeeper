const fs = require('node:fs');
const path = require('node:path');

let sqlPromise;

function getSqlJs() {
  if (!sqlPromise) {
    const initSqlJs = require('sql.js');
    sqlPromise = initSqlJs({
      locateFile: (file) => path.join(__dirname, '..', '..', 'node_modules', 'sql.js', 'dist', file),
    });
  }
  return sqlPromise;
}

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

function execRows(db, sql, params = []) {
  const statement = db.prepare(sql);
  try {
    statement.bind(params);
    const rows = [];
    while (statement.step()) rows.push(statement.getAsObject());
    return rows;
  } finally {
    statement.free();
  }
}

function tableExists(db, table) {
  return execRows(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;", [table]).length > 0;
}

function tableColumns(db, table) {
  return execRows(db, `PRAGMA table_info(${quoteIdent(table)});`);
}

function quoteIdent(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function entryValues(entry) {
  return {
    id: entry.id,
    rollout_path: entry.rolloutPath,
    created_at: entry.createdAt,
    updated_at: entry.updatedAt,
    source: entry.source,
    model_provider: entry.modelProvider,
    cwd: entry.cwd,
    title: entry.title,
    sandbox_policy: entry.sandboxPolicy,
    approval_mode: entry.approvalMode,
    tokens_used: entry.tokensUsed,
    has_user_event: entry.hasUserEvent,
    archived: entry.archived,
    archived_at: entry.archivedAt,
    first_user_message: entry.firstUserMessage,
    model: entry.model,
    preview: entry.preview,
    recency_at: entry.recencyAt,
    created_at_ms: entry.createdAtMs,
    updated_at_ms: entry.updatedAtMs,
    recency_at_ms: entry.recencyAtMs,
    thread_source: entry.threadSource,
    reasoning_effort: entry.reasoningEffort,
    cli_version: entry.cliVersion,
    memory_mode: entry.memoryMode,
    git_sha: entry.gitSHA,
    git_branch: entry.gitBranch,
    git_origin_url: entry.gitOriginURL,
    agent_nickname: entry.agentNickname,
    agent_role: entry.agentRole,
    agent_path: entry.agentPath,
  };
}

function fallbackValue(column) {
  const type = String(column.type || '').toUpperCase();
  if (type.includes('INT') || type.includes('REAL') || type.includes('NUM')) return 0;
  return '';
}

function result(insertedCount, skippedCount, warning = null) {
  return {
    insertedCount,
    skippedCount,
    warning,
    message: warning || `已补写列表索引：新增 ${insertedCount} 个，跳过 ${skippedCount} 个。`,
  };
}

async function ensureRecoveredThreadsInStateDatabase(databasePath, entries) {
  if (!entries.length) return result(0, 0);
  if (!fs.existsSync(databasePath)) {
    return result(0, 0, 'SQLite 索引未写入：state_5.sqlite 不存在');
  }

  const SQL = await getSqlJs();
  const db = new SQL.Database(await fs.promises.readFile(databasePath));
  let committed = false;
  try {
    if (!tableExists(db, 'threads')) {
      return result(0, 0, 'SQLite 索引未写入：threads 表不存在');
    }
    const columns = tableColumns(db, 'threads');
    let insertedCount = 0;
    let skippedCount = 0;
    db.run('BEGIN IMMEDIATE;');
    for (const entry of entries) {
      if (execRows(db, 'SELECT id FROM threads WHERE id = ?;', [entry.id]).length) {
        skippedCount += 1;
        continue;
      }
      const values = entryValues(entry);
      const writable = [];
      for (const column of columns) {
        if (Object.prototype.hasOwnProperty.call(values, column.name)) {
          writable.push([column.name, values[column.name]]);
        } else if (Number(column.notnull || 0) === 1 && column.dflt_value == null) {
          writable.push([column.name, fallbackValue(column)]);
        }
      }
      const names = writable.map(([name]) => quoteIdent(name)).join(', ');
      const placeholders = writable.map(() => '?').join(', ');
      db.run(
        `INSERT INTO threads (${names}) VALUES (${placeholders});`,
        writable.map(([, value]) => value)
      );
      insertedCount += 1;
    }
    db.run('COMMIT;');
    committed = true;
    if (insertedCount > 0) {
      await fs.promises.writeFile(databasePath, Buffer.from(db.export()));
    }
    return result(insertedCount, skippedCount);
  } catch (error) {
    if (!committed) {
      try { db.run('ROLLBACK;'); } catch {}
    }
    return result(0, 0, `SQLite 索引未写入：${error.message}`);
  } finally {
    db.close();
  }
}

module.exports = {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
};

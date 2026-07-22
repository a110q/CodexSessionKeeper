const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const conversationStateTables = [
  'threads',
  'thread_goals',
  'thread_dynamic_tools',
  'thread_spawn_edges',
  'stage1_outputs',
  'agent_job_items',
];

function quoteIdent(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function quoteLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function resolveSqlitePath(requestedPath = null) {
  if (requestedPath) return requestedPath;
  if (process.env.CODEX_SESSION_MANAGER_SQLITE3) return process.env.CODEX_SESSION_MANAGER_SQLITE3;
  if (process.platform !== 'win32') return '/usr/bin/sqlite3';

  const bundledPath = path.join(__dirname, '..', '..', 'vendor', 'sqlite3.exe');
  if (fs.existsSync(bundledPath)) return bundledPath;
  throw new Error('内置 sqlite3.exe 缺失，请重新下载完整便携包。');
}

function sqliteError(stderr, sqlitePath) {
  const detail = String(stderr || '').trim();
  if (/database is (locked|busy)/i.test(detail)) {
    const error = new Error('SQLite 数据库正忙，5 秒内未获得写锁；请稍后重试。');
    error.code = 'SQLITE_BUSY';
    return error;
  }
  return new Error(detail || `sqlite3 执行失败：${sqlitePath}`);
}

function runSQLite(databasePath, sql, options = {}) {
  const sqlitePath = resolveSqlitePath(options.sqlitePath);
  const busyTimeoutMs = options.busyTimeoutMs ?? 5000;
  const args = options.json ? ['-json', databasePath] : [databasePath];
  const input = `.bail on\n.timeout ${busyTimeoutMs}\n${sql.trim()}\n`;

  return new Promise((resolve, reject) => {
    const child = spawn(sqlitePath, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (status) => {
      if (status === 0) resolve(stdout);
      else reject(sqliteError(stderr, sqlitePath));
    });
    child.stdin.end(input);
  });
}

async function queryRows(databasePath, sql, options = {}) {
  const output = (await runSQLite(databasePath, sql, { ...options, json: true })).trim();
  return output ? JSON.parse(output) : [];
}

async function tableInfo(databasePath, table, options) {
  return queryRows(databasePath, `PRAGMA table_info(${quoteIdent(table)});`, options);
}

async function tableColumns(databasePath, table, options) {
  const rows = await tableInfo(databasePath, table, options);
  return rows.map((row) => row.name);
}

function sessionIdList(allowedSessionIds) {
  return [...allowedSessionIds].map(quoteLiteral).join(', ');
}

function sourceWhereClause(table, allowedSessionIds) {
  if (!allowedSessionIds) return '';
  if (allowedSessionIds.size === 0) return ' WHERE 0';
  const ids = sessionIdList(allowedSessionIds);
  if (table === 'threads') return ` WHERE id IN (${ids})`;
  if (table === 'thread_spawn_edges') return ` WHERE parent_thread_id IN (${ids}) OR child_thread_id IN (${ids})`;
  if (table === 'agent_job_items') return ` WHERE assigned_thread_id IN (${ids})`;
  return ` WHERE thread_id IN (${ids})`;
}

async function mergePlan(sourceDbPath, destinationDbPath, allowedSessionIds, options) {
  const plan = [];
  for (const table of conversationStateTables) {
    const [sourceColumns, destinationColumns] = await Promise.all([
      tableColumns(sourceDbPath, table, options),
      tableColumns(destinationDbPath, table, options),
    ]);
    const commonColumns = destinationColumns.filter((column) => sourceColumns.includes(column));
    if (!commonColumns.length) continue;
    const columns = commonColumns.map(quoteIdent).join(', ');
    plan.push({
      table,
      insert: `INSERT OR REPLACE INTO ${quoteIdent(table)} (${columns}) `
        + `SELECT ${columns} FROM snapshot.${quoteIdent(table)}${sourceWhereClause(table, allowedSessionIds)};`,
    });
  }
  return plan;
}

function buildAttachedWriteTransactionSql(sourceDbPath, statements) {
  return `
    PRAGMA foreign_keys = OFF;
    BEGIN IMMEDIATE;
    ATTACH DATABASE ${quoteLiteral(sourceDbPath)} AS snapshot;
    ${statements}
    COMMIT;
    DETACH DATABASE snapshot;
    PRAGMA foreign_keys = ON;
  `;
}

async function mergeStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds = null, options = {}) {
  if (!fs.existsSync(sourceDbPath)) return 'SQLite 索引未合并：快照数据库缺失。';
  if (allowedSessionIds && allowedSessionIds.size === 0) {
    return 'SQLite 索引未合并：快照中没有可恢复的会话文件。';
  }

  if (!fs.existsSync(destinationDbPath)) {
    fs.mkdirSync(path.dirname(destinationDbPath), { recursive: true });
    try {
      fs.copyFileSync(sourceDbPath, destinationDbPath, fs.constants.COPYFILE_EXCL);
      await replaceStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds, options);
      return 'SQLite 索引已恢复，并清理账号绑定表。';
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
  }

  const plan = await mergePlan(sourceDbPath, destinationDbPath, allowedSessionIds, options);
  await runSQLite(
    destinationDbPath,
    buildAttachedWriteTransactionSql(sourceDbPath, plan.map((item) => item.insert).join('\n')),
    options
  );
  return 'SQLite 索引已合并。';
}

async function replaceStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds, options = {}) {
  if (!fs.existsSync(sourceDbPath)) return 'SQLite 索引未恢复：快照数据库缺失。';
  if (!fs.existsSync(destinationDbPath)) {
    fs.mkdirSync(path.dirname(destinationDbPath), { recursive: true });
    try {
      fs.copyFileSync(sourceDbPath, destinationDbPath, fs.constants.COPYFILE_EXCL);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
  }

  const plan = await mergePlan(sourceDbPath, destinationDbPath, allowedSessionIds, options);
  const accountTables = [];
  for (const table of ['device_key_bindings', 'remote_control_enrollments']) {
    if ((await tableColumns(destinationDbPath, table, options)).length) accountTables.push(table);
  }

  const statements = [
    ...plan.map((item) => `DELETE FROM ${quoteIdent(item.table)};`),
    ...plan.map((item) => item.insert),
    ...accountTables.map((table) => `DELETE FROM ${quoteIdent(table)};`),
  ].join('\n');
  await runSQLite(
    destinationDbPath,
    buildAttachedWriteTransactionSql(sourceDbPath, statements),
    options
  );
  return 'SQLite 索引已完整恢复。';
}

async function repairStateDatabaseRolloutPaths(databasePath, updates, options = {}) {
  if (!fs.existsSync(databasePath) || !updates.length) return;
  const columns = await tableColumns(databasePath, 'threads', options);
  if (!columns.length || !columns.includes('rollout_path')) return;
  const hasArchived = columns.includes('archived');
  const statements = updates.map((update) => {
    const archived = hasArchived && update.archived !== null && update.archived !== undefined
      ? `, archived = ${update.archived ? 1 : 0}`
      : '';
    return `UPDATE threads SET rollout_path = ${quoteLiteral(update.rolloutPath)}${archived} `
      + `WHERE id = ${quoteLiteral(update.sessionId)};`;
  });
  await runSQLite(databasePath, `
    PRAGMA foreign_keys = OFF;
    BEGIN IMMEDIATE;
    ${statements.join('\n')}
    COMMIT;
    PRAGMA foreign_keys = ON;
  `, options);
}

async function mergeSingleSessionStateDb(snapshotDbPath, destinationDbPath, sessionId, options = {}) {
  if (!fs.existsSync(snapshotDbPath) || !fs.existsSync(destinationDbPath)) {
    return 'SQLite 索引未合并：数据库文件缺失。';
  }
  return mergeStateDatabase(snapshotDbPath, destinationDbPath, new Set([sessionId]), options);
}

async function deleteSingleSessionStateDb(destinationDbPath, sessionId, options = {}) {
  if (!fs.existsSync(destinationDbPath)) return 'SQLite 索引未删除：数据库文件缺失。';
  const id = quoteLiteral(sessionId);
  const rules = [
    { table: 'thread_dynamic_tools', sql: `DELETE FROM thread_dynamic_tools WHERE thread_id = ${id};` },
    { table: 'thread_goals', sql: `DELETE FROM thread_goals WHERE thread_id = ${id};` },
    { table: 'thread_spawn_edges', sql: `DELETE FROM thread_spawn_edges WHERE parent_thread_id = ${id} OR child_thread_id = ${id};` },
    { table: 'stage1_outputs', sql: `DELETE FROM stage1_outputs WHERE thread_id = ${id};` },
    { table: 'agent_job_items', sql: `DELETE FROM agent_job_items WHERE assigned_thread_id = ${id};` },
    { table: 'threads', sql: `DELETE FROM threads WHERE id = ${id};` },
  ];
  const statements = [];
  for (const rule of rules) {
    if ((await tableColumns(destinationDbPath, rule.table, options)).length) statements.push(rule.sql);
  }
  await runSQLite(destinationDbPath, `
    PRAGMA foreign_keys = OFF;
    BEGIN IMMEDIATE;
    ${statements.join('\n')}
    COMMIT;
    PRAGMA foreign_keys = ON;
  `, options);
  return 'SQLite 索引已删除。';
}

function recoveredThreadValues(entry) {
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

function sqlValue(value) {
  if (value === null || value === undefined) return 'NULL';
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  if (typeof value === 'boolean') return value ? '1' : '0';
  return quoteLiteral(value);
}

function recoveryResult(insertedCount, skippedCount, warning = null) {
  return {
    insertedCount,
    skippedCount,
    warning,
    message: warning || `已补写列表索引：新增 ${insertedCount} 个，跳过 ${skippedCount} 个。`,
  };
}

async function ensureRecoveredThreadsInStateDatabase(databasePath, entries, options = {}) {
  if (!entries.length) return recoveryResult(0, 0);
  if (!fs.existsSync(databasePath)) {
    return recoveryResult(0, 0, 'SQLite 索引未写入：state_5.sqlite 不存在');
  }

  try {
    const columns = await tableInfo(databasePath, 'threads', options);
    if (!columns.length) return recoveryResult(0, 0, 'SQLite 索引未写入：threads 表不存在');
    const ids = entries.map((entry) => quoteLiteral(entry.id)).join(', ');
    const existingRows = await queryRows(databasePath, `SELECT id FROM threads WHERE id IN (${ids});`, options);
    const existing = new Set(existingRows.map((row) => String(row.id)));
    const missing = entries.filter((entry) => !existing.has(String(entry.id)));
    const statements = missing.map((entry) => {
      const values = recoveredThreadValues(entry);
      const writable = [];
      for (const column of columns) {
        if (Object.prototype.hasOwnProperty.call(values, column.name)) {
          writable.push([column.name, values[column.name]]);
        } else if (Number(column.notnull || 0) === 1 && column.dflt_value == null) {
          writable.push([column.name, fallbackValue(column)]);
        }
      }
      const names = writable.map(([name]) => quoteIdent(name)).join(', ');
      const sqlValues = writable.map(([, value]) => sqlValue(value)).join(', ');
      return `INSERT OR IGNORE INTO threads (${names}) VALUES (${sqlValues});`;
    });

    if (statements.length) {
      await runSQLite(databasePath, `
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE;
        ${statements.join('\n')}
        COMMIT;
        PRAGMA foreign_keys = ON;
      `, options);
    }
    return recoveryResult(missing.length, entries.length - missing.length);
  } catch (error) {
    return recoveryResult(0, 0, `SQLite 索引未写入：${error.message}`);
  }
}

module.exports = {
  buildAttachedWriteTransactionSql,
  deleteSingleSessionStateDb,
  ensureRecoveredThreadsInStateDatabase,
  mergeStateDatabase,
  mergeSingleSessionStateDb,
  repairStateDatabaseRolloutPaths,
  replaceStateDatabase,
  resolveSqlitePath,
  runSQLite,
};

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
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
  const error = new Error(detail || `sqlite3 执行失败：${sqlitePath}`);
  if (/unique constraint failed|primary key|constraint failed/i.test(detail)) {
    error.code = 'SQLITE_RESTORE_CONFLICT';
  }
  return error;
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

function selectedPredicate(table, ids, alias = null) {
  const column = (name) => `${alias ? `${quoteIdent(alias)}.` : ''}${quoteIdent(name)}`;
  if (table === 'threads') return `${column('id')} IN (${ids})`;
  if (table === 'thread_spawn_edges') {
    return `${column('parent_thread_id')} IN (${ids}) OR ${column('child_thread_id')} IN (${ids})`;
  }
  if (table === 'agent_job_items') return `${column('assigned_thread_id')} IN (${ids})`;
  return `${column('thread_id')} IN (${ids})`;
}

function sourceWhereClause(table, allowedSessionIds) {
  if (!allowedSessionIds) return '';
  if (allowedSessionIds.size === 0) return ' WHERE 0';
  const ids = sessionIdList(allowedSessionIds);
  return ` WHERE ${selectedPredicate(table, ids)}`;
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
      columns: commonColumns,
      deleteSelected: allowedSessionIds
        ? `DELETE FROM ${quoteIdent(table)}${sourceWhereClause(table, allowedSessionIds)};`
        : `DELETE FROM ${quoteIdent(table)};`,
      insert: `INSERT INTO ${quoteIdent(table)} (${columns}) `
        + `SELECT ${columns} FROM snapshot.${quoteIdent(table)}${sourceWhereClause(table, allowedSessionIds)};`,
    });
  }
  return plan;
}

async function uniqueKeys(databasePath, table, options) {
  const info = await tableInfo(databasePath, table, options);
  const primaryKey = info
    .filter((column) => Number(column.pk || 0) > 0)
    .sort((left, right) => Number(left.pk) - Number(right.pk))
    .map((column) => column.name);
  const keys = primaryKey.length ? [primaryKey] : [];
  const indexes = await queryRows(databasePath, `PRAGMA index_list(${quoteIdent(table)});`, options);
  for (const index of indexes) {
    if (Number(index.unique || 0) !== 1 || typeof index.name !== 'string') continue;
    const columns = (await queryRows(
      databasePath,
      `PRAGMA index_info(${quoteIdent(index.name)});`,
      options,
    )).map((column) => column.name).filter((name) => typeof name === 'string');
    if (columns.length) keys.push(columns);
  }
  const seen = new Set();
  return keys.filter((columns) => {
    const key = columns.join('\0');
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

async function preflightMergeStateDatabase(
  sourceDbPath,
  destinationDbPath,
  allowedSessionIds,
  options = {},
) {
  if (!allowedSessionIds || allowedSessionIds.size === 0) return;
  if (!fs.existsSync(sourceDbPath) || !fs.existsSync(destinationDbPath)) return;
  const ids = sessionIdList(allowedSessionIds);
  const plan = await mergePlan(sourceDbPath, destinationDbPath, allowedSessionIds, options);
  for (const item of plan) {
    const keys = await uniqueKeys(destinationDbPath, item.table, options);
    for (const key of keys) {
      if (!key.every((column) => item.columns.includes(column))) continue;
      const equality = key.map((column) => (
        `${quoteIdent('incoming')}.${quoteIdent(column)} = ${quoteIdent('live')}.${quoteIdent(column)}`
      )).join(' AND ');
      const conflicts = await queryRows(destinationDbPath, `
        ATTACH DATABASE ${quoteLiteral(sourceDbPath)} AS snapshot;
        SELECT 1 AS conflict
        FROM snapshot.${quoteIdent(item.table)} AS ${quoteIdent('incoming')}
        JOIN main.${quoteIdent(item.table)} AS ${quoteIdent('live')} ON ${equality}
        WHERE (${selectedPredicate(item.table, ids, 'incoming')})
          AND NOT (${selectedPredicate(item.table, ids, 'live')})
        LIMIT 1;
        DETACH DATABASE snapshot;
      `, options);
      if (conflicts.length) {
        const error = new Error(`SQLite 恢复发生跨会话唯一键冲突：${item.table}(${key.join(', ')})`);
        error.code = 'SQLITE_RESTORE_CONFLICT';
        throw error;
      }
    }
  }
}

async function rolloutPathStatements(databasePath, updates = [], options = {}) {
  if (!updates.length) return [];
  const columns = await tableColumns(databasePath, 'threads', options);
  if (!columns.includes('id') || !columns.includes('rollout_path')) return [];
  const hasArchived = columns.includes('archived');
  return updates.map((update) => {
    const archived = hasArchived && update.archived !== null && update.archived !== undefined
      ? `, archived = ${update.archived ? 1 : 0}`
      : '';
    return `UPDATE threads SET rollout_path = ${quoteLiteral(update.rolloutPath)}${archived} `
      + `WHERE id = ${quoteLiteral(update.sessionId)};`;
  });
}

function candidatePathFor(destinationDbPath) {
  const nonce = `${process.pid}-${crypto.randomUUID()}`;
  return path.join(path.dirname(destinationDbPath), `.${path.basename(destinationDbPath)}.candidate-${nonce}`);
}

function removeDatabaseArtifacts(databasePath) {
  for (const suffix of ['', '-wal', '-shm']) {
    try {
      fs.rmSync(`${databasePath}${suffix}`, { force: true });
    } catch {
      // Keep the original error; orphan cleanup is best effort.
    }
  }
}

async function candidateSanitizationPlan(candidatePath, allowedSessionIds, options) {
  const statements = [];
  if (allowedSessionIds) {
    for (const table of conversationStateTables) {
      if (!(await tableColumns(candidatePath, table, options)).length) continue;
      if (allowedSessionIds.size === 0) {
        statements.push(`DELETE FROM ${quoteIdent(table)};`);
      } else {
        const selected = sourceWhereClause(table, allowedSessionIds).replace(/^ WHERE /, '');
        statements.push(`DELETE FROM ${quoteIdent(table)} WHERE NOT (${selected});`);
      }
    }
  }
  for (const table of ['device_key_bindings', 'remote_control_enrollments']) {
    if ((await tableColumns(candidatePath, table, options)).length) {
      statements.push(`DELETE FROM ${quoteIdent(table)};`);
    }
  }
  statements.push(...await rolloutPathStatements(candidatePath, options.rolloutPathUpdates, options));
  return statements;
}

async function validateCandidate(candidatePath, allowedSessionIds, options) {
  const integrity = String(await runSQLite(candidatePath, 'PRAGMA integrity_check;', options)).trim();
  if (integrity !== 'ok') throw new Error(`SQLite integrity_check 未通过：${integrity || '无结果'}`);

  if (allowedSessionIds) {
    for (const table of conversationStateTables) {
      if (!(await tableColumns(candidatePath, table, options)).length) continue;
      const selected = sourceWhereClause(table, allowedSessionIds).replace(/^ WHERE /, '');
      const rows = await queryRows(
        candidatePath,
        `SELECT COUNT(*) AS count FROM ${quoteIdent(table)} WHERE NOT (${selected});`,
        options,
      );
      if (Number(rows[0]?.count || 0) !== 0) {
        throw new Error(`SQLite 候选库包含未选择会话：${table}`);
      }
    }
  }
  for (const table of ['device_key_bindings', 'remote_control_enrollments']) {
    if (!(await tableColumns(candidatePath, table, options)).length) continue;
    const rows = await queryRows(candidatePath, `SELECT COUNT(*) AS count FROM ${quoteIdent(table)};`, options);
    if (Number(rows[0]?.count || 0) !== 0) throw new Error(`SQLite 候选库账号表未清空：${table}`);
  }
}

async function publishSanitizedCandidate(sourceDbPath, destinationDbPath, allowedSessionIds, options) {
  fs.mkdirSync(path.dirname(destinationDbPath), { recursive: true });
  const candidatePath = candidatePathFor(destinationDbPath);
  try {
    await runSQLite(sourceDbPath, `VACUUM INTO ${quoteLiteral(candidatePath)};`, options);
    const statements = await candidateSanitizationPlan(candidatePath, allowedSessionIds, options);
    await runSQLite(candidatePath, `
      PRAGMA foreign_keys = OFF;
      BEGIN IMMEDIATE;
      ${statements.join('\n')}
      COMMIT;
      PRAGMA foreign_keys = ON;
    `, options);
    await validateCandidate(candidatePath, allowedSessionIds, options);
    const handle = fs.openSync(candidatePath, 'r+');
    try {
      fs.fsyncSync(handle);
    } finally {
      fs.closeSync(handle);
    }
    fs.linkSync(candidatePath, destinationDbPath);
  } finally {
    removeDatabaseArtifacts(candidatePath);
  }
}

async function mergeStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds = null, options = {}) {
  if (!fs.existsSync(sourceDbPath)) return 'SQLite 索引未合并：快照数据库缺失。';
  if (allowedSessionIds && allowedSessionIds.size === 0) {
    return 'SQLite 索引未合并：快照中没有可恢复的会话文件。';
  }

  if (!fs.existsSync(destinationDbPath)) {
    try {
      await publishSanitizedCandidate(sourceDbPath, destinationDbPath, allowedSessionIds, options);
      return 'SQLite 索引已恢复，并清理账号绑定表。';
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    if (!fs.existsSync(destinationDbPath)) {
      throw new Error('Codex 并发创建的 SQLite 数据库在合并前消失，已停止恢复。');
    }
  }

  await preflightMergeStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds, options);
  const plan = await mergePlan(sourceDbPath, destinationDbPath, allowedSessionIds, options);
  const pathUpdates = await rolloutPathStatements(
    destinationDbPath,
    options.rolloutPathUpdates,
    options,
  );
  await runSQLite(destinationDbPath, `
    PRAGMA foreign_keys = OFF;
    ATTACH DATABASE ${quoteLiteral(sourceDbPath)} AS snapshot;
    BEGIN IMMEDIATE;
    ${plan.map((item) => item.deleteSelected).join('\n')}
    ${plan.map((item) => item.insert).join('\n')}
    ${pathUpdates.join('\n')}
    COMMIT;
    DETACH DATABASE snapshot;
    PRAGMA foreign_keys = ON;
  `, options);
  return 'SQLite 索引已合并。';
}

async function replaceStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds, options = {}) {
  if (!fs.existsSync(sourceDbPath)) return 'SQLite 索引未恢复：快照数据库缺失。';
  if (!fs.existsSync(destinationDbPath)) {
    try {
      await publishSanitizedCandidate(sourceDbPath, destinationDbPath, allowedSessionIds, options);
      return 'SQLite 索引已完整恢复。';
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (!fs.existsSync(destinationDbPath)) {
        throw new Error('Codex 并发创建的 SQLite 数据库在合并前消失，已停止恢复。');
      }
      // Codex won the no-replace publication race. Merge into its newly-created
      // live database so its committed rows are never cleared by this restore.
      return mergeStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds, options);
    }
  }

  const plan = await mergePlan(sourceDbPath, destinationDbPath, allowedSessionIds, options);
  const destinationConversationTables = [];
  for (const table of conversationStateTables) {
    if ((await tableColumns(destinationDbPath, table, options)).length) {
      destinationConversationTables.push(table);
    }
  }
  const accountTables = [];
  for (const table of ['device_key_bindings', 'remote_control_enrollments']) {
    if ((await tableColumns(destinationDbPath, table, options)).length) accountTables.push(table);
  }

  const pathUpdates = await rolloutPathStatements(
    destinationDbPath,
    options.rolloutPathUpdates,
    options,
  );
  await runSQLite(destinationDbPath, `
    PRAGMA foreign_keys = OFF;
    ATTACH DATABASE ${quoteLiteral(sourceDbPath)} AS snapshot;
    BEGIN IMMEDIATE;
    ${destinationConversationTables.map((table) => `DELETE FROM ${quoteIdent(table)};`).join('\n')}
    ${plan.map((item) => item.insert).join('\n')}
    ${pathUpdates.join('\n')}
    ${accountTables.map((table) => `DELETE FROM ${quoteIdent(table)};`).join('\n')}
    COMMIT;
    DETACH DATABASE snapshot;
    PRAGMA foreign_keys = ON;
  `, options);
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
  deleteSingleSessionStateDb,
  ensureRecoveredThreadsInStateDatabase,
  mergeStateDatabase,
  mergeSingleSessionStateDb,
  preflightMergeStateDatabase,
  repairStateDatabaseRolloutPaths,
  replaceStateDatabase,
  runSQLite,
};

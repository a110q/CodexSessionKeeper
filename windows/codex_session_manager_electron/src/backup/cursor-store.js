const fs = require('node:fs/promises');
const path = require('node:path');

const { runSQLite } = require('./live-state-database');

const CREATE_CURSOR_TABLE = `
  CREATE TABLE IF NOT EXISTS backup_cursors (
    source_path TEXT NOT NULL PRIMARY KEY,
    session_id TEXT NOT NULL,
    backup_path TEXT NOT NULL,
    last_byte_offset INTEGER NOT NULL,
    last_source_size INTEGER NOT NULL,
    last_source_modified_at REAL NOT NULL,
    line_count INTEGER NOT NULL,
    pending_partial_line TEXT NOT NULL,
    status TEXT NOT NULL,
    last_error TEXT,
    source_file_identity TEXT,
    updated_at REAL NOT NULL
  );
`;

const CURSOR_COLUMNS = `
  session_id AS sessionId,
  source_path AS sourcePath,
  source_file_identity AS sourceFileIdentity,
  backup_path AS backupPath,
  last_byte_offset AS lastByteOffset,
  last_source_size AS lastSourceSize,
  last_source_modified_at AS lastSourceModifiedAt,
  line_count AS lineCount,
  pending_partial_line AS pendingPartialLine,
  status,
  last_error AS lastError,
  updated_at AS updatedAt
`;

const PERSISTED_FIELDS = [
  ['source_path', 'sourcePath', 'text'],
  ['session_id', 'sessionId', 'text'],
  ['backup_path', 'backupPath', 'text'],
  ['last_byte_offset', 'lastByteOffset', 'number'],
  ['last_source_size', 'lastSourceSize', 'number'],
  ['last_source_modified_at', 'lastSourceModifiedAt', 'number'],
  ['line_count', 'lineCount', 'number'],
  ['pending_partial_line', 'pendingPartialLine', 'partial'],
  ['status', 'status', 'text'],
  ['last_error', 'lastError', 'nullableText'],
  ['source_file_identity', 'sourceFileIdentity', 'nullableText'],
  ['updated_at', 'updatedAt', 'number'],
];

function encodePendingPartialLine(value) {
  if (Buffer.isBuffer(value)) {
    return value.toString('base64');
  }
  return Buffer.from(String(value ?? ''), 'utf8').toString('base64');
}

function decodePendingPartialLine(value) {
  return Buffer.from(String(value ?? ''), 'base64').toString('utf8');
}

function safeInteger(value, field) {
  const number = Number(value ?? 0);
  if (!Number.isSafeInteger(number)) {
    throw new TypeError(`${field} must be a safe integer.`);
  }
  return number;
}

function finiteNumber(value, field) {
  const number = Number(value ?? 0);
  if (!Number.isFinite(number)) {
    throw new TypeError(`${field} must be a finite number.`);
  }
  return number;
}

function normalizeCursor(cursor) {
  return {
    sessionId: String(cursor.sessionId ?? ''),
    sourcePath: String(cursor.sourcePath ?? ''),
    sourceFileIdentity: cursor.sourceFileIdentity == null
      ? null
      : String(cursor.sourceFileIdentity),
    backupPath: String(cursor.backupPath ?? ''),
    lastByteOffset: safeInteger(cursor.lastByteOffset, 'lastByteOffset'),
    lastSourceSize: safeInteger(cursor.lastSourceSize, 'lastSourceSize'),
    lastSourceModifiedAt: finiteNumber(cursor.lastSourceModifiedAt, 'lastSourceModifiedAt'),
    lineCount: safeInteger(cursor.lineCount, 'lineCount'),
    pendingPartialLine: Buffer.isBuffer(cursor.pendingPartialLine)
      ? cursor.pendingPartialLine.toString('utf8')
      : String(cursor.pendingPartialLine ?? ''),
    status: String(cursor.status ?? ''),
    lastError: cursor.lastError == null ? null : String(cursor.lastError),
    updatedAt: finiteNumber(cursor.updatedAt, 'updatedAt'),
  };
}

function cursorFromRow(row) {
  return normalizeCursor({
    ...row,
    pendingPartialLine: decodePendingPartialLine(row.pendingPartialLine),
  });
}

function cloneCursor(cursor) {
  return { ...cursor };
}

function sqlText(value) {
  const hex = Buffer.from(String(value), 'utf8').toString('hex');
  return `CAST(X'${hex}' AS TEXT)`;
}

function sqlNullableText(value) {
  return value == null ? 'NULL' : sqlText(value);
}

function cursorSqlValue(cursor, field, kind) {
  const value = cursor[field];
  if (kind === 'text') return sqlText(value);
  if (kind === 'nullableText') return sqlNullableText(value);
  if (kind === 'partial') return sqlText(encodePendingPartialLine(value));
  return String(value);
}

function cursorEquality(cursor) {
  return PERSISTED_FIELDS.map(([column, field, kind]) => {
    const value = cursorSqlValue(cursor, field, kind);
    if (kind === 'nullableText' && value === 'NULL') return `${column} IS NULL`;
    return `${column} = ${value}`;
  }).join('\n      AND ');
}

function cursorExistsCondition(sourcePath, baseline) {
  const sourceLiteral = sqlText(sourcePath);
  if (!baseline) {
    return `NOT EXISTS (
      SELECT 1 FROM backup_cursors WHERE source_path = ${sourceLiteral}
    )`;
  }
  return `EXISTS (
    SELECT 1
    FROM backup_cursors
    WHERE source_path = ${sourceLiteral}
      AND ${cursorEquality(baseline)}
  )`;
}

function upsertStatement(cursor) {
  const values = PERSISTED_FIELDS.map(([, field, kind]) => cursorSqlValue(cursor, field, kind));
  return `
    INSERT INTO backup_cursors (
      ${PERSISTED_FIELDS.map(([column]) => column).join(',\n      ')}
    ) VALUES (
      ${values.join(',\n      ')}
    )
    ON CONFLICT(source_path) DO UPDATE SET
      session_id = excluded.session_id,
      backup_path = excluded.backup_path,
      last_byte_offset = excluded.last_byte_offset,
      last_source_size = excluded.last_source_size,
      last_source_modified_at = excluded.last_source_modified_at,
      line_count = excluded.line_count,
      pending_partial_line = excluded.pending_partial_line,
      status = excluded.status,
      last_error = excluded.last_error,
      source_file_identity = excluded.source_file_identity,
      updated_at = excluded.updated_at;
  `;
}

function cursorConflict(cause) {
  const error = new Error('Cursor changed in another process; reload before writing.');
  error.code = 'CURSOR_CONFLICT';
  error.cause = cause;
  return error;
}

class CursorStore {
  constructor({ paths, sqlitePath, busyTimeoutMs = 5000, sqliteRunner = runSQLite } = {}) {
    if (!paths || !paths.cursorDatabasePath) {
      throw new Error('CursorStore requires paths.cursorDatabasePath.');
    }
    if (!Number.isSafeInteger(busyTimeoutMs) || busyTimeoutMs < 0) {
      throw new TypeError('busyTimeoutMs must be a non-negative safe integer.');
    }
    if (typeof sqliteRunner !== 'function') {
      throw new TypeError('sqliteRunner must be a function.');
    }

    this.paths = paths;
    this.sqlitePath = sqlitePath;
    this.busyTimeoutMs = busyTimeoutMs;
    this.sqliteRunner = sqliteRunner;
    this.cursors = null;
  }

  runSQLite(sql, options = {}) {
    return this.sqliteRunner(this.paths.cursorDatabasePath, sql, {
      sqlitePath: this.sqlitePath,
      busyTimeoutMs: this.busyTimeoutMs,
      ...options,
    });
  }

  async open() {
    if (this.cursors) {
      return this;
    }

    await fs.mkdir(path.dirname(this.paths.cursorDatabasePath), { recursive: true });
    await this.runSQLite(CREATE_CURSOR_TABLE);

    if (!await this.hasSourceFileIdentityColumn()) {
      try {
        await this.runSQLite('ALTER TABLE backup_cursors ADD COLUMN source_file_identity TEXT;');
      } catch (error) {
        if (!await this.hasSourceFileIdentityColumn()) throw error;
      }
    }

    const output = String(await this.runSQLite(`
      SELECT ${CURSOR_COLUMNS}
      FROM backup_cursors;
    `, { json: true })).trim();
    const rows = output ? JSON.parse(output) : [];
    const cursors = new Map();
    for (const row of rows) {
      const cursor = cursorFromRow(row);
      cursors.set(cursor.sourcePath, cursor);
    }
    this.cursors = cursors;
    return this;
  }

  async hasSourceFileIdentityColumn() {
    const output = await this.runSQLite(`
      SELECT COUNT(*)
      FROM pragma_table_info('backup_cursors')
      WHERE name = 'source_file_identity';
    `);
    return Number(String(output).trim()) > 0;
  }

  async get(sourcePath) {
    this.ensureOpen();
    const cursor = this.cursors.get(String(sourcePath));
    return cursor ? cloneCursor(cursor) : null;
  }

  all() {
    this.ensureOpen();
    return new Map([...this.cursors].map(([sourcePath, cursor]) => [sourcePath, cloneCursor(cursor)]));
  }

  async upsert(cursor) {
    return this.upsertMany([cursor]);
  }

  async upsertMany(cursors, { deletingSourcePaths = [] } = {}) {
    this.ensureOpen();

    const batch = Array.from(cursors, normalizeCursor);
    const upsertedSourcePaths = new Set(batch.map((cursor) => cursor.sourcePath));
    const deletions = [...new Set(Array.from(deletingSourcePaths, String))]
      .filter((sourcePath) => !upsertedSourcePaths.has(sourcePath));
    if (batch.length === 0 && deletions.length === 0) return;

    const affectedSourcePaths = [...new Set([
      ...deletions,
      ...batch.map((cursor) => cursor.sourcePath),
    ])];
    const preconditions = affectedSourcePaths.map((sourcePath) => (
      cursorExistsCondition(sourcePath, this.cursors.get(sourcePath))
    ));
    const statements = [
      'BEGIN IMMEDIATE;',
      `CREATE TEMP TABLE cursor_cas_guard (
        ok INTEGER CONSTRAINT cursor_conflict CHECK (ok = 1)
      );`,
      `INSERT INTO cursor_cas_guard (ok)
       SELECT CASE WHEN
         (${preconditions.join(')\n         AND (')})
       THEN 1 ELSE 0 END;`,
      ...deletions.map((sourcePath) => (
        `DELETE FROM backup_cursors WHERE source_path = ${sqlText(sourcePath)};`
      )),
      ...batch.map(upsertStatement),
      'COMMIT;',
    ];

    try {
      await this.runSQLite(statements.join('\n'));
    } catch (error) {
      if (/cursor_conflict/i.test(String(error && error.message))) {
        throw cursorConflict(error);
      }
      throw error;
    }

    for (const sourcePath of deletions) this.cursors.delete(sourcePath);
    for (const cursor of batch) this.cursors.set(cursor.sourcePath, cursor);
  }

  async close() {
    this.cursors?.clear();
    this.cursors = null;
  }

  ensureOpen() {
    if (!this.cursors) {
      throw new Error('CursorStore is not open.');
    }
  }
}

module.exports = {
  CursorStore,
};

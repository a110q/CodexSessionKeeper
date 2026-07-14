const fs = require('node:fs/promises');
const path = require('node:path');
const { replaceFileDurably } = require('./durable-write');

let sqlModulePromise;

function defaultLocateFile(file) {
  if (file === 'sql-wasm.wasm') {
    return require.resolve('sql.js/dist/sql-wasm.wasm');
  }

  return file;
}

async function loadSqlModule(locateFile) {
  if (!sqlModulePromise || locateFile) {
    const initSqlJs = require('sql.js');
    const promise = initSqlJs({ locateFile: locateFile || defaultLocateFile });
    if (locateFile) {
      return promise;
    }
    sqlModulePromise = promise;
  }

  return sqlModulePromise;
}

function encodePendingPartialLine(value) {
  if (Buffer.isBuffer(value)) {
    return value.toString('base64');
  }

  return Buffer.from(String(value ?? ''), 'utf8').toString('base64');
}

function decodePendingPartialLine(value) {
  return Buffer.from(String(value ?? ''), 'base64').toString('utf8');
}

function numberValue(value) {
  return Number(value ?? 0);
}

const CURSOR_COLUMNS = `
  session_id AS sessionId,
  source_path AS sourcePath,
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

const UPSERT_CURSOR = `
  INSERT INTO backup_cursors (
    source_path,
    session_id,
    backup_path,
    last_byte_offset,
    last_source_size,
    last_source_modified_at,
    line_count,
    pending_partial_line,
    status,
    last_error,
    updated_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    updated_at = excluded.updated_at;
`;

function cursorFromRow(row) {
  return {
    sessionId: row.sessionId,
    sourcePath: row.sourcePath,
    backupPath: row.backupPath,
    lastByteOffset: numberValue(row.lastByteOffset),
    lastSourceSize: numberValue(row.lastSourceSize),
    lastSourceModifiedAt: numberValue(row.lastSourceModifiedAt),
    lineCount: numberValue(row.lineCount),
    pendingPartialLine: decodePendingPartialLine(row.pendingPartialLine),
    status: row.status,
    lastError: row.lastError ?? null,
    updatedAt: numberValue(row.updatedAt),
  };
}

function cursorValues(cursor) {
  return [
    cursor.sourcePath,
    cursor.sessionId,
    cursor.backupPath,
    Number(cursor.lastByteOffset ?? 0),
    Number(cursor.lastSourceSize ?? 0),
    Number(cursor.lastSourceModifiedAt ?? 0),
    Number(cursor.lineCount ?? 0),
    encodePendingPartialLine(cursor.pendingPartialLine),
    cursor.status,
    cursor.lastError ?? null,
    Number(cursor.updatedAt ?? 0),
  ];
}

class CursorStore {
  constructor({ paths, SQL, locateFile } = {}) {
    if (!paths || !paths.cursorDatabasePath) {
      throw new Error('CursorStore requires paths.cursorDatabasePath.');
    }

    this.paths = paths;
    this.SQL = SQL;
    this.locateFile = locateFile;
    this.db = null;
  }

  async open() {
    if (this.db) {
      return this;
    }

    const SQL = this.SQL || await loadSqlModule(this.locateFile);
    await fs.mkdir(path.dirname(this.paths.cursorDatabasePath), { recursive: true });

    let data = null;
    try {
      data = await fs.readFile(this.paths.cursorDatabasePath);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }

    this.db = data ? new SQL.Database(data) : new SQL.Database();
    this.db.run(`
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
        updated_at REAL NOT NULL
      );
    `);
    if (!data) {
      await this.flush();
    }

    return this;
  }

  async get(sourcePath) {
    this.ensureOpen();

    const statement = this.db.prepare(`
      SELECT
        ${CURSOR_COLUMNS}
      FROM backup_cursors
      WHERE source_path = ?
      LIMIT 1;
    `);

    try {
      statement.bind([sourcePath]);
      if (!statement.step()) {
        return null;
      }

      return cursorFromRow(statement.getAsObject());
    } finally {
      statement.free();
    }
  }

  all() {
    this.ensureOpen();

    const statement = this.db.prepare(`
      SELECT
        ${CURSOR_COLUMNS}
      FROM backup_cursors;
    `);
    const cursors = new Map();

    try {
      while (statement.step()) {
        const cursor = cursorFromRow(statement.getAsObject());
        cursors.set(cursor.sourcePath, cursor);
      }
      return cursors;
    } finally {
      statement.free();
    }
  }

  async upsert(cursor) {
    return this.upsertMany([cursor]);
  }

  async upsertMany(cursors) {
    this.ensureOpen();

    const batch = Array.from(cursors);
    if (batch.length === 0) {
      return;
    }

    const statement = this.db.prepare(UPSERT_CURSOR);
    let transactionStarted = false;

    try {
      this.db.run('BEGIN IMMEDIATE;');
      transactionStarted = true;
      for (const cursor of batch) {
        statement.bind(cursorValues(cursor));
        statement.step();
        statement.reset();
      }
      this.db.run('COMMIT;');
      transactionStarted = false;
    } catch (error) {
      if (transactionStarted) {
        try {
          this.db.run('ROLLBACK;');
        } catch {
          // Preserve the original SQL failure.
        }
      }
      throw error;
    } finally {
      statement.free();
    }

    await this.flush();
  }

  async flush() {
    this.ensureOpen();

    await fs.mkdir(path.dirname(this.paths.cursorDatabasePath), { recursive: true });
    await replaceFileDurably(this.paths.cursorDatabasePath, Buffer.from(this.db.export()));
  }

  async close() {
    if (!this.db) {
      return;
    }

    this.db.close();
    this.db = null;
  }

  ensureOpen() {
    if (!this.db) {
      throw new Error('CursorStore is not open.');
    }
  }
}

module.exports = {
  CursorStore,
};

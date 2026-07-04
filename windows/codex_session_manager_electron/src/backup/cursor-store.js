const fs = require('node:fs/promises');
const path = require('node:path');

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
    await this.flush();

    return this;
  }

  async get(sourcePath) {
    this.ensureOpen();

    const statement = this.db.prepare(`
      SELECT
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
      FROM backup_cursors
      WHERE source_path = ?
      LIMIT 1;
    `);

    try {
      statement.bind([sourcePath]);
      if (!statement.step()) {
        return null;
      }

      const row = statement.getAsObject();
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
    } finally {
      statement.free();
    }
  }

  async upsert(cursor) {
    this.ensureOpen();

    this.db.run(`
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
    `, [
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
    ]);

    await this.flush();
  }

  async flush() {
    this.ensureOpen();

    await fs.mkdir(path.dirname(this.paths.cursorDatabasePath), { recursive: true });
    const tempPath = `${this.paths.cursorDatabasePath}.tmp-${process.pid}-${Date.now()}`;

    try {
      await fs.writeFile(tempPath, Buffer.from(this.db.export()));
      await fs.rename(tempPath, this.paths.cursorDatabasePath);
    } catch (error) {
      try {
        await fs.rm(tempPath, { force: true });
      } catch {
        // Best effort cleanup after a failed temp write.
      }
      throw error;
    }
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

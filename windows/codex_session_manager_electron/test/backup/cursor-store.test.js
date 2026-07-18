const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const initSqlJs = require('sql.js');

const { CursorStore } = require('../../src/backup/cursor-store');
const { runSQLite } = require('../../src/backup/live-state-database');

const SQLITE_PATH = '/usr/bin/sqlite3';

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'cursor-store-'));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  return {
    root,
    paths: { cursorDatabasePath: path.join(root, 'state', 'cursors.sqlite') },
  };
}

function makeCursor(root, name, overrides = {}) {
  return {
    sessionId: `session-${name}`,
    sourcePath: path.join(root, 'sessions', `${name}.jsonl`),
    sourceFileIdentity: null,
    backupPath: path.join('sessions', `${name}.jsonl`),
    lastByteOffset: 10,
    lastSourceSize: 12,
    lastSourceModifiedAt: 1770000000.25,
    lineCount: 1,
    pendingPartialLine: '',
    status: 'active',
    lastError: null,
    blockedLineLimitBytes: null,
    updatedAt: 1770000001.5,
    ...overrides,
  };
}

function runSql(databasePath, sql) {
  execFileSync(SQLITE_PATH, [databasePath], {
    input: `.bail on\n.timeout 5000\n${sql.trim()}\n`,
    encoding: 'utf8',
  });
}

function queryRows(databasePath, sql) {
  const output = execFileSync(SQLITE_PATH, ['-json', databasePath, sql], { encoding: 'utf8' }).trim();
  return output ? JSON.parse(output) : [];
}

async function writeLegacySqlJsDatabase(databasePath, cursorOrCursors) {
  const cursors = Array.isArray(cursorOrCursors) ? cursorOrCursors : [cursorOrCursors];
  const SQL = await initSqlJs();
  const database = new SQL.Database();
  try {
    database.run(`
      CREATE TABLE backup_cursors (
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
    for (const cursor of cursors) {
      database.run(`
        INSERT INTO backup_cursors (
          source_path, session_id, backup_path, last_byte_offset, last_source_size,
          last_source_modified_at, line_count, pending_partial_line, status, last_error, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      `, [
        cursor.sourcePath,
        cursor.sessionId,
        cursor.backupPath,
        cursor.lastByteOffset,
        cursor.lastSourceSize,
        cursor.lastSourceModifiedAt,
        cursor.lineCount,
        Buffer.from(cursor.pendingPartialLine, 'utf8').toString('base64'),
        cursor.status,
        cursor.lastError,
        cursor.updatedAt,
      ]);
    }
    await fs.mkdir(path.dirname(databasePath), { recursive: true });
    await fs.writeFile(databasePath, Buffer.from(database.export()));
  } finally {
    database.close();
  }
}

function recordingRunner(calls) {
  return async (databasePath, sql, options) => {
    calls.push({ databasePath, sql, options: { ...options } });
    return runSQLite(databasePath, sql, options);
  };
}

function acquireWriteLock(databasePath) {
  return new Promise((resolve, reject) => {
    const child = spawn(SQLITE_PATH, [databasePath], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let acquired = false;
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (!acquired && stdout.includes('LOCKED')) {
        acquired = true;
        resolve({
          release: () => new Promise((releaseResolve, releaseReject) => {
            child.once('close', (status) => {
              if (status === 0) releaseResolve();
              else releaseReject(new Error(stderr || `sqlite3 exited ${status}`));
            });
            child.stdin.end('COMMIT;\n');
          }),
        });
      }
    });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (status) => {
      if (!acquired) reject(new Error(stderr || `sqlite3 exited ${status} before acquiring lock`));
    });
    child.stdin.write(".bail on\nBEGIN IMMEDIATE;\nSELECT 'LOCKED';\n");
  });
}

function spawnCursorWriter(databasePath, cursor) {
  const script = `
    const { CursorStore } = require(process.env.CURSOR_STORE_MODULE);
    (async () => {
      const store = new CursorStore({
        paths: { cursorDatabasePath: process.env.CURSOR_DATABASE_PATH },
        sqlitePath: process.env.SQLITE_PATH,
      });
      await store.open();
      process.stdout.write('READY\\n');
      await new Promise((resolve) => process.stdin.once('data', resolve));
      await store.upsert(JSON.parse(process.env.CURSOR_JSON));
      await store.close();
    })().catch((error) => {
      process.stderr.write(String(error && (error.stack || error)));
      process.exitCode = 1;
    });
  `;
  const child = spawn(process.execPath, ['-e', script], {
    env: {
      ...process.env,
      CURSOR_DATABASE_PATH: databasePath,
      CURSOR_JSON: JSON.stringify(cursor),
      CURSOR_STORE_MODULE: require.resolve('../../src/backup/cursor-store'),
      SQLITE_PATH,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolve, reject) => {
    readyResolve = resolve;
    readyReject = reject;
  });
  const completed = new Promise((resolve, reject) => {
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (stdout.includes('READY\n')) readyResolve();
    });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => {
      readyReject(error);
      reject(error);
    });
    child.on('close', (status) => {
      if (!stdout.includes('READY\n')) readyReject(new Error(stderr || `writer exited ${status} before ready`));
      if (status === 0) resolve();
      else reject(new Error(stderr || `writer exited ${status}`));
    });
  });
  return {
    ready,
    go() { child.stdin.end('GO\n'); },
    completed,
  };
}

test('open migrates legacy cursor line-limit state with an exact selective backfill', async (t) => {
  const { root, paths } = await makeFixture(t);
  const legacy = makeCursor(root, 'legacy', {
    sourceFileIdentity: undefined,
    blockedLineLimitBytes: undefined,
    pendingPartialLine: 'legacy partial',
    lastError: `Session JSONL line exceeds maximum JSONL line size of 33554432 bytes at offset 10: ${path.join(root, 'sessions', 'legacy.jsonl')}`,
  });
  const unrelated = makeCursor(root, 'unrelated', {
    sourceFileIdentity: undefined,
    blockedLineLimitBytes: undefined,
    lastError: 'NAS volume unavailable',
  });
  const caseVariant = makeCursor(root, 'case-variant', {
    sourceFileIdentity: undefined,
    blockedLineLimitBytes: undefined,
    lastError: `session JSONL line exceeds maximum JSONL line size of 33554432 bytes at offset 10: ${path.join(root, 'sessions', 'case-variant.jsonl')}`,
  });
  await writeLegacySqlJsDatabase(paths.cursorDatabasePath, [legacy, unrelated, caseVariant]);
  const store = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  t.after(async () => store.close());

  await store.open();

  assert.equal((await store.get(legacy.sourcePath)).blockedLineLimitBytes, 33_554_432);
  assert.equal((await store.get(unrelated.sourcePath)).blockedLineLimitBytes, null);
  assert.equal((await store.get(caseVariant.sourcePath)).blockedLineLimitBytes, null);
  const columns = queryRows(paths.cursorDatabasePath, 'PRAGMA table_info(backup_cursors);');
  assert.ok(columns.some((column) => column.name === 'source_file_identity'));
  assert.ok(columns.some((column) => column.name === 'blocked_line_limit_bytes'));
});

test('concurrent opens safely migrate the old schema', async (t) => {
  const { root, paths } = await makeFixture(t);
  const legacy = makeCursor(root, 'concurrent-legacy', {
    sourceFileIdentity: undefined,
    blockedLineLimitBytes: undefined,
  });
  await writeLegacySqlJsDatabase(paths.cursorDatabasePath, legacy);
  const stores = [
    new CursorStore({ paths, sqlitePath: SQLITE_PATH }),
    new CursorStore({ paths, sqlitePath: SQLITE_PATH }),
  ];
  t.after(async () => Promise.all(stores.map((store) => store.close())));

  await Promise.all(stores.map((store) => store.open()));

  assert.equal((await stores[0].get(legacy.sourcePath)).sourceFileIdentity, null);
  assert.equal((await stores[1].get(legacy.sourcePath)).sourceFileIdentity, null);
  assert.equal((await stores[0].get(legacy.sourcePath)).blockedLineLimitBytes, null);
});

test('round trips Chinese, quotes, nullable identity, and a NUL partial line', async (t) => {
  const { root, paths } = await makeFixture(t);
  const store = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  await store.open();
  const cursor = makeCursor(root, "中文-'会话", {
    sessionId: "中文 session 'quoted'",
    sourceFileIdentity: "卷标'文件-身份-中文",
    backupPath: "sessions/中文-'backup'.jsonl",
    pendingPartialLine: "前半段\0后半段 'quoted' 🚀",
    status: "active-'中文",
    lastError: "错误'); DROP TABLE backup_cursors; -- 中文",
    blockedLineLimitBytes: 67_108_864,
  });

  await store.upsert(cursor);
  await store.close();
  const reopened = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  t.after(async () => reopened.close());
  await reopened.open();

  assert.deepEqual(await reopened.get(cursor.sourcePath), cursor);
});

test('open loads the cursor Map with one JSON SELECT', async (t) => {
  const { paths } = await makeFixture(t);
  const calls = [];
  const store = new CursorStore({
    paths,
    sqlitePath: SQLITE_PATH,
    sqliteRunner: recordingRunner(calls),
  });
  t.after(async () => store.close());

  await store.open();

  const cursorSelects = calls.filter(({ sql, options }) => (
    options.json === true && /FROM\s+backup_cursors/i.test(sql)
  ));
  assert.equal(cursorSelects.length, 1);
});

test('empty batches run no write transaction', async (t) => {
  const { paths } = await makeFixture(t);
  const calls = [];
  const store = new CursorStore({
    paths,
    sqlitePath: SQLITE_PATH,
    sqliteRunner: recordingRunner(calls),
  });
  t.after(async () => store.close());
  await store.open();
  calls.length = 0;

  await store.upsertMany([]);

  assert.equal(calls.filter(({ sql }) => /^\s*BEGIN IMMEDIATE;/i.test(sql)).length, 0);
});

test('a changed batch uses one native transaction and the default busy timeout', async (t) => {
  const { root, paths } = await makeFixture(t);
  const calls = [];
  const store = new CursorStore({
    paths,
    sqlitePath: SQLITE_PATH,
    sqliteRunner: recordingRunner(calls),
  });
  t.after(async () => store.close());
  await store.open();
  calls.length = 0;

  await store.upsertMany([makeCursor(root, 'one'), makeCursor(root, 'two')]);

  const transactions = calls.filter(({ sql }) => /^\s*BEGIN IMMEDIATE;/i.test(sql));
  assert.equal(transactions.length, 1);
  assert.equal(transactions[0].options.busyTimeoutMs, 5000);
  assert.equal(store.all().size, 2);
});

test('a SQL failure rolls back the whole native batch', async (t) => {
  const { root, paths } = await makeFixture(t);
  const store = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  t.after(async () => store.close());
  await store.open();
  runSql(paths.cursorDatabasePath, `
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
    CREATE TRIGGER reject_bad_cursor
    BEFORE INSERT ON backup_cursors
    WHEN NEW.source_path LIKE '%bad.jsonl'
    BEGIN
      SELECT RAISE(ABORT, 'injected SQL failure');
    END;
  `);

  await assert.rejects(
    store.upsertMany([makeCursor(root, 'good'), makeCursor(root, 'bad')]),
    /injected SQL failure/,
  );

  assert.deepEqual(queryRows(paths.cursorDatabasePath, 'SELECT source_path FROM backup_cursors;'), []);
  assert.equal(store.all().size, 0);
});

test('two stale Node processes writing different rows preserve both', async (t) => {
  const { root, paths } = await makeFixture(t);
  const initializer = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  await initializer.open();
  await initializer.close();
  const writers = [
    spawnCursorWriter(paths.cursorDatabasePath, makeCursor(root, 'child-one')),
    spawnCursorWriter(paths.cursorDatabasePath, makeCursor(root, 'child-two')),
  ];

  await Promise.all(writers.map((writer) => writer.ready));
  writers.forEach((writer) => writer.go());
  await Promise.all(writers.map((writer) => writer.completed));

  assert.deepEqual(
    queryRows(paths.cursorDatabasePath, 'SELECT session_id AS sessionId FROM backup_cursors ORDER BY session_id;'),
    [{ sessionId: 'session-child-one' }, { sessionId: 'session-child-two' }],
  );
});

test('a stale writer on the same row gets CURSOR_CONFLICT without overwriting', async (t) => {
  const { root, paths } = await makeFixture(t);
  const original = makeCursor(root, 'same-row');
  const seed = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  await seed.open();
  await seed.upsert(original);
  await seed.close();
  const first = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  const stale = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  t.after(async () => Promise.all([first.close(), stale.close()]));
  await Promise.all([first.open(), stale.open()]);
  const winner = {
    ...original,
    sourceFileIdentity: 'winner-identity',
    blockedLineLimitBytes: 67_108_864,
  };
  const loser = { ...original, lastByteOffset: 30, updatedAt: 1770000003.5 };

  await first.upsert(winner);
  await assert.rejects(stale.upsert(loser), (error) => error.code === 'CURSOR_CONFLICT');

  assert.deepEqual(await first.get(original.sourcePath), winner);
  assert.deepEqual(await stale.get(original.sourcePath), original);
  assert.equal(
    queryRows(paths.cursorDatabasePath, 'SELECT source_file_identity AS value FROM backup_cursors;')[0].value,
    winner.sourceFileIdentity,
  );
  assert.equal(
    queryRows(paths.cursorDatabasePath, 'SELECT blocked_line_limit_bytes AS value FROM backup_cursors;')[0].value,
    winner.blockedLineLimitBytes,
  );
});

test('a stale delete conflicts with a concurrent update and deletes nothing', async (t) => {
  const { root, paths } = await makeFixture(t);
  const original = makeCursor(root, 'delete-update');
  const seed = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  await seed.open();
  await seed.upsert(original);
  await seed.close();
  const updater = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  const deleter = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  t.after(async () => Promise.all([updater.close(), deleter.close()]));
  await Promise.all([updater.open(), deleter.open()]);
  const winner = { ...original, lastError: 'winner' };

  await updater.upsert(winner);
  await assert.rejects(
    deleter.upsertMany([], { deletingSourcePaths: [original.sourcePath] }),
    (error) => error.code === 'CURSOR_CONFLICT',
  );

  assert.deepEqual(await updater.get(original.sourcePath), winner);
  assert.equal(queryRows(paths.cursorDatabasePath, 'SELECT COUNT(*) AS count FROM backup_cursors;')[0].count, 1);
  assert.equal(queryRows(paths.cursorDatabasePath, 'SELECT last_error AS value FROM backup_cursors;')[0].value, 'winner');
});

test('a real SQLite write lock times out without partial writes', async (t) => {
  const { root, paths } = await makeFixture(t);
  const store = new CursorStore({
    paths,
    sqlitePath: SQLITE_PATH,
    busyTimeoutMs: 25,
  });
  t.after(async () => store.close());
  await store.open();
  const lock = await acquireWriteLock(paths.cursorDatabasePath);
  let released = false;
  t.after(async () => {
    if (!released) await lock.release();
  });

  await assert.rejects(store.upsert(makeCursor(root, 'locked')), (error) => error.code === 'SQLITE_BUSY');
  await lock.release();
  released = true;

  assert.deepEqual(queryRows(paths.cursorDatabasePath, 'SELECT source_path FROM backup_cursors;'), []);
  assert.equal(store.all().size, 0);
});

test('unsafe integers and non-finite numbers are rejected before a transaction', async (t) => {
  const { root, paths } = await makeFixture(t);
  const calls = [];
  const store = new CursorStore({
    paths,
    sqlitePath: SQLITE_PATH,
    sqliteRunner: recordingRunner(calls),
  });
  t.after(async () => store.close());
  await store.open();
  calls.length = 0;

  await assert.rejects(
    store.upsert(makeCursor(root, 'unsafe', { lastByteOffset: Number.MAX_SAFE_INTEGER + 1 })),
    /safe integer/i,
  );
  await assert.rejects(
    store.upsert(makeCursor(root, 'infinite', { updatedAt: Number.POSITIVE_INFINITY })),
    /finite/i,
  );

  assert.equal(calls.filter(({ sql }) => /^\s*BEGIN IMMEDIATE;/i.test(sql)).length, 0);
});

test('close clears the in-memory cursor Map', async (t) => {
  const { paths } = await makeFixture(t);
  const store = new CursorStore({ paths, sqlitePath: SQLITE_PATH });
  await store.open();

  await store.close();

  assert.equal(store.cursors, null);
  assert.throws(() => store.all(), /not open/i);
});

test('cursor-store source has no sql.js whole-file export path', async () => {
  const source = await fs.readFile(require.resolve('../../src/backup/cursor-store'), 'utf8');

  assert.doesNotMatch(source, /sql\.js/);
  assert.doesNotMatch(source, /db\.export/);
  assert.doesNotMatch(source, /replaceFileDurably/);
});

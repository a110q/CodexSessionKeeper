const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  deleteSingleSessionStateDb,
  ensureRecoveredThreadsInStateDatabase,
  mergeStateDatabase,
  mergeSingleSessionStateDb,
  repairStateDatabaseRolloutPaths,
  replaceStateDatabase,
  resolveSqlitePath,
} = require('../../src/backup/live-state-database');

const sqlitePath = resolveSqlitePath();

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'live-state-database-'));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  return {
    destinationDbPath: path.join(root, 'live.sqlite'),
    sourceDbPath: path.join(root, 'snapshot.sqlite'),
  };
}

function runSql(databasePath, sql) {
  execFileSync(sqlitePath, [databasePath], { input: `.bail on\n${sql}\n`, encoding: 'utf8' });
}

function queryRows(databasePath, sql) {
  const output = execFileSync(sqlitePath, ['-json', databasePath, sql], { encoding: 'utf8' }).trim();
  return output ? JSON.parse(output) : [];
}

function createStateDatabase(databasePath, rows = [], options = {}) {
  const destinationOnlyColumn = options.destinationOnly === false
    ? ''
    : ", destination_only TEXT NOT NULL DEFAULT 'preserved-default'";
  runSql(databasePath, `
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      rollout_path TEXT NOT NULL,
      archived INTEGER NOT NULL DEFAULT 0
      ${destinationOnlyColumn}
    );
    CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    ${rows.map((row) => `INSERT INTO threads (id, title, rollout_path) VALUES ('${row.id}', '${row.title}', '${row.rolloutPath}');`).join('\n')}
  `);
}

function acquireWriteLock(databasePath, sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(sqlitePath, [databasePath], { stdio: ['pipe', 'pipe', 'pipe'] });
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
    child.stdin.write(`.bail on\nBEGIN IMMEDIATE;\n${sql}\nSELECT 'LOCKED';\n`);
  });
}

test('mergeStateDatabase keeps existing live rows while adding snapshot rows', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'live-session', title: 'Live', rolloutPath: 'C:\\live.jsonl' },
  ]);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ], { destinationOnly: false });

  await mergeStateDatabase(
    sourceDbPath,
    destinationDbPath,
    new Set(['snapshot-session']),
    { sqlitePath }
  );

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id, title, destination_only FROM threads ORDER BY id;'),
    [
      { id: 'live-session', title: 'Live', destination_only: 'preserved-default' },
      { id: 'snapshot-session', title: 'Snapshot', destination_only: 'preserved-default' },
    ]
  );
});

test('mergeStateDatabase waits for a concurrent Codex commit and preserves both writes', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);
  const lock = await acquireWriteLock(
    destinationDbPath,
    "INSERT INTO threads (id, title, rollout_path) VALUES ('codex-session', 'Codex', 'C:\\codex.jsonl');"
  );

  const mergePromise = mergeStateDatabase(
    sourceDbPath,
    destinationDbPath,
    new Set(['snapshot-session']),
    { sqlitePath }
  );
  await new Promise((resolve) => setTimeout(resolve, 100));
  await lock.release();
  await mergePromise;

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'),
    [{ id: 'codex-session' }, { id: 'snapshot-session' }]
  );
});

test('mergeStateDatabase times out without partial writes when the live database stays locked', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);
  const lock = await acquireWriteLock(
    destinationDbPath,
    "INSERT INTO threads (id, title, rollout_path) VALUES ('codex-session', 'Codex', 'C:\\codex.jsonl');"
  );

  await assert.rejects(
    mergeStateDatabase(
      sourceDbPath,
      destinationDbPath,
      new Set(['snapshot-session']),
      { sqlitePath, busyTimeoutMs: 25 }
    ),
    (error) => error.code === 'SQLITE_BUSY'
  );
  await lock.release();

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'),
    [{ id: 'codex-session' }]
  );
});

test('mergeStateDatabase rolls back all rows when a statement fails', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath);
  createStateDatabase(sourceDbPath, [
    { id: 'good', title: 'Good', rolloutPath: 'C:\\good.jsonl' },
    { id: 'bad', title: 'Bad', rolloutPath: 'C:\\bad.jsonl' },
  ]);
  runSql(destinationDbPath, `
    CREATE TRIGGER reject_bad BEFORE INSERT ON threads
    WHEN NEW.id = 'bad'
    BEGIN
      SELECT RAISE(ABORT, 'forced merge failure');
    END;
  `);

  await assert.rejects(
    mergeStateDatabase(
      sourceDbPath,
      destinationDbPath,
      new Set(['good', 'bad']),
      { sqlitePath }
    ),
    /forced merge failure/
  );

  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM threads;'), []);
});

test('repairStateDatabaseRolloutPaths updates only requested sessions', async (t) => {
  const { destinationDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'session-1', title: 'One', rolloutPath: 'C:\\old-1.jsonl' },
    { id: 'session-2', title: 'Two', rolloutPath: 'C:\\old-2.jsonl' },
  ]);

  await repairStateDatabaseRolloutPaths(destinationDbPath, [{
    sessionId: 'session-1',
    rolloutPath: 'C:\\new-1.jsonl',
    archived: true,
  }], { sqlitePath });

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id, rollout_path, archived FROM threads ORDER BY id;'),
    [
      { id: 'session-1', rollout_path: 'C:\\new-1.jsonl', archived: 1 },
      { id: 'session-2', rollout_path: 'C:\\old-2.jsonl', archived: 0 },
    ]
  );
});

test('mergeSingleSessionStateDb imports only the requested snapshot session', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'live-session', title: 'Live', rolloutPath: 'C:\\live.jsonl' },
  ]);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-1', title: 'Snapshot one', rolloutPath: 'C:\\snapshot-1.jsonl' },
    { id: 'snapshot-2', title: 'Snapshot two', rolloutPath: 'C:\\snapshot-2.jsonl' },
  ]);

  await mergeSingleSessionStateDb(
    sourceDbPath,
    destinationDbPath,
    'snapshot-1',
    { sqlitePath }
  );

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'),
    [{ id: 'live-session' }, { id: 'snapshot-1' }]
  );
});

test('deleteSingleSessionStateDb removes only the requested session and related rows', async (t) => {
  const { destinationDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'session-1', title: 'One', rolloutPath: 'C:\\one.jsonl' },
    { id: 'session-2', title: 'Two', rolloutPath: 'C:\\two.jsonl' },
  ]);
  runSql(destinationDbPath, `
    CREATE TABLE thread_goals (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL);
    CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT);
    INSERT INTO thread_goals (id, thread_id) VALUES ('goal-1', 'session-1'), ('goal-2', 'session-2');
    INSERT INTO agent_job_items (id, assigned_thread_id) VALUES ('job-1', 'session-1'), ('job-2', 'session-2');
  `);

  await deleteSingleSessionStateDb(destinationDbPath, 'session-1', { sqlitePath });

  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'), [{ id: 'session-2' }]);
  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM thread_goals ORDER BY id;'), [{ id: 'goal-2' }]);
  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM agent_job_items ORDER BY id;'), [{ id: 'job-2' }]);
});

test('ensureRecoveredThreadsInStateDatabase inserts missing rows without overwriting existing rows', async (t) => {
  const { destinationDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'existing', title: 'Existing title', rolloutPath: 'C:\\existing.jsonl' },
  ]);

  const result = await ensureRecoveredThreadsInStateDatabase(destinationDbPath, [
    { id: 'existing', title: 'Replacement', rolloutPath: 'C:\\replacement.jsonl', archived: 0 },
    { id: 'recovered', title: 'Recovered', rolloutPath: 'C:\\recovered.jsonl', archived: 0 },
  ], { sqlitePath });

  assert.equal(result.insertedCount, 1);
  assert.equal(result.skippedCount, 1);
  assert.equal(result.warning, null);
  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id, title, rollout_path FROM threads ORDER BY id;'),
    [
      { id: 'existing', title: 'Existing title', rollout_path: 'C:\\existing.jsonl' },
      { id: 'recovered', title: 'Recovered', rollout_path: 'C:\\recovered.jsonl' },
    ]
  );
});

test('mergeStateDatabase exclusively creates a missing live database and sanitizes it', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(sourceDbPath, [
    { id: 'allowed', title: 'Allowed', rolloutPath: 'C:\\allowed.jsonl' },
    { id: 'not-restorable', title: 'Missing file', rolloutPath: 'C:\\missing.jsonl' },
  ]);
  runSql(sourceDbPath, `
    CREATE TABLE device_key_bindings (id TEXT PRIMARY KEY);
    INSERT INTO device_key_bindings (id) VALUES ('snapshot-binding');
  `);

  await mergeStateDatabase(
    sourceDbPath,
    destinationDbPath,
    new Set(['allowed']),
    { sqlitePath }
  );

  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'), [{ id: 'allowed' }]);
  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM device_key_bindings;'), []);
});

test('replaceStateDatabase replaces conversation rows but preserves unrelated live tables', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'old-live-session', title: 'Old live', rolloutPath: 'C:\\old.jsonl' },
  ]);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);
  runSql(destinationDbPath, `
    INSERT INTO app_settings (key, value) VALUES ('theme', 'dark');
    CREATE TABLE device_key_bindings (id TEXT PRIMARY KEY);
    INSERT INTO device_key_bindings (id) VALUES ('live-binding');
  `);

  await replaceStateDatabase(
    sourceDbPath,
    destinationDbPath,
    new Set(['snapshot-session']),
    { sqlitePath }
  );

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'),
    [{ id: 'snapshot-session' }]
  );
  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT key, value FROM app_settings;'),
    [{ key: 'theme', value: 'dark' }]
  );
  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM device_key_bindings;'), []);
});

test('replaceStateDatabase exclusively creates and sanitizes a missing live database', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(sourceDbPath, [
    { id: 'allowed', title: 'Allowed', rolloutPath: 'C:\\allowed.jsonl' },
    { id: 'not-restorable', title: 'Missing file', rolloutPath: 'C:\\missing.jsonl' },
  ]);
  runSql(sourceDbPath, `
    CREATE TABLE device_key_bindings (id TEXT PRIMARY KEY);
    INSERT INTO device_key_bindings (id) VALUES ('snapshot-binding');
  `);

  await replaceStateDatabase(
    sourceDbPath,
    destinationDbPath,
    new Set(['allowed']),
    { sqlitePath }
  );

  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'), [{ id: 'allowed' }]);
  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM device_key_bindings;'), []);
});

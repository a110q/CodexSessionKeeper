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
  preflightMergeStateDatabase,
  repairStateDatabaseRolloutPaths,
  replaceStateDatabase,
} = require('../../src/backup/live-state-database');

const sqlitePath = '/usr/bin/sqlite3';

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

test('replaceStateDatabase clears live-only conversation tables', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'old-live-session', title: 'Old live', rolloutPath: 'C:\\old.jsonl' },
  ]);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);
  runSql(destinationDbPath, `
    CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT, payload TEXT);
    INSERT INTO agent_job_items VALUES ('live-only', 'old-live-session', 'stale');
  `);

  await replaceStateDatabase(
    sourceDbPath,
    destinationDbPath,
    new Set(['snapshot-session']),
    { sqlitePath },
  );

  assert.deepEqual(queryRows(destinationDbPath, 'SELECT id FROM agent_job_items;'), []);
});

test('mergeStateDatabase applies rollout updates in the merge transaction', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'session-a', title: 'Live', rolloutPath: 'C:\\old.jsonl' },
  ]);
  createStateDatabase(sourceDbPath, [
    { id: 'session-a', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);

  await mergeStateDatabase(sourceDbPath, destinationDbPath, new Set(['session-a']), {
    sqlitePath,
    rolloutPathUpdates: [{
      sessionId: 'session-a',
      rolloutPath: 'C:\\safe\\sessions\\session-a.jsonl',
      archived: true,
    }],
  });

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT rollout_path, archived FROM threads WHERE id = \'session-a\';'),
    [{ rollout_path: 'C:\\safe\\sessions\\session-a.jsonl', archived: 1 }],
  );
});

test('rollout updates tolerate an older threads schema without rollout_path', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  runSql(destinationDbPath, `CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);`);
  runSql(sourceDbPath, `
    CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);
    INSERT INTO threads VALUES ('session-a', 'Snapshot');
  `);

  await mergeStateDatabase(sourceDbPath, destinationDbPath, new Set(['session-a']), {
    sqlitePath,
    rolloutPathUpdates: [{ sessionId: 'session-a', rolloutPath: 'C:\\safe.jsonl' }],
  });

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id, title FROM threads;'),
    [{ id: 'session-a', title: 'Snapshot' }],
  );
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

test('replaceStateDatabase preserves a live database created during candidate publication', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);
  const fsSync = require('node:fs');
  const linkSync = fsSync.linkSync;
  let injected = false;
  fsSync.linkSync = (sourcePath, targetPath) => {
    if (!injected && targetPath === destinationDbPath && sourcePath.includes('.candidate-')) {
      injected = true;
      createStateDatabase(destinationDbPath, [
        { id: 'codex-session', title: 'Created concurrently', rolloutPath: 'C:\\codex.jsonl' },
      ]);
      const error = new Error('destination exists');
      error.code = 'EEXIST';
      throw error;
    }
    return linkSync(sourcePath, targetPath);
  };
  try {
    await replaceStateDatabase(
      sourceDbPath,
      destinationDbPath,
      new Set(['snapshot-session']),
      { sqlitePath },
    );
  } finally {
    fsSync.linkSync = linkSync;
  }

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'),
    [{ id: 'codex-session' }, { id: 'snapshot-session' }],
  );
});

test('replaceStateDatabase fails closed if the concurrently created database disappears', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(sourceDbPath, [
    { id: 'snapshot-session', title: 'Snapshot', rolloutPath: 'C:\\snapshot.jsonl' },
  ]);
  const fsSync = require('node:fs');
  const linkSync = fsSync.linkSync;
  let injected = false;
  fsSync.linkSync = (sourcePath, targetPath) => {
    if (!injected && targetPath === destinationDbPath && sourcePath.includes('.candidate-')) {
      injected = true;
      createStateDatabase(destinationDbPath, [
        { id: 'codex-session', title: 'Created concurrently', rolloutPath: 'C:\\codex.jsonl' },
      ]);
      fsSync.rmSync(destinationDbPath, { force: true });
      const error = new Error('destination existed and disappeared');
      error.code = 'EEXIST';
      throw error;
    }
    return linkSync(sourcePath, targetPath);
  };
  try {
    await assert.rejects(
      replaceStateDatabase(
        sourceDbPath,
        destinationDbPath,
        new Set(['snapshot-session']),
        { sqlitePath },
      ),
      /消失|disappear/,
    );
  } finally {
    fsSync.linkSync = linkSync;
  }

  assert.equal(fsSync.existsSync(destinationDbPath), false);
});

test('selected-session relation conflict rolls back without overwriting an unselected owner', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(destinationDbPath, [
    { id: 'A', title: 'Live A', rolloutPath: 'C:\\live-a.jsonl' },
    { id: 'B', title: 'Live B', rolloutPath: 'C:\\live-b.jsonl' },
  ]);
  createStateDatabase(sourceDbPath, [
    { id: 'A', title: 'Snapshot A', rolloutPath: 'C:\\snapshot-a.jsonl' },
  ]);
  runSql(destinationDbPath, `
    CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT, payload TEXT);
    INSERT INTO agent_job_items VALUES ('shared', 'B', 'live B');
  `);
  runSql(sourceDbPath, `
    CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT, payload TEXT);
    INSERT INTO agent_job_items VALUES ('shared', 'A', 'snapshot A');
  `);

  await assert.rejects(
    mergeSingleSessionStateDb(sourceDbPath, destinationDbPath, 'A', { sqlitePath }),
    (error) => error.code === 'SQLITE_RESTORE_CONFLICT',
  );

  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id, title FROM threads ORDER BY id;'),
    [{ id: 'A', title: 'Live A' }, { id: 'B', title: 'Live B' }],
  );
  assert.deepEqual(
    queryRows(destinationDbPath, 'SELECT id, assigned_thread_id, payload FROM agent_job_items;'),
    [{ id: 'shared', assigned_thread_id: 'B', payload: 'live B' }],
  );
});

test('missing-destination merge failure never publishes the unsanitized source database', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(sourceDbPath, [
    { id: 'allowed', title: 'Allowed', rolloutPath: 'C:\\allowed.jsonl' },
    { id: 'not-selected', title: 'Not selected', rolloutPath: 'C:\\other.jsonl' },
  ]);
  runSql(sourceDbPath, `
    CREATE TABLE device_key_bindings (id TEXT PRIMARY KEY);
    INSERT INTO device_key_bindings VALUES ('secret');
  `);

  await assert.rejects(
    mergeStateDatabase(sourceDbPath, destinationDbPath, new Set(['allowed']), {
      sqlitePath: path.join(path.dirname(destinationDbPath), 'missing-sqlite3'),
    }),
  );

  assert.equal(require('node:fs').existsSync(destinationDbPath), false);
  assert.equal(require('node:fs').existsSync(`${destinationDbPath}-wal`), false);
  assert.equal(require('node:fs').existsSync(`${destinationDbPath}-shm`), false);
});

const relationConflictFixtures = [
  {
    table: 'threads',
    setup(databasePath, owner, isSource) {
      runSql(databasePath, `
        CREATE UNIQUE INDEX IF NOT EXISTS threads_unique_title ON threads(title);
        UPDATE threads SET title = ${isSource ? "'shared-title'" : owner === 'B' ? "'shared-title'" : "'live-a'"}
        WHERE id = '${owner}';
      `);
    },
  },
  ...[
    ['thread_goals', 'thread_id'],
    ['thread_dynamic_tools', 'thread_id'],
    ['stage1_outputs', 'thread_id'],
    ['agent_job_items', 'assigned_thread_id'],
  ].map(([table, ownerColumn]) => ({
    table,
    setup(databasePath, owner) {
      runSql(databasePath, `
        CREATE TABLE ${table} (id TEXT PRIMARY KEY, ${ownerColumn} TEXT, payload TEXT);
        INSERT INTO ${table} VALUES ('shared-key', '${owner}', '${owner} payload');
      `);
    },
  })),
  {
    table: 'thread_spawn_edges',
    setup(databasePath, owner) {
      runSql(databasePath, `
        CREATE TABLE thread_spawn_edges (
          id TEXT PRIMARY KEY,
          parent_thread_id TEXT,
          child_thread_id TEXT,
          payload TEXT
        );
        INSERT INTO thread_spawn_edges VALUES ('shared-key', '${owner}', '${owner}', '${owner} payload');
      `);
    },
  },
];

for (const fixture of relationConflictFixtures) {
  test(`${fixture.table} cross-session unique conflict rolls back the selected restore`, async (t) => {
    const { destinationDbPath, sourceDbPath } = await makeFixture(t);
    createStateDatabase(destinationDbPath, [
      { id: 'A', title: 'Live A', rolloutPath: 'C:\\live-a.jsonl' },
      { id: 'B', title: 'Live B', rolloutPath: 'C:\\live-b.jsonl' },
    ]);
    createStateDatabase(sourceDbPath, [
      { id: 'A', title: 'Snapshot A', rolloutPath: 'C:\\snapshot-a.jsonl' },
    ]);
    if (fixture.table === 'threads') {
      fixture.setup(destinationDbPath, 'A', false);
      fixture.setup(destinationDbPath, 'B', false);
      fixture.setup(sourceDbPath, 'A', true);
    } else {
      fixture.setup(destinationDbPath, 'B', false);
      fixture.setup(sourceDbPath, 'A', true);
    }

    await assert.rejects(
      preflightMergeStateDatabase(sourceDbPath, destinationDbPath, new Set(['A']), { sqlitePath }),
      (error) => error.code === 'SQLITE_RESTORE_CONFLICT',
    );
    await assert.rejects(
      mergeSingleSessionStateDb(sourceDbPath, destinationDbPath, 'A', { sqlitePath }),
      (error) => error.code === 'SQLITE_RESTORE_CONFLICT',
    );
    assert.deepEqual(
      queryRows(destinationDbPath, 'SELECT id FROM threads ORDER BY id;'),
      [{ id: 'A' }, { id: 'B' }],
    );
  });
}

test('candidate sanitization trigger failure leaves no live database or sidecar', async (t) => {
  const { destinationDbPath, sourceDbPath } = await makeFixture(t);
  createStateDatabase(sourceDbPath, [
    { id: 'allowed', title: 'Allowed', rolloutPath: 'C:\\allowed.jsonl' },
    { id: 'not-selected', title: 'Other', rolloutPath: 'C:\\other.jsonl' },
  ]);
  runSql(sourceDbPath, `
    CREATE TRIGGER reject_candidate_delete BEFORE DELETE ON threads
    WHEN OLD.id = 'not-selected'
    BEGIN
      SELECT RAISE(ABORT, 'candidate cleaning rejected');
    END;
  `);

  await assert.rejects(
    mergeStateDatabase(sourceDbPath, destinationDbPath, new Set(['allowed']), { sqlitePath }),
    /candidate cleaning rejected/,
  );
  assert.equal(require('node:fs').existsSync(destinationDbPath), false);
  assert.equal(require('node:fs').existsSync(`${destinationDbPath}-wal`), false);
  assert.equal(require('node:fs').existsSync(`${destinationDbPath}-shm`), false);
});

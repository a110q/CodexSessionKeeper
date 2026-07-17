const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { runSQLite } = require('../../src/backup/live-state-database');
const {
  createConsistentStateDatabaseSnapshot,
  createConsistentStateDatabaseSnapshotForTesting,
  protectionSnapshotWarning,
} = require('../../src/backup/snapshot-state-database');

const sqlitePath = '/usr/bin/sqlite3';

async function makeFixture(t, directoryName = 'snapshot-state-database-') {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), directoryName));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  return {
    root,
    sourcePath: path.join(root, 'state_5.sqlite'),
    destinationPath: path.join(root, 'snapshot', 'state_5.sqlite'),
  };
}

function runSql(databasePath, sql) {
  execFileSync(sqlitePath, [databasePath], {
    input: `.bail on\n${sql}\n`,
    encoding: 'utf8',
  });
}

function queryRows(databasePath, sql) {
  const output = execFileSync(sqlitePath, ['-json', databasePath, sql], { encoding: 'utf8' }).trim();
  return output ? JSON.parse(output) : [];
}

async function openWalDatabase(databasePath) {
  const child = spawn(sqlitePath, [databasePath], { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  const ready = new Promise((resolve, reject) => {
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (stdout.includes('SNAPSHOT_READY')) resolve();
    });
    child.once('error', reject);
    child.once('close', (status) => {
      if (!stdout.includes('SNAPSHOT_READY')) {
        reject(new Error(stderr || `sqlite3 exited ${status} before the WAL fixture was ready`));
      }
    });
  });

  child.stdin.write([
    '.bail on',
    'PRAGMA journal_mode=WAL;',
    'PRAGMA wal_autocheckpoint=0;',
    'CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);',
    'PRAGMA wal_checkpoint(TRUNCATE);',
    'BEGIN;',
    "INSERT INTO threads (id, title) VALUES ('committed-in-wal', 'kept');",
    'COMMIT;',
    "SELECT 'SNAPSHOT_READY';",
    '',
  ].join('\n'));
  await ready;

  return {
    close: () => new Promise((resolve, reject) => {
      child.once('close', (status) => {
        if (status === 0) resolve();
        else reject(new Error(stderr || `sqlite3 exited ${status}`));
      });
      child.stdin.end('.quit\n');
    }),
  };
}

async function acquireExclusiveLock(databasePath) {
  const child = spawn(sqlitePath, [databasePath], { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  const locked = new Promise((resolve, reject) => {
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (stdout.includes('EXCLUSIVE_LOCK_READY')) resolve();
    });
    child.once('error', reject);
    child.once('close', (status) => {
      if (!stdout.includes('EXCLUSIVE_LOCK_READY')) {
        reject(new Error(stderr || `sqlite3 exited ${status} before acquiring the lock`));
      }
    });
  });

  child.stdin.write([
    '.bail on',
    'BEGIN EXCLUSIVE;',
    "SELECT 'EXCLUSIVE_LOCK_READY';",
    '',
  ].join('\n'));
  await locked;

  return () => new Promise((resolve, reject) => {
    child.once('close', (status) => {
      if (status === 0) resolve();
      else reject(new Error(stderr || `sqlite3 exited ${status}`));
    });
    child.stdin.end('ROLLBACK;\n.quit\n');
  });
}

async function temporaryArtifacts(destinationPath) {
  const parent = path.dirname(destinationPath);
  try {
    const entries = await fs.readdir(parent);
    return entries.filter((entry) => entry.startsWith(`${path.basename(destinationPath)}.snapshot-`));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

test('captures committed WAL rows while the source connection remains open', async (t) => {
  const fixture = await makeFixture(t);
  const connection = await openWalDatabase(fixture.sourcePath);
  t.after(() => connection.close());

  const walStat = await fs.stat(`${fixture.sourcePath}-wal`);
  assert.ok(walStat.size > 0);

  await createConsistentStateDatabaseSnapshot({
    sourcePath: fixture.sourcePath,
    destinationPath: fixture.destinationPath,
    sqlitePath,
  });

  assert.deepEqual(
    queryRows(fixture.destinationPath, 'SELECT id, title FROM threads;'),
    [{ id: 'committed-in-wal', title: 'kept' }]
  );
  assert.equal(await fs.stat(fixture.destinationPath).then(() => true), true);
  await assert.rejects(fs.stat(`${fixture.destinationPath}-wal`), (error) => error.code === 'ENOENT');
  await assert.rejects(fs.stat(`${fixture.destinationPath}-shm`), (error) => error.code === 'ENOENT');
});

test('supports spaces, Chinese characters, and single quotes in database paths', async (t) => {
  const fixture = await makeFixture(t, "SQLite 路径 with space's-");
  runSql(fixture.sourcePath, `
    CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);
    INSERT INTO threads VALUES ('quoted-path', '路径安全');
  `);
  fixture.destinationPath = path.join(fixture.root, "快照 folder's", 'state_5.sqlite');

  await createConsistentStateDatabaseSnapshot({
    sourcePath: fixture.sourcePath,
    destinationPath: fixture.destinationPath,
    sqlitePath,
  });

  assert.deepEqual(
    queryRows(fixture.destinationPath, 'SELECT id, title FROM threads;'),
    [{ id: 'quoted-path', title: '路径安全' }]
  );
});

test('does not overwrite an existing destination database', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, 'CREATE TABLE threads (id TEXT PRIMARY KEY);');
  await fs.mkdir(path.dirname(fixture.destinationPath), { recursive: true });
  await fs.writeFile(fixture.destinationPath, 'existing-snapshot');

  await assert.rejects(
    createConsistentStateDatabaseSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
    }),
    /already exists|EEXIST|已存在/i
  );

  assert.equal(await fs.readFile(fixture.destinationPath, 'utf8'), 'existing-snapshot');
  assert.deepEqual(await temporaryArtifacts(fixture.destinationPath), []);
});

test('missing source creates neither the destination nor its parent directory', async (t) => {
  const fixture = await makeFixture(t);

  await assert.rejects(
    createConsistentStateDatabaseSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
    }),
    (error) => error.code === 'ENOENT'
  );

  await assert.rejects(fs.stat(path.dirname(fixture.destinationPath)), (error) => error.code === 'ENOENT');
});

test('removes temporary output when sqlite3 VACUUM fails', async (t) => {
  const fixture = await makeFixture(t);
  await fs.writeFile(fixture.sourcePath, 'not-a-database');

  await assert.rejects(
    createConsistentStateDatabaseSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
    })
  );

  await assert.rejects(fs.stat(fixture.destinationPath), (error) => error.code === 'ENOENT');
  assert.deepEqual(await temporaryArtifacts(fixture.destinationPath), []);
});

test('rejects a non-ok integrity result and removes the temporary database', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, 'CREATE TABLE threads (id TEXT PRIMARY KEY);');
  const createSnapshot = createConsistentStateDatabaseSnapshotForTesting({
    runSQLite: async (databasePath, sql, options) => {
      if (/PRAGMA integrity_check/i.test(sql)) return 'not ok\n';
      return runSQLite(databasePath, sql, options);
    },
  });

  await assert.rejects(
    createSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
    }),
    /integrity_check/i
  );

  await assert.rejects(fs.stat(fixture.destinationPath), (error) => error.code === 'ENOENT');
  assert.deepEqual(await temporaryArtifacts(fixture.destinationPath), []);
});

test('sync failure closes the file and leaves no destination or temporary database', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, 'CREATE TABLE threads (id TEXT PRIMARY KEY);');
  let didClose = false;
  const createSnapshot = createConsistentStateDatabaseSnapshotForTesting({
    fileSystem: {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        return {
          sync: async () => { throw new Error('forced sync failure'); },
          close: async () => {
            didClose = true;
            await handle.close();
          },
        };
      },
    },
  });

  await assert.rejects(
    createSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
    }),
    /forced sync failure/
  );

  assert.equal(didClose, true);
  await assert.rejects(fs.stat(fixture.destinationPath), (error) => error.code === 'ENOENT');
  assert.deepEqual(await temporaryArtifacts(fixture.destinationPath), []);
});

test('atomic publish failure leaves no destination or temporary database', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, 'CREATE TABLE threads (id TEXT PRIMARY KEY);');
  const createSnapshot = createConsistentStateDatabaseSnapshotForTesting({
    fileSystem: {
      ...fs,
      link: async () => { throw new Error('forced publish failure'); },
    },
  });

  await assert.rejects(
    createSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
    }),
    /forced publish failure/
  );

  await assert.rejects(fs.stat(fixture.destinationPath), (error) => error.code === 'ENOENT');
  assert.deepEqual(await temporaryArtifacts(fixture.destinationPath), []);
});

test('temporary link cleanup failure keeps the published destination and reports success', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, `
    CREATE TABLE threads (id TEXT PRIMARY KEY);
    INSERT INTO threads VALUES ('published');
  `);
  const createSnapshot = createConsistentStateDatabaseSnapshotForTesting({
    fileSystem: {
      ...fs,
      rm: async (targetPath, options) => {
        if (path.basename(targetPath).startsWith('state_5.sqlite.snapshot-')) {
          const error = new Error('forced temporary cleanup failure');
          error.code = 'EPERM';
          throw error;
        }
        return fs.rm(targetPath, options);
      },
    },
  });

  await createSnapshot({
    sourcePath: fixture.sourcePath,
    destinationPath: fixture.destinationPath,
    sqlitePath,
  });

  assert.deepEqual(
    queryRows(fixture.destinationPath, 'SELECT id FROM threads;'),
    [{ id: 'published' }]
  );
  assert.equal((await temporaryArtifacts(fixture.destinationPath)).length, 1);
});

test('passes the default and requested busy timeout to every sqlite3 invocation', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, 'CREATE TABLE threads (id TEXT PRIMARY KEY);');
  const calls = [];
  const createSnapshot = createConsistentStateDatabaseSnapshotForTesting({
    runSQLite: async (databasePath, sql, options) => {
      calls.push({ databasePath, sql, options });
      return runSQLite(databasePath, sql, options);
    },
  });

  await createSnapshot({
    sourcePath: fixture.sourcePath,
    destinationPath: fixture.destinationPath,
    sqlitePath,
  });
  assert.deepEqual(calls.map((call) => call.options.busyTimeoutMs), [5000, 5000]);

  const secondDestination = path.join(fixture.root, 'snapshot-2', 'state_5.sqlite');
  calls.length = 0;
  await createSnapshot({
    sourcePath: fixture.sourcePath,
    destinationPath: secondDestination,
    sqlitePath,
    busyTimeoutMs: 37,
  });
  assert.deepEqual(calls.map((call) => call.options.busyTimeoutMs), [37, 37]);
});

test('real sqlite lock timeout leaves no destination or temporary database', async (t) => {
  const fixture = await makeFixture(t);
  runSql(fixture.sourcePath, 'CREATE TABLE threads (id TEXT PRIMARY KEY);');
  const release = await acquireExclusiveLock(fixture.sourcePath);
  t.after(release);

  await assert.rejects(
    createConsistentStateDatabaseSnapshot({
      sourcePath: fixture.sourcePath,
      destinationPath: fixture.destinationPath,
      sqlitePath,
      busyTimeoutMs: 25,
    }),
    (error) => error.code === 'SQLITE_BUSY'
  );

  await assert.rejects(fs.stat(fixture.destinationPath), (error) => error.code === 'ENOENT');
  assert.deepEqual(await temporaryArtifacts(fixture.destinationPath), []);
});

test('main uses the consistent snapshot helper and degrades without copying WAL sidecars', async () => {
  const mainPath = path.join(__dirname, '..', '..', 'src', 'main.js');
  const source = await fs.readFile(mainPath, 'utf8');

  assert.match(source, /require\(['"]\.\/backup\/snapshot-state-database['"]\)/);
  assert.match(source, /createConsistentStateDatabaseSnapshot\s*\(/);
  assert.doesNotMatch(source, /copyPathIntoSnapshot\(\s*['"]state_5\.sqlite['"]/);
  assert.match(source, /SQLite 索引库无法生成一致副本，已降级创建文件型快照/);
  assert.match(source, /state_5\.sqlite-shm/);
  assert.match(source, /state_5\.sqlite-wal/);
  assert.match(source, /if \(stateCopy\.ok\)[\s\S]{0,180}(includedPaths\.push|includedPaths\.add)\(['"]state_5\.sqlite['"]\)/);
  assert.equal((source.match(/else if \(stateCopy\.warning\) \{\s*warnings\.push\(stateCopy\.warning\);/g) || []).length, 2);

  const wrapper = source.match(/async function copyStateDatabaseIntoSnapshot[\s\S]*?\n}\n\nfunction removeStateDatabaseSidecars/)?.[0] || '';
  assert.doesNotMatch(wrapper, /rmSync\s*\(/);
});

test('protection snapshot warning describes only a degraded SQLite protection point', () => {
  const warning = 'SQLite 索引库无法生成一致副本，已降级创建文件型快照。原因：database is busy';
  assert.equal(
    protectionSnapshotWarning({ warnings: [warning], includedPaths: ['sessions'] }),
    ' 注意：保护快照不包含 SQLite 索引；会话文件保护点仍已创建。'
  );
  assert.equal(protectionSnapshotWarning({ warnings: [], includedPaths: ['sessions'] }), '');
  assert.equal(
    protectionSnapshotWarning({ warnings: [warning], includedPaths: ['sessions', 'state_5.sqlite'] }),
    ''
  );
});

test('all restore and delete protection snapshots append degradation warnings to IPC success messages', async () => {
  const mainPath = path.join(__dirname, '..', '..', 'src', 'main.js');
  const source = await fs.readFile(mainPath, 'utf8');

  assert.equal(
    (source.match(/const protectionSnapshot = await createRestoreProtectionSnapshot\s*\(/g) || []).length,
    6
  );
  assert.equal(
    (source.match(/const protectionSnapshot = await createSessionProtectionSnapshot\s*\(/g) || []).length,
    2
  );
  assert.equal(
    (source.match(/const protectionWarning = protectionSnapshotWarning\(protectionSnapshot\);/g) || []).length,
    8
  );
  assert.equal((source.match(/\$\{protectionWarning\}/g) || []).length, 8);
});

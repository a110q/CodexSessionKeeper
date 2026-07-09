const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const initSqlJs = require('sql.js');

const {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
} = require('../../src/backup/recovered-thread-index');

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'recovered-thread-index-'));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  const codexRoot = path.join(root, '.codex');
  const recoveredRoot = path.join(codexRoot, 'sessions', 'recovered');
  await fs.mkdir(recoveredRoot, { recursive: true });
  return { root, codexRoot, recoveredRoot };
}

function record(sessionId, title = 'Manifest Title') {
  return {
    sessionId,
    sourcePath: `C:\\Users\\Ada\\.codex\\sessions\\${sessionId}.jsonl`,
    backupPath: `sessions/2026/07/08/${sessionId}.jsonl`,
    title,
    firstSeenAt: '2026-07-08T12:00:00.000Z',
    lastBackedUpAt: '2026-07-08T12:05:00.000Z',
    lineCount: 1,
    bytesBackedUp: 100,
    status: 'active',
  };
}

async function createStateDatabase(databasePath) {
  const SQL = await initSqlJs();
  const db = new SQL.Database();
  db.run(`
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      model_provider TEXT NOT NULL,
      cwd TEXT NOT NULL,
      title TEXT NOT NULL,
      sandbox_policy TEXT NOT NULL,
      approval_mode TEXT NOT NULL,
      tokens_used INTEGER NOT NULL DEFAULT 0,
      has_user_event INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      archived_at INTEGER,
      cli_version TEXT NOT NULL DEFAULT '',
      first_user_message TEXT NOT NULL DEFAULT '',
      memory_mode TEXT NOT NULL DEFAULT 'enabled',
      model TEXT,
      created_at_ms INTEGER,
      updated_at_ms INTEGER,
      thread_source TEXT,
      preview TEXT NOT NULL DEFAULT '',
      recency_at INTEGER NOT NULL DEFAULT 0,
      recency_at_ms INTEGER NOT NULL DEFAULT 0
    );
  `);
  await fs.writeFile(databasePath, Buffer.from(db.export()));
  db.close();
}

async function queryRows(databasePath, sql) {
  const SQL = await initSqlJs();
  const db = new SQL.Database(await fs.readFile(databasePath));
  try {
    const result = db.exec(sql);
    return result[0] ? result[0].values : [];
  } finally {
    db.close();
  }
}

test('extractRecoveredThreadMetadata prefers manifest title and jsonl timestamps', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'session-1.jsonl');
  await fs.writeFile(recoveredPath, [
    '{"timestamp":"2026-07-08T12:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello from jsonl"}}',
    '{"timestamp":"2026-07-08T12:05:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"reply"}]}}',
    '',
  ].join('\n'), 'utf8');

  const entry = await extractRecoveredThreadMetadata(record('session-1'), recoveredPath, codexRoot);

  assert.equal(entry.id, 'session-1');
  assert.equal(entry.rolloutPath, recoveredPath);
  assert.equal(entry.title, 'Manifest Title');
  assert.equal(entry.firstUserMessage, 'hello from jsonl');
  assert.equal(entry.preview, 'hello from jsonl');
  assert.equal(entry.createdAt, 1783512001);
  assert.equal(entry.updatedAt, 1783512302);
  assert.equal(entry.createdAtMs, 1783512001000);
  assert.equal(entry.updatedAtMs, 1783512302000);
  assert.equal(entry.archived, 0);
  assert.equal(entry.hasUserEvent, 1);
});

test('extractRecoveredThreadMetadata falls back to record dates and session id', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'session-2.jsonl');
  await fs.writeFile(recoveredPath, '{"role":"assistant","content":"only assistant"}\n', 'utf8');

  const entry = await extractRecoveredThreadMetadata(record('session-2', ''), recoveredPath, codexRoot);

  assert.equal(entry.id, 'session-2');
  assert.equal(entry.title, 'session-2');
  assert.equal(entry.firstUserMessage, '');
  assert.equal(entry.createdAt, 1783512000);
  assert.equal(entry.updatedAt, 1783512300);
  assert.equal(entry.hasUserEvent, 0);
});

test('ensureRecoveredThreadsInStateDatabase inserts missing row', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const databasePath = path.join(codexRoot, 'state_5.sqlite');
  await createStateDatabase(databasePath);
  const recoveredPath = path.join(recoveredRoot, 'session-1.jsonl');
  await fs.writeFile(recoveredPath, '{"role":"user","content":"hello"}\n', 'utf8');
  const entry = await extractRecoveredThreadMetadata(record('session-1', 'Inserted Title'), recoveredPath, codexRoot);

  const result = await ensureRecoveredThreadsInStateDatabase(databasePath, [entry]);

  assert.equal(result.insertedCount, 1);
  assert.equal(result.skippedCount, 0);
  assert.equal(result.warning, null);
  const rows = await queryRows(databasePath, "SELECT id, title, rollout_path, archived FROM threads WHERE id = 'session-1';");
  assert.deepEqual(rows[0], ['session-1', 'Inserted Title', recoveredPath, 0]);
});

test('ensureRecoveredThreadsInStateDatabase does not overwrite existing row', async (t) => {
  const { codexRoot } = await makeFixture(t);
  const databasePath = path.join(codexRoot, 'state_5.sqlite');
  await createStateDatabase(databasePath);
  const SQL = await initSqlJs();
  const db = new SQL.Database(await fs.readFile(databasePath));
  db.run("INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode, archived, first_user_message, preview, recency_at, recency_at_ms) VALUES ('existing', '/old.jsonl', 1, 1, 'vscode', 'openai', '', 'Old Title', '', '', 0, '', '', 1, 1000);");
  await fs.writeFile(databasePath, Buffer.from(db.export()));
  db.close();

  const result = await ensureRecoveredThreadsInStateDatabase(databasePath, [{
    id: 'existing',
    rolloutPath: '/new.jsonl',
    createdAt: 2,
    updatedAt: 2,
    source: 'recovered',
    modelProvider: 'unknown',
    cwd: '',
    title: 'New Title',
    sandboxPolicy: '',
    approvalMode: '',
    tokensUsed: 0,
    hasUserEvent: 1,
    archived: 0,
    archivedAt: null,
    firstUserMessage: 'New Title',
    model: 'unknown',
    preview: 'New Title',
    recencyAt: 2,
    createdAtMs: 2000,
    updatedAtMs: 2000,
    recencyAtMs: 2000,
    threadSource: 'recovered',
    cliVersion: '',
    memoryMode: 'enabled',
  }]);

  assert.equal(result.insertedCount, 0);
  assert.equal(result.skippedCount, 1);
  const rows = await queryRows(databasePath, "SELECT title, rollout_path FROM threads WHERE id = 'existing';");
  assert.deepEqual(rows[0], ['Old Title', '/old.jsonl']);
});

test('ensureRecoveredThreadsInStateDatabase returns warning when database is missing', async (t) => {
  const { codexRoot } = await makeFixture(t);

  const result = await ensureRecoveredThreadsInStateDatabase(
    path.join(codexRoot, 'missing-state.sqlite'),
    [{ id: 'missing' }]
  );

  assert.equal(result.insertedCount, 0);
  assert.equal(result.warning, 'SQLite 索引未写入：state_5.sqlite 不存在');
});

test('ensureRecoveredThreadsInStateDatabase returns warning when threads table is missing', async (t) => {
  const { codexRoot } = await makeFixture(t);
  const databasePath = path.join(codexRoot, 'state_5.sqlite');
  const SQL = await initSqlJs();
  const db = new SQL.Database();
  db.run('CREATE TABLE unrelated (id TEXT PRIMARY KEY);');
  await fs.writeFile(databasePath, Buffer.from(db.export()));
  db.close();

  const result = await ensureRecoveredThreadsInStateDatabase(databasePath, [{ id: 'missing' }]);

  assert.equal(result.insertedCount, 0);
  assert.equal(result.warning, 'SQLite 索引未写入：threads 表不存在');
});

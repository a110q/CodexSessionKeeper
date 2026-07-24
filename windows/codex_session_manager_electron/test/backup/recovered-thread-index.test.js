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

async function withTrackedReadsAndParses(filePath, operation) {
  const originalOpen = fs.open;
  const originalParse = JSON.parse;
  const originalConcat = Buffer.concat;
  const events = [];
  const readBuffers = [];
  const parsedLineBytes = [];
  let concatCalls = 0;
  fs.open = async function (openedPath, ...args) {
    const handle = await originalOpen.call(fs, openedPath, ...args);
    if (path.resolve(String(openedPath)) === path.resolve(filePath)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (...readArgs) => {
        readBuffers.push(readArgs[0]);
        const result = await originalRead(...readArgs);
        if (result.bytesRead > 0) events.push('read');
        return result;
      };
    }
    return handle;
  };
  JSON.parse = function (value, ...args) {
    events.push('parse');
    parsedLineBytes.push(Buffer.byteLength(String(value)));
    return originalParse.call(JSON, value, ...args);
  };
  Buffer.concat = function (...args) {
    concatCalls += 1;
    return originalConcat.apply(Buffer, args);
  };
  try {
    return {
      result: await operation(),
      events,
      readBuffers,
      parsedLineBytes,
      get concatCalls() { return concatCalls; },
    };
  } finally {
    Buffer.concat = originalConcat;
    JSON.parse = originalParse;
    fs.open = originalOpen;
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

test('recovered metadata parses records as they stream instead of accumulating 400 decoded lines', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'streamed-metadata.jsonl');
  const contents = Array.from(
    { length: 400 },
    (_, index) => `${JSON.stringify({ timestamp: `2026-07-08T12:00:${String(index % 60).padStart(2, '0')}Z`, index })}\n`,
  ).join('');
  await fs.writeFile(recoveredPath, contents, 'utf8');

  const readBufferBytes = 128;
  const maxLineBytes = 128;
  const {
    result,
    events,
    readBuffers,
    parsedLineBytes,
    concatCalls,
  } = await withTrackedReadsAndParses(
    recoveredPath,
    () => extractRecoveredThreadMetadata(
      record('streamed-metadata'),
      recoveredPath,
      codexRoot,
      { maxLineBytes, readBufferBytes },
    ),
  );
  const firstParse = events.indexOf('parse');
  const secondRead = events.indexOf('read', events.indexOf('read') + 1);

  assert.equal(result.id, 'streamed-metadata');
  assert.ok(firstParse >= 0);
  assert.ok(secondRead >= 0);
  assert.ok(firstParse < secondRead, `expected parse before second read, got ${events.slice(0, 8).join(', ')}`);
  assert.equal(new Set(readBuffers).size, 1);
  assert.equal(parsedLineBytes.length, 400);
  assert.ok(Math.max(...parsedLineBytes) + readBufferBytes <= maxLineBytes + readBufferBytes);
  assert.equal(concatCalls, 0);
});

test('recovered metadata caps retained first-message and preview text', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'bounded-preview.jsonl');
  const message = 'x'.repeat(8192);
  await fs.writeFile(recoveredPath, `${JSON.stringify({ role: 'user', content: message })}\n`, 'utf8');

  const originalSplit = String.prototype.split;
  let largestWhitespaceNormalization = 0;
  String.prototype.split = function (separator, ...args) {
    if (separator instanceof RegExp && separator.source === '\\s+') {
      largestWhitespaceNormalization = Math.max(largestWhitespaceNormalization, String(this).length);
    }
    return originalSplit.call(this, separator, ...args);
  };
  let entry;
  try {
    entry = await extractRecoveredThreadMetadata(
      record('bounded-preview', ''),
      recoveredPath,
      codexRoot,
      { maxLineBytes: 16 * 1024, readBufferBytes: 128 },
    );
  } finally {
    String.prototype.split = originalSplit;
  }

  assert.equal(entry.firstUserMessage, message.slice(0, 4096));
  assert.equal(entry.preview, message.slice(0, 4096));
  assert.equal(entry.title, message.slice(0, 180));
  assert.ok(largestWhitespaceNormalization <= 4096);
});

test('recovered metadata rejects max plus one when newline arrives in the next chunk', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'boundary.jsonl');
  await fs.writeFile(recoveredPath, Buffer.concat([
    Buffer.alloc(8, 0x78),
    Buffer.from('x\n'),
  ]));

  await assert.rejects(
    extractRecoveredThreadMetadata(
      record('boundary'),
      recoveredPath,
      codexRoot,
      { maxLineBytes: 8, readBufferBytes: 8 },
    ),
    /exceeds 8 bytes/,
  );
});

test('recovered metadata accepts an exact maxLineBytes record', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'exact-boundary.jsonl');
  const exactLine = Buffer.from('{"a":1 }');
  await fs.writeFile(recoveredPath, Buffer.concat([exactLine, Buffer.from('\n')]));

  const entry = await extractRecoveredThreadMetadata(
    record('exact-boundary'),
    recoveredPath,
    codexRoot,
    { maxLineBytes: exactLine.length, readBufferBytes: 3 },
  );

  assert.equal(entry.id, 'exact-boundary');
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

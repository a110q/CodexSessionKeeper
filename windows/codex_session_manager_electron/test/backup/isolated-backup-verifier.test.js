'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  runIsolatedBackupVerification,
} = require('../../src/backup/isolated-backup-verifier');

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'isolated-backup-verifier-'));
  t.after(() => fs.rm(root, { force: true, recursive: true }));
  return root;
}

test('isolated full verification returns hashes and exits before resolving', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'session.jsonl');
  const contents = Buffer.from('{"ok":true}\n');
  await fs.writeFile(filePath, contents);
  const events = [];

  const result = await runIsolatedBackupVerification({
    operation: 'verifyFull',
    payload: { filePath, chunkSize: 8, maxLineBytes: 64 },
    onLifecycle: (event) => events.push(event),
  });

  assert.equal(result.contentHash, sha256(contents));
  assert.deepEqual(events, ['started', 'message', 'exited']);
});

test('isolated verification returns a malformed JSON failure after worker exit', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'invalid.jsonl');
  await fs.writeFile(filePath, '{not-json}\n');
  const events = [];

  await assert.rejects(
    runIsolatedBackupVerification({
      operation: 'verifyFull',
      payload: { filePath, chunkSize: 4, maxLineBytes: 64 },
      onLifecycle: (event) => events.push(event),
    }),
    /Invalid JSONL at line 1/,
  );
  assert.deepEqual(events, ['started', 'message', 'exited']);
});

test('isolated changed-chunk verification preserves the public result contract', async (t) => {
  const root = await fixture(t);
  const sourcePath = path.join(root, 'source.jsonl');
  const targetPath = path.join(root, 'target.jsonl');
  const contents = Buffer.from('{"ok":true}\n');
  await Promise.all([
    fs.writeFile(sourcePath, contents),
    fs.writeFile(targetPath, contents),
  ]);

  const result = await runIsolatedBackupVerification({
    operation: 'verifyChangedChunks',
    payload: {
      sourcePath,
      targetPath,
      previous: {
        backupPath: 'sessions/session.jsonl',
        byteCount: 0,
        lineCount: 0,
        chunkHashes: [],
        verifiedAt: '2026-07-15T00:00:00.000Z',
      },
      backupPath: 'sessions/session.jsonl',
      committedByteCount: contents.length,
      lineCount: 1,
      verifiedAt: new Date('2026-07-15T00:01:00.000Z'),
      chunkSize: 8,
      maxLineBytes: 64,
    },
  });

  assert.deepEqual(result, {
    backupPath: 'sessions/session.jsonl',
    byteCount: contents.length,
    lineCount: 1,
    chunkHashes: [sha256(contents.subarray(0, 8)), sha256(contents.subarray(8))],
    verifiedAt: '2026-07-15T00:01:00.000Z',
  });
});

test('unsupported operations and already-aborted work never create a worker', async () => {
  let workerCount = 0;
  const workerFactory = () => {
    workerCount += 1;
    throw new Error('worker must not be created');
  };

  await assert.rejects(
    runIsolatedBackupVerification({ operation: 'unknown', payload: {}, workerFactory }),
    /Unsupported backup verification operation/,
  );
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    runIsolatedBackupVerification({
      operation: 'verifyFull',
      payload: {},
      signal: controller.signal,
      workerFactory,
    }),
    (error) => error?.name === 'AbortError' && error?.code === 'ABORT_ERR',
  );
  assert.equal(workerCount, 0);
});

test('abort after worker start waits for exit and does not accept a result', async () => {
  class ControlledWorker extends EventEmitter {
    terminate() {
      queueMicrotask(() => this.emit('exit', 1));
      return Promise.resolve(1);
    }
  }
  const controller = new AbortController();
  const events = [];

  await assert.rejects(
    runIsolatedBackupVerification({
      operation: 'verifyFull',
      payload: {},
      signal: controller.signal,
      workerFactory: () => new ControlledWorker(),
      onLifecycle: (event) => {
        events.push(event);
        if (event === 'started') controller.abort();
      },
    }),
    (error) => error?.name === 'AbortError' && error?.code === 'ABORT_ERR',
  );
  assert.deepEqual(events, ['started', 'exited']);
});

test('malformed worker protocol is rejected only after worker exit', async () => {
  class MalformedWorker extends EventEmitter {
    constructor() {
      super();
      queueMicrotask(() => {
        this.emit('message', { version: 2, ok: true, result: {} });
        this.emit('exit', 0);
      });
    }
  }
  const events = [];

  await assert.rejects(
    runIsolatedBackupVerification({
      operation: 'verifyFull',
      payload: {},
      workerFactory: () => new MalformedWorker(),
      onLifecycle: (event) => events.push(event),
    }),
    /Worker failed/,
  );
  assert.deepEqual(events, ['started', 'message', 'exited']);
});

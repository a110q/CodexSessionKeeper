'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  publishSyncedTemporaryFileIfAbsent,
  replaceFileDurably,
  writeFileDurably,
} = require('../../src/backup/durable-write');

test('durable replace syncs before rename and removes only its temporary file', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'manifest.json');
  await fsp.writeFile(destination, 'committed');
  let syncCount = 0;

  await replaceFileDurably(destination, 'replacement', {
    sync: async (handle) => { syncCount += 1; await handle.sync(); }
  });

  assert.equal(await fsp.readFile(destination, 'utf8'), 'replacement');
  assert.equal(syncCount, 1);
  assert.deepEqual(await fsp.readdir(root), ['manifest.json']);
});

test('sync failure preserves destination and cleans temporary file', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'manifest.json');
  await fsp.writeFile(destination, 'committed');

  await assert.rejects(
    replaceFileDurably(destination, 'uncommitted', { sync: async () => { throw new Error('sync failed'); } }),
    /sync failed/
  );

  assert.equal(await fsp.readFile(destination, 'utf8'), 'committed');
  assert.deepEqual(await fsp.readdir(root), ['manifest.json']);
});

test('writeFileDurably never overwrites an existing destination', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'session.jsonl');
  await fsp.writeFile(destination, 'live');

  await assert.rejects(writeFileDurably(destination, 'backup'));
  assert.equal(await fsp.readFile(destination, 'utf8'), 'live');
});

test('writeFileDurably fails closed and cleans its temp when SMB rejects hard links', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'session.jsonl');
  let linkAttempts = 0;

  await assert.rejects(
    writeFileDurably(destination, 'backup', {
      link: async () => {
        linkAttempts += 1;
        const error = new Error('SMB hard links are unsupported');
        error.code = 'ENOTSUP';
        throw error;
      },
    }),
    (error) => {
      assert.equal(error.code, 'ATOMIC_NO_REPLACE_UNSUPPORTED');
      assert.match(error.message, /atomic no-replace|unsupported/i);
      return true;
    },
  );

  assert.equal(linkAttempts, 1);
  await assert.rejects(fsp.readFile(destination), { code: 'ENOENT' });
  assert.deepEqual(await fsp.readdir(root), []);
});

test('unsupported hard-link publication never invokes the racy rename fallback', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'session.jsonl');
  const temporary = path.join(root, '.session.jsonl.synced-temp');
  await fsp.writeFile(temporary, 'backup');
  let renameCalled = false;

  await assert.rejects(
    publishSyncedTemporaryFileIfAbsent(temporary, destination, {
      link: async () => {
        const error = new Error('SMB hard links are unsupported');
        error.code = 'ENOTSUP';
        throw error;
      },
      rename: async (source, target) => {
        renameCalled = true;
        await fsp.writeFile(target, 'racer');
        return fsp.rename(source, target);
      },
    }),
    (error) => {
      assert.equal(error.code, 'ATOMIC_NO_REPLACE_UNSUPPORTED');
      assert.match(error.message, /atomic no-replace|unsupported/i);
      return true;
    },
  );

  assert.equal(renameCalled, false);
  assert.equal(await fsp.readFile(temporary, 'utf8'), 'backup');
  await assert.rejects(fsp.readFile(destination), { code: 'ENOENT' });
});

for (const unlinkCode of ['EPERM', 'EINVAL', 'EIO']) {
  test(`successful publication remains committed when temp unlink fails with ${unlinkCode}`, async (t) => {
    const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
    t.after(() => fsp.rm(root, { recursive: true, force: true }));
    const destination = path.join(root, 'session.jsonl');
    const temporary = path.join(root, '.session.jsonl.repair-orphan');
    await fsp.writeFile(temporary, 'backup');

    await publishSyncedTemporaryFileIfAbsent(temporary, destination, {
      unlink: async () => {
        const error = new Error(`injected unlink failure: ${unlinkCode}`);
        error.code = unlinkCode;
        throw error;
      },
    });

    assert.equal(await fsp.readFile(destination, 'utf8'), 'backup');
    assert.equal(await fsp.readFile(temporary, 'utf8'), 'backup');
  });
}

test('target appearing during an unsupported hard-link attempt is never overwritten', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'session.jsonl');
  const temporary = path.join(root, '.session.jsonl.synced-temp');
  await fsp.writeFile(temporary, 'backup');

  await assert.rejects(
    publishSyncedTemporaryFileIfAbsent(temporary, destination, {
      link: async () => {
        await fsp.writeFile(destination, 'racer');
        const error = new Error('SMB hard links are unsupported');
        error.code = 'ENOTSUP';
        throw error;
      },
    }),
    (error) => {
      assert.equal(error.code, 'ATOMIC_NO_REPLACE_UNSUPPORTED');
      return true;
    },
  );

  assert.equal(await fsp.readFile(destination, 'utf8'), 'racer');
  assert.equal(await fsp.readFile(temporary, 'utf8'), 'backup');
});

test('unsupported SMB no-replace publication preserves an existing destination', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'session.jsonl');
  await fsp.writeFile(destination, 'live');

  await assert.rejects(writeFileDurably(destination, 'backup', {
    link: async () => {
      const error = new Error('SMB hard links are unsupported');
      error.code = 'ENOTSUP';
      throw error;
    },
  }));

  assert.equal(await fsp.readFile(destination, 'utf8'), 'live');
});

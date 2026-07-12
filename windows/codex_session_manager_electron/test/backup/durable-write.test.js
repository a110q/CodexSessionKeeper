'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { replaceFileDurably, writeFileDurably } = require('../../src/backup/durable-write');

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

test('writeFileDurably falls back to atomic rename when SMB rejects hard links', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'durable-write-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'session.jsonl');
  let linkAttempts = 0;

  await writeFileDurably(destination, 'backup', {
    link: async () => {
      linkAttempts += 1;
      const error = new Error('SMB hard links are unsupported');
      error.code = 'ENOTSUP';
      throw error;
    },
  });

  assert.equal(linkAttempts, 1);
  assert.equal(await fsp.readFile(destination, 'utf8'), 'backup');
  assert.deepEqual(await fsp.readdir(root), ['session.jsonl']);
});

test('SMB fallback still refuses an existing destination', async (t) => {
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

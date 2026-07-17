'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { durableReplaceWithWriter } = require('../../src/backup/durable-write');
const {
  appendCompleteLines,
  rebuildCompleteLines,
  rangesMatch,
} = require('../../src/backup/session-backup-streamer');

const ONE_MIB = 1024 * 1024;

async function makeFixture(t, contents = Buffer.alloc(0)) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'session-backup-streamer-'));
  t.after(() => fs.rm(root, { force: true, recursive: true }));
  const sourcePath = path.join(root, 'source.jsonl');
  const targetPath = path.join(root, 'target.jsonl');
  await fs.writeFile(sourcePath, contents);
  return { root, sourcePath, targetPath };
}

function sha256(contents) {
  return crypto.createHash('sha256').update(contents).digest('hex');
}

async function withTrackedReadSizes(filePath, operation) {
  const originalOpen = fs.open;
  const readSizes = [];
  fs.open = async function (openedPath, ...args) {
    const handle = await originalOpen.call(fs, openedPath, ...args);
    if (path.resolve(String(openedPath)) === path.resolve(filePath)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (buffer, offset, length, position) => {
        readSizes.push(length);
        return originalRead(buffer, offset, length, position);
      };
    }
    return handle;
  };
  try {
    return { result: await operation(), readSizes };
  } finally {
    fs.open = originalOpen;
  }
}

async function withTrackedWriteSizes(targetPath, operation) {
  const originalOpen = fs.open;
  const writes = [];
  const targetDirectory = path.resolve(path.dirname(targetPath));
  const targetBasename = path.basename(targetPath);
  fs.open = async function (openedPath, ...args) {
    const handle = await originalOpen.call(fs, openedPath, ...args);
    const resolved = path.resolve(String(openedPath));
    const isTarget = resolved === path.resolve(targetPath)
      || (path.dirname(resolved) === targetDirectory
        && path.basename(resolved).startsWith(`.${targetBasename}.tmp-`));
    if (isTarget) {
      const originalWrite = handle.write.bind(handle);
      handle.write = async (buffer, offset, length, position) => {
        writes.push({ length, position });
        return originalWrite(buffer, offset, length, position);
      };
    }
    return handle;
  };
  try {
    return { result: await operation(), writes };
  } finally {
    fs.open = originalOpen;
  }
}

function manySmallRecords(minimumBytes) {
  const record = '{"type":"event_msg","payload":{"type":"user_message","message":"buffer me"}}\n';
  return Buffer.from(record.repeat(Math.ceil(minimumBytes / Buffer.byteLength(record))));
}

test('rebuild streams several chunks, excludes a partial record, and hashes committed bytes', async (t) => {
  const chunkSize = 7;
  const source = Buffer.from('a'.repeat(chunkSize * 4 + 3) + '\nsecond\npartial');
  const expected = source.subarray(0, source.length - Buffer.byteLength('partial'));
  const { sourcePath, targetPath } = await makeFixture(t, source);

  const { result, readSizes } = await withTrackedReadSizes(sourcePath, () => rebuildCompleteLines({
    sourcePath,
    targetPath,
    chunkSize,
  }));

  assert.equal(await fs.readFile(targetPath, 'utf8'), expected.toString());
  assert.deepEqual(result, {
    committedByteCount: expected.length,
    lineCount: 2,
    contentHash: sha256(expected),
  });
  assert.ok(readSizes.length > 3);
  assert.ok(readSizes.every((size) => size <= chunkSize));
});

test('rebuild batches many small records into one MiB writes', async (t) => {
  const source = manySmallRecords(ONE_MIB * 3 + 17);
  const { sourcePath, targetPath } = await makeFixture(t, source);

  const { writes } = await withTrackedWriteSizes(targetPath, () => rebuildCompleteLines({
    sourcePath,
    targetPath,
  }));

  assert.deepEqual(await fs.readFile(targetPath), source);
  assert.ok(writes.length <= Math.ceil(source.length / ONE_MIB));
  assert.ok(writes.every(({ length }) => length > 0 && length <= ONE_MIB));
});

test('append batches many small records into positioned one MiB writes', async (t) => {
  const prefix = Buffer.from('{"type":"event_msg","payload":{"message":"existing"}}\n');
  const appended = manySmallRecords(ONE_MIB * 2 + 17);
  const { sourcePath, targetPath } = await makeFixture(t, Buffer.concat([prefix, appended]));
  await fs.writeFile(targetPath, prefix);

  const { writes } = await withTrackedWriteSizes(targetPath, () => appendCompleteLines({
    sourcePath,
    sourceOffset: prefix.length,
    targetPath,
  }));

  assert.deepEqual(await fs.readFile(targetPath), Buffer.concat([prefix, appended]));
  assert.ok(writes.length <= Math.ceil(appended.length / ONE_MIB));
  assert.ok(writes.every(({ length }) => length > 0 && length <= ONE_MIB));
  assert.equal(writes[0].position, prefix.length);
});

test('rebuild accepts a legal 32 MiB line spanning bounded chunks', async (t) => {
  const maximumLineBytes = 32 * 1024 * 1024;
  const source = Buffer.concat([Buffer.alloc(maximumLineBytes, 0x78), Buffer.from('\n')]);
  const { sourcePath, targetPath } = await makeFixture(t, source);

  const result = await rebuildCompleteLines({
    sourcePath,
    targetPath,
    chunkSize: 1024 * 1024,
  });

  assert.equal((await fs.stat(targetPath)).size, source.length);
  assert.deepEqual(result, {
    committedByteCount: source.length,
    lineCount: 1,
    contentHash: sha256(source),
  });
});

test('rebuild stops at maximumOffset without committing its partial record', async (t) => {
  const { sourcePath, targetPath } = await makeFixture(t, Buffer.from('one\ntwo\nthree\n'));

  const result = await rebuildCompleteLines({
    sourcePath,
    targetPath,
    maximumOffset: 6,
    chunkSize: 3,
  });

  const expected = Buffer.from('one\n');
  assert.equal(await fs.readFile(targetPath, 'utf8'), expected.toString());
  assert.deepEqual(result, {
    committedByteCount: expected.length,
    lineCount: 1,
    contentHash: sha256(expected),
  });
});

test('rebuild creates an empty target with the canonical empty SHA-256', async (t) => {
  const { sourcePath, targetPath } = await makeFixture(t);

  const result = await rebuildCompleteLines({ sourcePath, targetPath, chunkSize: 4 });

  assert.equal((await fs.stat(targetPath)).size, 0);
  assert.deepEqual(result, {
    committedByteCount: 0,
    lineCount: 0,
    contentHash: sha256(Buffer.alloc(0)),
  });
});

test('rangesMatch compares only requested ranges with bounded reads', async (t) => {
  const { sourcePath, targetPath } = await makeFixture(t, Buffer.from('prefix-SAME-suffix'));
  await fs.writeFile(targetPath, 'other-SAME-tail');

  const { result: matching, readSizes } = await withTrackedReadSizes(sourcePath, () => rangesMatch({
    sourcePath,
    sourceOffset: 7,
    targetPath,
    targetOffset: 6,
    length: 4,
    chunkSize: 2,
  }));
  const mismatching = await rangesMatch({
    sourcePath,
    sourceOffset: 0,
    targetPath,
    targetOffset: 0,
    length: 6,
    chunkSize: 2,
  });

  assert.equal(matching, true);
  assert.equal(mismatching, false);
  assert.ok(readSizes.length >= 2);
  assert.ok(readSizes.every((size) => size <= 2));
});

test('failed streaming replacement preserves the old target and removes its temp file', async (t) => {
  const { root, targetPath } = await makeFixture(t);
  await fs.writeFile(targetPath, 'committed');

  await assert.rejects(
    durableReplaceWithWriter(targetPath, async (handle) => {
      await handle.writeFile('uncommitted');
      throw new Error('injected writer failure');
    }),
    /injected writer failure/,
  );

  assert.equal(await fs.readFile(targetPath, 'utf8'), 'committed');
  assert.deepEqual((await fs.readdir(root)).sort(), ['source.jsonl', 'target.jsonl']);
});

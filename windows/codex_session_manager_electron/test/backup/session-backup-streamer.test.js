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
  rebuildSessionCompleteLines,
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
  const readBuffers = [];
  fs.open = async function (openedPath, ...args) {
    const handle = await originalOpen.call(fs, openedPath, ...args);
    if (path.resolve(String(openedPath)) === path.resolve(filePath)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (buffer, offset, length, position) => {
        readSizes.push(length);
        readBuffers.push(buffer);
        return originalRead(buffer, offset, length, position);
      };
    }
    return handle;
  };
  try {
    return { result: await operation(), readSizes, readBuffers };
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

async function withTrackedBufferConcats(operation) {
  const originalConcat = Buffer.concat;
  let concatCalls = 0;
  Buffer.concat = function (...args) {
    concatCalls += 1;
    return originalConcat.apply(Buffer, args);
  };
  try {
    return { result: await operation(), concatCalls };
  } finally {
    Buffer.concat = originalConcat;
  }
}

async function withTrackedUnsafeAllocations(operation) {
  const originalAllocUnsafe = Buffer.allocUnsafe;
  const allocationSizes = [];
  Buffer.allocUnsafe = function (size, ...args) {
    allocationSizes.push(size);
    return originalAllocUnsafe.call(Buffer, size, ...args);
  };
  try {
    return { result: await operation(), allocationSizes };
  } finally {
    Buffer.allocUnsafe = originalAllocUnsafe;
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

test('rebuild reuses one scanner buffer independent of chunk count', async (t) => {
  const source = Buffer.from(Array.from(
    { length: 80 },
    (_, index) => `${JSON.stringify({ index, value: 'crosses reads' })}\n`,
  ).join(''));
  const { sourcePath, targetPath } = await makeFixture(t, source);

  const { readBuffers } = await withTrackedReadSizes(sourcePath, () => rebuildCompleteLines({
    sourcePath,
    targetPath,
    chunkSize: 7,
  }));

  assert.ok(readBuffers.length > 40);
  assert.equal(new Set(readBuffers).size, 1);
  assert.deepEqual(await fs.readFile(targetPath), source);
});

test('rebuild uses one spanning-line accumulator without a full-line concat', async (t) => {
  const source = Buffer.from(`${JSON.stringify({ value: 'x'.repeat(80) })}\n`);
  const { sourcePath, targetPath } = await makeFixture(t, source);

  const { result, concatCalls } = await withTrackedBufferConcats(() => rebuildCompleteLines({
    sourcePath,
    targetPath,
    chunkSize: 7,
    maxLineBytes: source.length - 1,
  }));

  assert.equal(result.lineCount, 1);
  assert.equal(concatCalls, 0);
  assert.deepEqual(await fs.readFile(targetPath), source);
});

test('a short partial tail does not reserve the full 64 MiB line budget', async (t) => {
  const { sourcePath, targetPath } = await makeFixture(t, Buffer.from('partial'));
  const maximumLineBytes = 64 * 1024 * 1024;

  const { result, allocationSizes } = await withTrackedUnsafeAllocations(() => rebuildSessionCompleteLines({
    sourcePath,
    targetPath,
    chunkSize: 3,
    maxLineBytes: maximumLineBytes,
  }));

  assert.equal(result.pendingPartialLine, 'partial');
  assert.equal(allocationSizes.includes(maximumLineBytes), false);
});

test('rebuild accepts exact maxLineBytes and blocks max plus one', async (t) => {
  const exactLine = Buffer.from('"123456"');
  const exact = await makeFixture(t, Buffer.concat([exactLine, Buffer.from('\n')]));
  const exactResult = await rebuildSessionCompleteLines({
    sourcePath: exact.sourcePath,
    targetPath: exact.targetPath,
    chunkSize: 3,
    maxLineBytes: exactLine.length,
  });
  assert.equal(exactResult.lineCount, 1);
  assert.equal(exactResult.blockedError, null);

  const overRoot = path.join(exact.root, 'over');
  await fs.mkdir(overRoot);
  const overSource = path.join(overRoot, 'source.jsonl');
  const overTarget = path.join(overRoot, 'target.jsonl');
  await fs.writeFile(overSource, '"1234567"\n');
  const overResult = await rebuildSessionCompleteLines({
    sourcePath: overSource,
    targetPath: overTarget,
    chunkSize: 3,
    maxLineBytes: exactLine.length,
  });
  assert.equal(overResult.lineCount, 0);
  assert.match(overResult.blockedError, /maximum JSONL line size of 8 bytes/);
  assert.equal((await fs.stat(overTarget)).size, 0);
});

test('title scan skips oversized records without changing streamed backup bytes', async (t) => {
  const oversized = Buffer.from(`${JSON.stringify({
    role: 'user',
    content: `oversized title ${'x'.repeat(128 * 1024)}`,
  })}\n`);
  const { sourcePath, targetPath } = await makeFixture(t, oversized);

  const result = await rebuildSessionCompleteLines({
    sourcePath,
    targetPath,
    chunkSize: 4096,
  });

  assert.equal(result.firstTitle, null);
  assert.equal(result.lineCount, 1);
  assert.deepEqual(await fs.readFile(targetPath), oversized);
});

test('title scan remains bounded by record count and parsed bytes', async (t) => {
  const manyRecords = Buffer.from([
    ...Array.from({ length: 300 }, (_, index) => JSON.stringify({ role: 'assistant', content: `record ${index}` })),
    JSON.stringify({ role: 'user', content: 'past record budget' }),
    '',
  ].join('\n'));
  const parsedByteBudget = Buffer.from([
    ...Array.from({ length: 5 }, () => JSON.stringify({ role: 'assistant', content: 'x'.repeat(60 * 1024) })),
    JSON.stringify({ role: 'user', content: 'past byte budget' }),
    '',
  ].join('\n'));
  const first = await makeFixture(t, manyRecords);
  const secondRoot = path.join(first.root, 'second');
  await fs.mkdir(secondRoot);
  const second = {
    sourcePath: path.join(secondRoot, 'source.jsonl'),
    targetPath: path.join(secondRoot, 'target.jsonl'),
  };
  await fs.writeFile(second.sourcePath, parsedByteBudget);

  const [recordLimited, byteLimited] = await Promise.all([
    rebuildSessionCompleteLines({ sourcePath: first.sourcePath, targetPath: first.targetPath }),
    rebuildSessionCompleteLines({ sourcePath: second.sourcePath, targetPath: second.targetPath }),
  ]);

  assert.equal(recordLimited.firstTitle, null);
  assert.equal(byteLimited.firstTitle, null);
  assert.deepEqual(await fs.readFile(first.targetPath), manyRecords);
  assert.deepEqual(await fs.readFile(second.targetPath), parsedByteBudget);
});

test('an oversized non-title record does not consume the parsed-byte title budget', async (t) => {
  const source = Buffer.from([
    JSON.stringify({ role: 'assistant', content: 'x'.repeat(128 * 1024) }),
    JSON.stringify({ role: 'user', content: 'small title after oversized assistant' }),
    '',
  ].join('\n'));
  const { sourcePath, targetPath } = await makeFixture(t, source);

  const result = await rebuildSessionCompleteLines({ sourcePath, targetPath, chunkSize: 4096 });

  assert.equal(result.firstTitle, 'small title after oversized assistant');
  assert.deepEqual(await fs.readFile(targetPath), source);
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

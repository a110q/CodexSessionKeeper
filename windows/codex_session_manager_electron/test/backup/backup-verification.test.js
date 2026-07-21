'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  BackupFileVerificationError,
  verifyAppendSourceAnchors,
  verifyChangedBackupChunks,
  verifyFullBackupFile,
} = require('../../src/backup/backup-file-verifier');
const {
  ISOLATED_VERIFICATION_THRESHOLD_BYTES,
} = require('../../src/backup/isolated-backup-verifier');
const {
  emptyVerificationDocument,
  loadVerification,
  saveVerification,
} = require('../../src/backup/verification-store');

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function jsonStringRecord(totalBytes) {
  const record = Buffer.alloc(totalBytes, 0x78);
  record[0] = 0x22;
  record[totalBytes - 2] = 0x22;
  record[totalBytes - 1] = 0x0A;
  return record;
}

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'backup-verification-'));
  t.after(() => fs.rm(root, { force: true, recursive: true }));
  return root;
}

async function withTrackedReadBuffers(filePaths, operation) {
  const trackedPaths = new Set(filePaths.map((filePath) => path.resolve(filePath)));
  const originalOpen = fs.open;
  const readsByPath = new Map([...trackedPaths].map((filePath) => [filePath, []]));
  fs.open = async function (openedPath, ...args) {
    const handle = await originalOpen.call(fs, openedPath, ...args);
    const resolvedPath = path.resolve(String(openedPath));
    if (trackedPaths.has(resolvedPath)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (buffer, offset, length, position) => {
        readsByPath.get(resolvedPath).push(buffer);
        return originalRead(buffer, offset, length, position);
      };
    }
    return handle;
  };
  try {
    return { result: await operation(), readsByPath };
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

test('verification store round trips and missing store loads an empty document', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'verification.json');
  assert.deepEqual(await loadVerification(filePath), emptyVerificationDocument());
  const document = {
    version: 1,
    algorithm: 'sha256-chunks-v1',
    chunkSize: 4 * 1024 * 1024,
    sessions: {
      session: {
        backupPath: 'sessions/session.jsonl',
        byteCount: 8,
        lineCount: 1,
        chunkHashes: [sha256(Buffer.from('{"a":1}\n'))],
        verifiedAt: '2026-07-15T00:00:00.000Z',
      },
    },
  };

  await saveVerification(filePath, document);

  assert.deepEqual(await loadVerification(filePath), document);
});

test('full verification checks JSONL, length, full hash, and fixed chunks', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'session.jsonl');
  const data = Buffer.from('{"a":1}\n{"b":2}\n');
  await fs.writeFile(filePath, data);

  const result = await verifyFullBackupFile({
    filePath,
    chunkSize: 8,
    maxLineBytes: 64,
    expectedByteCount: data.length,
    expectedLineCount: 2,
    expectedContentHash: sha256(data),
  });

  assert.deepEqual(result, {
    byteCount: data.length,
    lineCount: 2,
    contentHash: sha256(data),
    chunkHashes: [sha256(data.subarray(0, 8)), sha256(data.subarray(8, 16))],
  });
});

test('full verification reuses one scratch buffer across every chunk read', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'bounded-full.jsonl');
  const data = Buffer.from(Array.from(
    { length: 40 },
    (_, index) => `${JSON.stringify({ index, value: 'spans chunks' })}\n`,
  ).join(''));
  await fs.writeFile(filePath, data);

  const { result, readsByPath } = await withTrackedReadBuffers([filePath], () => verifyFullBackupFile({
    filePath,
    chunkSize: 7,
    maxLineBytes: 128,
  }));
  const reads = readsByPath.get(path.resolve(filePath));

  assert.equal(result.lineCount, 40);
  assert.ok(reads.length > 20);
  assert.equal(new Set(reads).size, 1);
});

test('full verification uses one spanning-line accumulator without a full-line concat', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'single-accumulator.jsonl');
  const data = Buffer.from(`${JSON.stringify({ value: 'x'.repeat(80) })}\n`);
  await fs.writeFile(filePath, data);

  const { result, concatCalls } = await withTrackedBufferConcats(() => verifyFullBackupFile({
    filePath,
    chunkSize: 7,
    maxLineBytes: data.length - 1,
  }));

  assert.equal(result.lineCount, 1);
  assert.equal(concatCalls, 0);
});

test('full verification isolates exactly 8 MiB while keeping smaller files in process', async (t) => {
  const root = await fixture(t);
  const belowPath = path.join(root, 'below-threshold.jsonl');
  const exactPath = path.join(root, 'exact-threshold.jsonl');
  const below = jsonStringRecord(ISOLATED_VERIFICATION_THRESHOLD_BYTES - 1);
  const exact = jsonStringRecord(ISOLATED_VERIFICATION_THRESHOLD_BYTES);
  await fs.writeFile(belowPath, below);
  await fs.writeFile(exactPath, exact);
  const calls = [];
  const isolationRunner = async (request) => {
    calls.push(request);
    return {
      byteCount: exact.length,
      lineCount: 1,
      contentHash: sha256(exact),
      chunkHashes: [],
    };
  };

  const belowResult = await verifyFullBackupFile({
    filePath: belowPath,
    isolationRunner,
  });
  assert.equal(belowResult.byteCount, below.length);
  assert.equal(calls.length, 0);

  const exactResult = await verifyFullBackupFile({
    filePath: exactPath,
    isolationRunner,
  });
  assert.equal(exactResult.byteCount, exact.length);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].operation, 'verifyFull');
  assert.equal(calls[0].payload.filePath, exactPath);
  assert.equal('isolationRunner' in calls[0].payload, false);
});

test('large isolated JSON failure remains a BackupFileVerificationError', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'invalid-large.jsonl');
  const invalid = Buffer.alloc(ISOLATED_VERIFICATION_THRESHOLD_BYTES, 0x78);
  invalid[invalid.length - 1] = 0x0A;
  await fs.writeFile(filePath, invalid);

  await assert.rejects(
    verifyFullBackupFile({ filePath }),
    BackupFileVerificationError,
  );
});

test('full verification accepts exact maxLineBytes and rejects max plus one', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'exact-line-limit.jsonl');
  const exactLine = Buffer.from('"123456"');
  await fs.writeFile(filePath, Buffer.concat([exactLine, Buffer.from('\n')]));

  const exact = await verifyFullBackupFile({ filePath, chunkSize: 3, maxLineBytes: exactLine.length });
  assert.equal(exact.lineCount, 1);

  await fs.writeFile(filePath, Buffer.concat([Buffer.from('"1234567"'), Buffer.from('\n')]));
  await assert.rejects(
    verifyFullBackupFile({ filePath, chunkSize: 3, maxLineBytes: exactLine.length }),
    /exceeds 8 bytes/,
  );
});

test('full verification rejects same-size corruption and malformed JSONL', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'session.jsonl');
  const expected = Buffer.from('{"a":1}\n');
  await fs.writeFile(filePath, '{"a":2}\n');

  await assert.rejects(
    verifyFullBackupFile({
      filePath,
      chunkSize: 4,
      maxLineBytes: 64,
      expectedByteCount: expected.length,
      expectedLineCount: 1,
      expectedContentHash: sha256(expected),
    }),
    BackupFileVerificationError,
  );

  await fs.writeFile(filePath, '{not-json}\n');
  await assert.rejects(verifyFullBackupFile({ filePath, chunkSize: 4, maxLineBytes: 64 }), BackupFileVerificationError);
  await fs.writeFile(filePath, '{"a":1}');
  await assert.rejects(verifyFullBackupFile({ filePath, chunkSize: 4, maxLineBytes: 64 }), BackupFileVerificationError);
});

test('changed verification rehashes affected chunks and rejects mismatches', async (t) => {
  const root = await fixture(t);
  const sourcePath = path.join(root, 'source.jsonl');
  const targetPath = path.join(root, 'target.jsonl');
  const original = Buffer.from('{"a":1}\n');
  const complete = Buffer.concat([original, Buffer.from('{"b":2}\n')]);
  await fs.writeFile(sourcePath, complete);
  await fs.writeFile(targetPath, complete);
  const previous = {
    backupPath: 'sessions/session.jsonl',
    byteCount: original.length,
    lineCount: 1,
    chunkHashes: [sha256(original)],
    verifiedAt: '2026-07-15T00:00:00.000Z',
  };

  const updated = await verifyChangedBackupChunks({
    sourcePath,
    targetPath,
    previous,
    backupPath: previous.backupPath,
    committedByteCount: complete.length,
    lineCount: 2,
    verifiedAt: '2026-07-15T00:01:00.000Z',
    chunkSize: 8,
  });
  assert.deepEqual(updated.chunkHashes, [sha256(complete.subarray(0, 8)), sha256(complete.subarray(8, 16))]);

  const corrupt = Buffer.from(complete);
  corrupt[corrupt.length - 1] = 0x20;
  await fs.writeFile(targetPath, corrupt);
  await assert.rejects(
    verifyChangedBackupChunks({
      sourcePath,
      targetPath,
      previous,
      backupPath: previous.backupPath,
      committedByteCount: complete.length,
      lineCount: 2,
      verifiedAt: '2026-07-15T00:01:00.000Z',
      chunkSize: 8,
    }),
    BackupFileVerificationError,
  );
});

test('changed verification reuses exactly one source and one target scratch buffer', async (t) => {
  const root = await fixture(t);
  const sourcePath = path.join(root, 'bounded-source.jsonl');
  const targetPath = path.join(root, 'bounded-target.jsonl');
  const original = Buffer.from('{"a":1}\n');
  const appended = Buffer.from(Array.from(
    { length: 40 },
    (_, index) => `${JSON.stringify({ index, value: 'changed chunks' })}\n`,
  ).join(''));
  const complete = Buffer.concat([original, appended]);
  await fs.writeFile(sourcePath, complete);
  await fs.writeFile(targetPath, complete);
  const previous = {
    backupPath: 'sessions/bounded.jsonl',
    byteCount: original.length,
    lineCount: 1,
    chunkHashes: [sha256(original)],
    verifiedAt: '2026-07-15T00:00:00.000Z',
  };

  const { result, readsByPath } = await withTrackedReadBuffers(
    [sourcePath, targetPath],
    () => verifyChangedBackupChunks({
      sourcePath,
      targetPath,
      previous,
      backupPath: previous.backupPath,
      committedByteCount: complete.length,
      lineCount: 41,
      verifiedAt: '2026-07-15T00:01:00.000Z',
      chunkSize: original.length,
      maxLineBytes: 128,
    }),
  );
  const sourceReads = readsByPath.get(path.resolve(sourcePath));
  const targetReads = readsByPath.get(path.resolve(targetPath));

  assert.equal(result.lineCount, 41);
  assert.ok(sourceReads.length > 20);
  assert.equal(new Set(sourceReads).size, 1);
  assert.equal(new Set(targetReads).size, 1);
  assert.equal(new Set([...sourceReads, ...targetReads]).size, 2);
});

test('changed verification isolates an exact 8 MiB changed range but not one byte less', async (t) => {
  const root = await fixture(t);
  const belowSourcePath = path.join(root, 'below-source.jsonl');
  const belowTargetPath = path.join(root, 'below-target.jsonl');
  const exactSourcePath = path.join(root, 'exact-source.jsonl');
  const exactTargetPath = path.join(root, 'exact-target.jsonl');
  const below = jsonStringRecord(ISOLATED_VERIFICATION_THRESHOLD_BYTES - 1);
  const exact = jsonStringRecord(ISOLATED_VERIFICATION_THRESHOLD_BYTES);
  await Promise.all([
    fs.writeFile(belowSourcePath, below),
    fs.writeFile(belowTargetPath, below),
    fs.writeFile(exactSourcePath, exact),
    fs.writeFile(exactTargetPath, exact),
  ]);
  const previous = {
    backupPath: 'sessions/threshold.jsonl',
    byteCount: 0,
    lineCount: 0,
    chunkHashes: [],
    verifiedAt: '2026-07-15T00:00:00.000Z',
  };
  const calls = [];
  const isolatedResult = {
    backupPath: previous.backupPath,
    byteCount: exact.length,
    lineCount: 1,
    chunkHashes: [],
    verifiedAt: '2026-07-15T00:01:00.000Z',
  };
  const isolationRunner = async (request) => {
    calls.push(request);
    return isolatedResult;
  };

  const belowResult = await verifyChangedBackupChunks({
    sourcePath: belowSourcePath,
    targetPath: belowTargetPath,
    previous,
    backupPath: previous.backupPath,
    committedByteCount: below.length,
    lineCount: 1,
    verifiedAt: isolatedResult.verifiedAt,
    isolationRunner,
  });
  assert.equal(belowResult.byteCount, below.length);
  assert.equal(calls.length, 0);

  const exactResult = await verifyChangedBackupChunks({
    sourcePath: exactSourcePath,
    targetPath: exactTargetPath,
    previous,
    backupPath: previous.backupPath,
    committedByteCount: exact.length,
    lineCount: 1,
    verifiedAt: isolatedResult.verifiedAt,
    isolationRunner,
  });
  assert.deepEqual(exactResult, isolatedResult);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].operation, 'verifyChangedChunks');
});

test('empty and exact four MiB boundary files produce canonical chunks', async (t) => {
  const root = await fixture(t);
  const emptyPath = path.join(root, 'empty.jsonl');
  await fs.writeFile(emptyPath, Buffer.alloc(0));
  const empty = await verifyFullBackupFile({ filePath: emptyPath, expectedByteCount: 0, expectedLineCount: 0 });
  assert.deepEqual(empty.chunkHashes, []);
  assert.equal(empty.contentHash, sha256(Buffer.alloc(0)));

  const chunkSize = 4 * 1024 * 1024;
  const boundary = Buffer.concat([
    Buffer.from('"'),
    Buffer.alloc(chunkSize - 3, 0x61),
    Buffer.from('"\n'),
  ]);
  const appended = Buffer.from('{}\n');
  const sourcePath = path.join(root, 'boundary-source.jsonl');
  const targetPath = path.join(root, 'boundary-target.jsonl');
  await fs.writeFile(sourcePath, boundary);
  await fs.writeFile(targetPath, boundary);
  const initial = await verifyFullBackupFile({
    filePath: sourcePath,
    expectedByteCount: chunkSize,
    expectedLineCount: 1,
  });
  assert.deepEqual(initial.chunkHashes, [sha256(boundary)]);
  await fs.appendFile(sourcePath, appended);
  await fs.appendFile(targetPath, appended);

  const updated = await verifyChangedBackupChunks({
    sourcePath,
    targetPath,
    previous: {
      backupPath: 'sessions/boundary.jsonl',
      byteCount: chunkSize,
      lineCount: 1,
      chunkHashes: initial.chunkHashes,
      verifiedAt: '2026-07-15T00:00:00.000Z',
    },
    backupPath: 'sessions/boundary.jsonl',
    committedByteCount: chunkSize + appended.length,
    lineCount: 2,
    verifiedAt: '2026-07-15T00:01:00.000Z',
    chunkSize,
  });

  assert.deepEqual(updated.chunkHashes, [sha256(boundary), sha256(appended)]);
});

test('append source anchors read only the unique first, lower-middle, and last old chunks', async (t) => {
  const root = await fixture(t);
  const sourcePath = path.join(root, 'source-anchors.jsonl');
  const chunkSize = 16;
  const chunks = [0, 1, 2, 3, 4].map((index) => Buffer.alloc(chunkSize, 0x61 + index));
  const tail = Buffer.from('tail');
  const previousData = Buffer.concat([...chunks, tail]);
  await fs.writeFile(sourcePath, Buffer.concat([previousData, Buffer.from('growth') ]));
  const reads = [];

  assert.equal(await verifyAppendSourceAnchors({
    sourcePath,
    previous: {
      byteCount: previousData.length,
      chunkHashes: [...chunks.map(sha256), sha256(tail)],
    },
    chunkSize,
    onRead: (read) => reads.push(read),
  }), true);

  assert.deepEqual(reads.map(({ chunkIndex, byteCount }) => [chunkIndex, byteCount]), [
    [0, chunkSize],
    [2, chunkSize],
    [5, tail.length],
  ]);
  assert.ok(reads.reduce((sum, read) => sum + read.byteCount, 0) <= 3 * chunkSize);
});

test('append source anchors detect mismatches and handle empty and short prefixes', async (t) => {
  const root = await fixture(t);
  const sourcePath = path.join(root, 'source-short-anchors.jsonl');
  const chunkSize = 8;
  const first = Buffer.alloc(chunkSize, 0x61);
  const second = Buffer.from('tail');
  await fs.writeFile(sourcePath, Buffer.concat([first, second, Buffer.from('growth')]));
  const previous = {
    byteCount: first.length + second.length,
    chunkHashes: [sha256(first), sha256(second)],
  };
  const reads = [];

  assert.equal(await verifyAppendSourceAnchors({
    sourcePath,
    previous,
    chunkSize,
    onRead: (read) => reads.push(read),
  }), true);
  assert.deepEqual(reads.map(({ chunkIndex }) => chunkIndex), [0, 1]);

  const changed = await fs.readFile(sourcePath);
  changed[0] ^= 0x01;
  await fs.writeFile(sourcePath, changed);
  assert.equal(await verifyAppendSourceAnchors({ sourcePath, previous, chunkSize }), false);

  let emptyReads = 0;
  assert.equal(await verifyAppendSourceAnchors({
    sourcePath,
    previous: { byteCount: 0, chunkHashes: [] },
    chunkSize,
    onRead: () => { emptyReads += 1; },
  }), true);
  assert.equal(emptyReads, 0);
});

test('append source anchors reject malformed verification state', async (t) => {
  const root = await fixture(t);
  const sourcePath = path.join(root, 'source-malformed-anchors.jsonl');
  await fs.writeFile(sourcePath, Buffer.alloc(32));
  const malformed = [
    null,
    { byteCount: -1, chunkHashes: [] },
    { byteCount: 1.5, chunkHashes: [sha256(Buffer.from('x'))] },
    { byteCount: 9, chunkHashes: [sha256(Buffer.alloc(8))] },
    { byteCount: 8, chunkHashes: ['not-a-hash'] },
  ];

  for (const previous of malformed) {
    await assert.rejects(
      verifyAppendSourceAnchors({ sourcePath, previous, chunkSize: 8 }),
      BackupFileVerificationError,
    );
  }
});

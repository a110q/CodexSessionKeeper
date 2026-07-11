const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  copyRestoreEntry,
  mergeRestoreDirectory,
  validateRestoreFilesystem,
} = require('../../src/backup/restore-filesystem');

async function fixture(t) {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'restore-filesystem-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const sourceRoot = path.join(root, 'snapshot', 'data');
  const destinationRoot = path.join(root, 'codex');
  await fsp.mkdir(sourceRoot, { recursive: true });
  await fsp.mkdir(destinationRoot, { recursive: true });
  return { root, sourceRoot, destinationRoot };
}

test('restore filesystem accepts regular source trees and destinations', async (t) => {
  const { sourceRoot, destinationRoot } = await fixture(t);
  const sourcePath = path.join(sourceRoot, 'sessions');
  const destinationPath = path.join(destinationRoot, 'sessions');
  await fsp.mkdir(sourcePath, { recursive: true });
  await fsp.writeFile(path.join(sourcePath, 'session.jsonl'), '{}\n');

  assert.doesNotThrow(() => validateRestoreFilesystem({
    restorePaths: [{ relativePath: 'sessions', sourcePath, destinationPath }],
    sourceRoot,
    destinationRoot,
  }));

  copyRestoreEntry({ sourcePath, destinationPath, sourceRoot, destinationRoot });
  assert.equal(await fsp.readFile(path.join(destinationPath, 'session.jsonl'), 'utf8'), '{}\n');
});

test('restore filesystem rejects source file and directory symlinks', async (t) => {
  const { root, sourceRoot, destinationRoot } = await fixture(t);
  const outside = path.join(root, 'outside');
  await fsp.mkdir(outside, { recursive: true });
  await fsp.writeFile(path.join(outside, 'secret.jsonl'), 'secret\n');

  for (const [name, target, type] of [
    ['file-link.jsonl', path.join(outside, 'secret.jsonl'), 'file'],
    ['directory-link', outside, process.platform === 'win32' ? 'junction' : 'dir'],
  ]) {
    const sourcePath = path.join(sourceRoot, name);
    await fsp.symlink(target, sourcePath, type);
    assert.throws(() => validateRestoreFilesystem({
      restorePaths: [{ relativePath: name, sourcePath, destinationPath: path.join(destinationRoot, name) }],
      sourceRoot,
      destinationRoot,
    }), (error) => error.code === 'INVALID_SNAPSHOT_PATH');
  }
});

test('restore filesystem rejects contained and dangling source links', async (t) => {
  const { sourceRoot, destinationRoot } = await fixture(t);
  const containedTarget = path.join(sourceRoot, 'target.jsonl');
  await fsp.writeFile(containedTarget, 'target\n');

  for (const [name, target] of [
    ['contained-link.jsonl', containedTarget],
    ['dangling-link.jsonl', path.join(sourceRoot, 'missing.jsonl')],
  ]) {
    const sourcePath = path.join(sourceRoot, name);
    await fsp.symlink(target, sourcePath, 'file');
    assert.throws(() => validateRestoreFilesystem({
      restorePaths: [{ relativePath: name, sourcePath, destinationPath: path.join(destinationRoot, name) }],
      sourceRoot,
      destinationRoot,
    }), (error) => error.code === 'INVALID_SNAPSHOT_PATH');
  }
});

test('restore filesystem rejects linked trust roots', async (t) => {
  const { root } = await fixture(t);
  const actualSourceRoot = path.join(root, 'actual-source');
  const actualDestinationRoot = path.join(root, 'actual-destination');
  const linkedSourceRoot = path.join(root, 'linked-source');
  const linkedDestinationRoot = path.join(root, 'linked-destination');
  await fsp.mkdir(actualSourceRoot);
  await fsp.mkdir(actualDestinationRoot);
  await fsp.writeFile(path.join(actualSourceRoot, 'session.jsonl'), '{}\n');
  const directoryLinkType = process.platform === 'win32' ? 'junction' : 'dir';
  await fsp.symlink(actualSourceRoot, linkedSourceRoot, directoryLinkType);
  await fsp.symlink(actualDestinationRoot, linkedDestinationRoot, directoryLinkType);

  assert.throws(() => validateRestoreFilesystem({
    restorePaths: [{
      relativePath: 'session.jsonl',
      sourcePath: path.join(linkedSourceRoot, 'session.jsonl'),
      destinationPath: path.join(actualDestinationRoot, 'session.jsonl'),
    }],
    sourceRoot: linkedSourceRoot,
    destinationRoot: actualDestinationRoot,
  }), (error) => error.code === 'INVALID_SNAPSHOT_PATH');

  assert.throws(() => validateRestoreFilesystem({
    restorePaths: [{
      relativePath: 'session.jsonl',
      sourcePath: path.join(actualSourceRoot, 'session.jsonl'),
      destinationPath: path.join(linkedDestinationRoot, 'session.jsonl'),
    }],
    sourceRoot: actualSourceRoot,
    destinationRoot: linkedDestinationRoot,
  }), (error) => error.code === 'INVALID_SNAPSHOT_PATH');
});

test('restore filesystem rejects destination symlinks before external writes', async (t) => {
  const { root, sourceRoot, destinationRoot } = await fixture(t);
  const sourcePath = path.join(sourceRoot, 'sessions');
  const outside = path.join(root, 'outside');
  const linkedDestination = path.join(destinationRoot, 'sessions');
  await fsp.mkdir(sourcePath, { recursive: true });
  await fsp.mkdir(outside, { recursive: true });
  await fsp.writeFile(path.join(sourcePath, 'victim.jsonl'), 'snapshot\n');
  await fsp.writeFile(path.join(outside, 'victim.jsonl'), 'outside\n');
  await fsp.symlink(outside, linkedDestination, process.platform === 'win32' ? 'junction' : 'dir');

  assert.throws(() => mergeRestoreDirectory({
    sourcePath,
    destinationPath: linkedDestination,
    sourceRoot,
    destinationRoot,
  }), (error) => error.code === 'INVALID_SNAPSHOT_PATH');
  assert.equal(await fsp.readFile(path.join(outside, 'victim.jsonl'), 'utf8'), 'outside\n');
});

test('restore filesystem rejects the whole preflight list when one tree is unsafe', async (t) => {
  const { root, sourceRoot, destinationRoot } = await fixture(t);
  const safeSource = path.join(sourceRoot, 'safe.jsonl');
  const unsafeSource = path.join(sourceRoot, 'unsafe.jsonl');
  const outside = path.join(root, 'outside.jsonl');
  await fsp.writeFile(safeSource, 'safe\n');
  await fsp.writeFile(outside, 'outside\n');
  await fsp.symlink(outside, unsafeSource);

  assert.throws(() => validateRestoreFilesystem({
    restorePaths: [
      { relativePath: 'safe.jsonl', sourcePath: safeSource, destinationPath: path.join(destinationRoot, 'safe.jsonl') },
      { relativePath: 'unsafe.jsonl', sourcePath: unsafeSource, destinationPath: path.join(destinationRoot, 'unsafe.jsonl') },
    ],
    sourceRoot,
    destinationRoot,
  }), (error) => error.code === 'INVALID_SNAPSHOT_PATH');
  assert.equal(fs.existsSync(path.join(destinationRoot, 'safe.jsonl')), false);
});

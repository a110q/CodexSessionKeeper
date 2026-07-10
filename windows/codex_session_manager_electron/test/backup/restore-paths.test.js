const assert = require('node:assert/strict');
const test = require('node:test');

const {
  InvalidRestorePathError,
  validateRestorePaths,
} = require('../../src/backup/restore-paths');

const sourceRoot = 'C:\\vault\\snapshots\\snapshot-1\\data';
const destinationRoot = 'C:\\Users\\Ada\\.codex';

test('validateRestorePaths accepts top-level and nested relative paths', () => {
  const paths = validateRestorePaths({
    includedPaths: ['state_5.sqlite', 'sessions/recovered/session-1.jsonl'],
    sourceRoot,
    destinationRoot,
  });

  assert.deepEqual(paths.map((item) => item.relativePath), [
    'state_5.sqlite',
    'sessions/recovered/session-1.jsonl',
  ]);
  assert.equal(paths[0].sourcePath, 'C:\\vault\\snapshots\\snapshot-1\\data\\state_5.sqlite');
  assert.equal(paths[1].destinationPath, 'C:\\Users\\Ada\\.codex\\sessions\\recovered\\session-1.jsonl');
  assert.equal(Object.isFrozen(paths), true);
  assert.equal(Object.isFrozen(paths[0]), true);
});

for (const relativePath of [
  '',
  '.',
  'sessions/./session-1.jsonl',
  'sessions//session-1.jsonl',
  '../../outside.txt',
  'sessions/../../../outside.txt',
  'sessions\\..\\..\\outside.txt',
  '/tmp/outside.txt',
  'C:\\Users\\Ada\\outside.txt',
  'C:outside.txt',
  '\\\\server\\share\\outside.txt',
  'sessions/\0outside.txt',
  null,
  42,
]) {
  test(`validateRestorePaths rejects unsafe path ${JSON.stringify(relativePath)}`, () => {
    assert.throws(
      () => validateRestorePaths({
        includedPaths: [relativePath],
        sourceRoot,
        destinationRoot,
      }),
      (error) => error instanceof InvalidRestorePathError
        && error.code === 'INVALID_SNAPSHOT_PATH'
    );
  });
}

test('validateRestorePaths rejects the whole list when one path is unsafe', () => {
  assert.throws(
    () => validateRestorePaths({
      includedPaths: ['sessions', '../../outside.txt', 'history.jsonl'],
      sourceRoot,
      destinationRoot,
    }),
    InvalidRestorePathError
  );
});

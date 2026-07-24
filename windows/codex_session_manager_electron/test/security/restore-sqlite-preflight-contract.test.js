'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const mainSource = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'main.js'), 'utf8');

function handler(channel, nextChannel) {
  const start = mainSource.indexOf(`handleTrustedIpc('${channel}'`);
  const end = mainSource.indexOf(`handleTrustedIpc('${nextChannel}'`, start + 1);
  assert.ok(start >= 0 && end > start, `handler slice must exist: ${channel}`);
  return mainSource.slice(start, end);
}

for (const [channel, nextChannel] of [
  ['restore-snapshot-conversations', 'restore-snapshot-full'],
  ['restore-snapshot-session', 'restore-snapshot-sessions'],
  ['restore-snapshot-sessions', 'restore-incremental-backup-sessions'],
  ['restore-session', 'delete-session'],
]) {
  test(`${channel} checks SQLite conflicts before creating a protection snapshot`, () => {
    const source = handler(channel, nextChannel);
    const preflight = source.indexOf('preflightSnapshotStateDatabaseMerge');
    const protection = source.indexOf('createRestoreProtectionSnapshot');
    assert.ok(preflight >= 0, `${channel} must preflight SQLite`);
    assert.ok(protection > preflight, `${channel} must preflight before protection side effects`);
  });
}

test('snapshot restores pass trusted rollout paths into the SQLite transaction', () => {
  assert.match(mainSource, /function rolloutPathUpdatesFromRestorePlan\(/);
  assert.match(mainSource, /mergeStateDatabase\([\s\S]{0,220}rolloutPathUpdatesFromRestorePlan\(/);
  assert.match(mainSource, /replaceLiveStateDatabase\([\s\S]{0,220}rolloutPathUpdates:/);
});

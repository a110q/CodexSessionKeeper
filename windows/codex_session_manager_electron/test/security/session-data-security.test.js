'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  applySessionDeletionPlan,
  applySessionJsonlPlan,
  assertFileContentMatchesFingerprint,
  assertSessionRestorePlanFresh,
  buildSessionDeletionPlan,
  buildSessionJsonlPlan,
  buildSessionProtectionPlan,
  buildSessionRestorePlan,
  indexTrustedSessionFiles,
  materializeSessionProtectionPlan,
  parseSessionJsonlFile,
} = require('../../src/session-data-security');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'session-data-security-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function write(filePath, lines) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${lines.join('\n')}${lines.length ? '\n' : ''}`, 'utf8');
}

test('history merge uses only the top-level session_id and ignores UUIDs in content', (t) => {
  const root = fixture(t);
  const source = path.join(root, 'snapshot-history.jsonl');
  const destination = path.join(root, 'history.jsonl');
  const target = '11111111-2222-3333-4444-555555555555';
  const other = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  write(destination, [JSON.stringify({ session_id: other, first_text: 'existing' })]);
  write(source, [
    JSON.stringify({ session_id: target, first_text: 'selected' }),
    JSON.stringify({ session_id: other, first_text: `mentions ${target}` }),
  ]);

  const plan = buildSessionJsonlPlan({
    operations: [{
      mode: 'merge',
      kind: 'history',
      sourcePath: source,
      destinationPath: destination,
      sessionIds: new Set([target]),
    }],
  });
  applySessionJsonlPlan(plan);

  const records = parseSessionJsonlFile({ filePath: destination, kind: 'history' }).records;
  assert.deepEqual(records.map((record) => record.sessionId), [other, target]);
  assert.doesNotMatch(fs.readFileSync(destination, 'utf8'), /mentions/);
});

test('non-UUID session identities remain case-sensitive', (t) => {
  const root = fixture(t);
  const source = path.join(root, 'history.jsonl');
  const destination = path.join(root, 'filtered.jsonl');
  write(source, [
    JSON.stringify({ session_id: 'CaseSensitive', first_text: 'selected' }),
    JSON.stringify({ session_id: 'casesensitive', first_text: 'other' }),
  ]);

  const plan = buildSessionJsonlPlan({ operations: [{
    mode: 'filter',
    kind: 'history',
    sourcePath: source,
    destinationPath: destination,
    sessionIds: new Set(['CaseSensitive']),
  }] });
  applySessionJsonlPlan(plan);

  const records = parseSessionJsonlFile({ filePath: destination, kind: 'history' }).records;
  assert.deepEqual(records.map((record) => record.sessionId), ['CaseSensitive']);
});

test('delete plan removes only exact schema identities', (t) => {
  const root = fixture(t);
  const targetPath = path.join(root, 'session_index.jsonl');
  const target = '11111111-2222-3333-4444-555555555555';
  const other = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  write(targetPath, [
    JSON.stringify({ id: target, thread_name: 'selected' }),
    JSON.stringify({ id: other, thread_name: `mentions ${target}` }),
  ]);

  const plan = buildSessionJsonlPlan({
    operations: [{
      mode: 'delete',
      kind: 'sessionIndex',
      sourcePath: targetPath,
      destinationPath: targetPath,
      sessionIds: new Set([target]),
    }],
  });
  applySessionJsonlPlan(plan);

  const records = parseSessionJsonlFile({ filePath: targetPath, kind: 'sessionIndex' }).records;
  assert.deepEqual(records.map((record) => record.sessionId), [other]);
});

test('atomic JSONL publication failure preserves the original and removes backup artifacts', (t) => {
  const root = fixture(t);
  const targetPath = path.join(root, 'history.jsonl');
  write(targetPath, [JSON.stringify({ session_id: 'target', first_text: 'preserve' })]);
  const before = fs.readFileSync(targetPath);
  const plan = buildSessionJsonlPlan({ operations: [{
    mode: 'delete',
    kind: 'history',
    sourcePath: targetPath,
    destinationPath: targetPath,
    sessionIds: new Set(['target']),
  }] });
  const renameSync = fs.renameSync;
  fs.renameSync = () => {
    const error = new Error('injected atomic replace failure');
    error.code = 'EIO';
    throw error;
  };
  try {
    assert.throws(() => applySessionJsonlPlan(plan), /injected atomic replace failure/);
  } finally {
    fs.renameSync = renameSync;
  }

  assert.deepEqual(fs.readFileSync(targetPath), before);
  assert.equal(fs.readdirSync(root).some((name) => name.includes('.previous')), false);
});

test('invalid or ambiguous JSONL fails before any destination mutation', (t) => {
  const root = fixture(t);
  const source = path.join(root, 'snapshot-history.jsonl');
  const destination = path.join(root, 'history.jsonl');
  write(destination, [JSON.stringify({ session_id: 'safe', first_text: 'preserve' })]);
  fs.writeFileSync(source, '{"session_id":"target"}\n\nnot-json\n', 'utf8');
  const before = fs.readFileSync(destination);

  assert.throws(
    () => buildSessionJsonlPlan({
      operations: [{
        mode: 'merge',
        kind: 'history',
        sourcePath: source,
        destinationPath: destination,
        sessionIds: new Set(['target']),
      }],
    }),
    (error) => error.code === 'INVALID_SESSION_JSONL' && /line 2|第 2 行/.test(error.message),
  );
  assert.deepEqual(fs.readFileSync(destination), before);

  write(source, [JSON.stringify({ session_id: 'target', id: 'other' })]);
  assert.throws(
    () => parseSessionJsonlFile({ filePath: source, kind: 'history' }),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );

  write(source, [JSON.stringify({ SESSION_ID: 'target' })]);
  assert.throws(
    () => parseSessionJsonlFile({ filePath: source, kind: 'history' }),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );

  write(source, [JSON.stringify({ session_id: '   ' })]);
  assert.throws(
    () => parseSessionJsonlFile({ filePath: source, kind: 'history' }),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );
});

test('trusted rollout identity comes from the first session_meta payload.id', (t) => {
  const codexRoot = fixture(t);
  const target = '11111111-2222-3333-4444-555555555555';
  const nested = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const valid = path.join(codexRoot, 'sessions', 'unrelated-name.jsonl');
  const misleading = path.join(codexRoot, 'sessions', `rollout-${target}.jsonl`);
  write(valid, [
    JSON.stringify({ type: 'session_meta', payload: { id: target, session_id: nested } }),
    JSON.stringify({ type: 'session_meta', payload: { id: nested, session_id: nested } }),
  ]);
  write(misleading, [
    JSON.stringify({ type: 'session_meta', payload: { id: nested } }),
  ]);

  const index = indexTrustedSessionFiles({ codexRoot });
  assert.deepEqual(index.get(target), [fs.realpathSync.native(valid)]);
  assert.deepEqual(index.get(nested), [fs.realpathSync.native(misleading)]);
});

test('trusted rollout index ignores symlink escapes and rejects a non-meta first record', (t) => {
  const codexRoot = fixture(t);
  const sessions = path.join(codexRoot, 'sessions');
  const outside = path.join(path.dirname(codexRoot), `${path.basename(codexRoot)}-outside.jsonl`);
  fs.mkdirSync(sessions, { recursive: true });
  write(outside, [JSON.stringify({ type: 'session_meta', payload: { id: 'outside' } })]);
  fs.symlinkSync(outside, path.join(sessions, 'linked.jsonl'));
  write(path.join(sessions, 'bad.jsonl'), [
    JSON.stringify({ type: 'event_msg', payload: { id: 'bad' } }),
  ]);

  const index = indexTrustedSessionFiles({ codexRoot });
  assert.equal(index.has('outside'), false);
  assert.equal(index.has('bad'), false);
});

test('trusted rollout index rejects a symbolic-link trust root', (t) => {
  const parent = fixture(t);
  const actualRoot = path.join(parent, 'actual');
  const linkedRoot = path.join(parent, 'linked');
  write(path.join(actualRoot, 'sessions', 'session.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { id: 'session-a' } }),
  ]);
  fs.symlinkSync(actualRoot, linkedRoot, 'dir');

  assert.throws(
    () => indexTrustedSessionFiles({ codexRoot: linkedRoot }),
    (error) => error.code === 'UNTRUSTED_SESSION_FILE',
  );
});

test('restore plan rejects a symbolic-link destination root', (t) => {
  const parent = fixture(t);
  const sourceRoot = path.join(parent, 'source');
  const actualDestination = path.join(parent, 'actual-destination');
  const linkedDestination = path.join(parent, 'linked-destination');
  write(path.join(sourceRoot, 'sessions', 'session.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { id: 'session-a' } }),
  ]);
  fs.mkdirSync(actualDestination);
  fs.symlinkSync(actualDestination, linkedDestination, 'dir');

  assert.throws(
    () => buildSessionRestorePlan({
      sessionIds: new Set(['session-a']),
      sourceRoot,
      destinationRoot: linkedDestination,
    }),
    (error) => error.code === 'UNTRUSTED_SESSION_FILE',
  );
});

test('protection plan copies only frozen trusted rollouts and exact JSONL identities', (t) => {
  const codexRoot = fixture(t);
  const destinationRoot = path.join(fixture(t), 'data');
  const target = '11111111-2222-3333-4444-555555555555';
  const other = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const trusted = path.join(codexRoot, 'sessions', 'unrelated-name.jsonl');
  const misleading = path.join(codexRoot, 'sessions', `rollout-${target}.jsonl`);
  write(trusted, [JSON.stringify({ type: 'session_meta', payload: { id: target } })]);
  write(misleading, [JSON.stringify({ type: 'session_meta', payload: { id: other } })]);
  write(path.join(codexRoot, 'history.jsonl'), [
    JSON.stringify({ session_id: target, first_text: 'selected' }),
    JSON.stringify({ session_id: other, first_text: `mentions ${target}` }),
  ]);

  const plan = buildSessionProtectionPlan({
    sessionIds: new Set([target]),
    codexRoot,
    destinationRoot,
  });
  materializeSessionProtectionPlan(plan);

  assert.equal(fs.existsSync(path.join(destinationRoot, 'sessions', 'unrelated-name.jsonl')), true);
  assert.equal(fs.existsSync(path.join(destinationRoot, 'sessions', `rollout-${target}.jsonl`)), false);
  const records = parseSessionJsonlFile({
    filePath: path.join(destinationRoot, 'history.jsonl'),
    kind: 'history',
  }).records;
  assert.deepEqual(records.map((record) => record.sessionId), [target]);
});

test('protection plan rejects a source changed after preflight', (t) => {
  const codexRoot = fixture(t);
  const destinationRoot = path.join(fixture(t), 'data');
  const target = '11111111-2222-3333-4444-555555555555';
  const rollout = path.join(codexRoot, 'sessions', 'session.jsonl');
  write(rollout, [JSON.stringify({ type: 'session_meta', payload: { id: target } })]);
  const plan = buildSessionProtectionPlan({
    sessionIds: new Set([target]),
    codexRoot,
    destinationRoot,
  });
  fs.appendFileSync(rollout, `${JSON.stringify({ type: 'event_msg', payload: { text: 'changed' } })}\n`);

  assert.throws(
    () => materializeSessionProtectionPlan(plan),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );
  assert.equal(fs.existsSync(destinationRoot), false);
});

test('protection materialization removes frozen JSONL outputs when rollout staging fails', (t) => {
  const codexRoot = fixture(t);
  const destinationRoot = path.join(fixture(t), 'data');
  const target = '11111111-2222-3333-4444-555555555555';
  const rollout = path.join(codexRoot, 'sessions', 'session.jsonl');
  write(rollout, [JSON.stringify({ type: 'session_meta', payload: { id: target } })]);
  write(path.join(codexRoot, 'history.jsonl'), [
    JSON.stringify({ session_id: target, first_text: 'selected' }),
  ]);
  const plan = buildSessionProtectionPlan({
    sessionIds: new Set([target]),
    codexRoot,
    destinationRoot,
  });
  const copyFileSync = fs.copyFileSync;
  fs.copyFileSync = () => {
    const error = new Error('injected copy failure');
    error.code = 'EIO';
    throw error;
  };
  try {
    assert.throws(() => materializeSessionProtectionPlan(plan), /injected copy failure/);
  } finally {
    fs.copyFileSync = copyFileSync;
  }

  assert.equal(fs.existsSync(path.join(destinationRoot, 'history.jsonl')), false);
  assert.equal(fs.existsSync(path.join(destinationRoot, 'sessions', 'session.jsonl')), false);
});

test('deletion plan ignores an untrusted raw path and cleans only exact safe indexes', (t) => {
  const codexRoot = fixture(t);
  const target = '11111111-2222-3333-4444-555555555555';
  const outside = path.join(path.dirname(codexRoot), `${path.basename(codexRoot)}-outside.jsonl`);
  write(outside, [JSON.stringify({ type: 'session_meta', payload: { id: target } })]);
  write(path.join(codexRoot, 'history.jsonl'), [
    JSON.stringify({ session_id: target, first_text: 'remove' }),
    JSON.stringify({ session_id: 'safe', first_text: `mentions ${target}` }),
  ]);

  const plan = buildSessionDeletionPlan({ sessionIds: new Set([target]), codexRoot });
  const warning = applySessionDeletionPlan(plan);

  assert.match(warning, /仅清理索引/);
  assert.equal(fs.existsSync(outside), true);
  const records = parseSessionJsonlFile({
    filePath: path.join(codexRoot, 'history.jsonl'),
    kind: 'history',
  }).records;
  assert.deepEqual(records.map((record) => record.sessionId), ['safe']);
});

test('batch deletion rolls back quarantined rollouts when one move fails', (t) => {
  const codexRoot = fixture(t);
  const target = '11111111-2222-3333-4444-555555555555';
  const first = path.join(codexRoot, 'sessions', 'first.jsonl');
  const second = path.join(codexRoot, 'archived_sessions', 'second.jsonl');
  const history = path.join(codexRoot, 'history.jsonl');
  write(first, [JSON.stringify({ type: 'session_meta', payload: { id: target } })]);
  write(second, [JSON.stringify({ type: 'session_meta', payload: { id: target } })]);
  write(history, [JSON.stringify({ session_id: target, first_text: 'preserve on failure' })]);
  const firstBefore = fs.readFileSync(first);
  const secondBefore = fs.readFileSync(second);
  const historyBefore = fs.readFileSync(history);
  const plan = buildSessionDeletionPlan({ sessionIds: new Set([target]), codexRoot });
  const failOnPath = fs.realpathSync.native(first);

  const renameSync = fs.renameSync;
  let injected = false;
  fs.renameSync = (sourcePath, destinationPath) => {
    if (!injected && sourcePath === failOnPath && destinationPath.includes('.delete-quarantine-')) {
      injected = true;
      const error = new Error('injected quarantine failure');
      error.code = 'EACCES';
      throw error;
    }
    return renameSync(sourcePath, destinationPath);
  };
  try {
    assert.throws(() => applySessionDeletionPlan(plan), /injected quarantine failure/);
  } finally {
    fs.renameSync = renameSync;
  }

  assert.deepEqual(fs.readFileSync(first), firstBefore);
  assert.deepEqual(fs.readFileSync(second), secondBefore);
  assert.deepEqual(fs.readFileSync(history), historyBefore);
  assert.deepEqual(
    fs.readdirSync(path.dirname(first)).filter((name) => name.includes('.delete-quarantine-')),
    [],
  );
});

test('restore preflight rejects one malformed index before creating destination files', (t) => {
  const root = fixture(t);
  const sourceRoot = path.join(root, 'snapshot');
  const destinationRoot = path.join(root, 'codex');
  const target = '11111111-2222-3333-4444-555555555555';
  write(path.join(sourceRoot, 'sessions', 'session.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { id: target } }),
  ]);
  fs.mkdirSync(sourceRoot, { recursive: true });
  fs.writeFileSync(path.join(sourceRoot, 'history.jsonl'), `${JSON.stringify({ session_id: target })}\n\n`, 'utf8');

  assert.throws(
    () => buildSessionRestorePlan({ sessionIds: new Set([target]), sourceRoot, destinationRoot }),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );
  assert.equal(fs.existsSync(destinationRoot), false);
});

test('restore plan rejects destination JSONL files created after preflight', (t) => {
  const root = fixture(t);
  const sourceRoot = path.join(root, 'snapshot');
  const destinationRoot = path.join(root, 'codex');
  const target = '11111111-2222-3333-4444-555555555555';
  write(path.join(sourceRoot, 'sessions', 'session.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { id: target } }),
  ]);
  write(path.join(sourceRoot, 'history.jsonl'), [
    JSON.stringify({ session_id: target, first_text: 'snapshot' }),
  ]);

  const plan = buildSessionRestorePlan({
    sessionIds: new Set([target]),
    sourceRoot,
    destinationRoot,
  });
  const concurrentRollout = path.join(destinationRoot, 'sessions', 'session.jsonl');
  const concurrentHistory = path.join(destinationRoot, 'history.jsonl');
  write(concurrentRollout, [
    JSON.stringify({ type: 'session_meta', payload: { id: target } }),
    JSON.stringify({ type: 'event_msg', payload: { message: 'new Codex data' } }),
  ]);
  write(concurrentHistory, [
    JSON.stringify({ session_id: target, first_text: 'new Codex data' }),
  ]);
  const rolloutBefore = fs.readFileSync(concurrentRollout);
  const historyBefore = fs.readFileSync(concurrentHistory);

  assert.throws(
    () => assertSessionRestorePlanFresh(plan),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );
  assert.throws(
    () => applySessionJsonlPlan(plan.jsonlPlan),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );
  assert.deepEqual(fs.readFileSync(concurrentRollout), rolloutBefore);
  assert.deepEqual(fs.readFileSync(concurrentHistory), historyBefore);
});

test('session-scoped operations never identify shell snapshots by filename substring', () => {
  const mainSource = fs.readFileSync(path.join(__dirname, '../../src/main.js'), 'utf8');

  assert.doesNotMatch(mainSource, /copyShellSnapshotsForSessions/);
  assert.doesNotMatch(mainSource, /restoreShellSnapshots/);
  assert.doesNotMatch(mainSource, /shellDir[\s\S]{0,500}basename\([^\n]+\)\.includes\(session/);
});

test('protection snapshots materialize the frozen security plan', () => {
  const mainSource = fs.readFileSync(path.join(__dirname, '../../src/main.js'), 'utf8');

  assert.match(mainSource, /const protectionPlan = buildSessionProtectionPlan\(/);
  assert.match(mainSource, /materializeSessionProtectionPlan\(protectionPlan\)/);
  assert.doesNotMatch(mainSource, /copyRolloutFilesForSessions/);
  assert.doesNotMatch(mainSource, /buildSessionDeletionPlan\([^)]*\);\s*\n\s*ensureDir\(snapshotRoot\)/);
});

test('staged rollout content must still match the frozen source digest', (t) => {
  const root = fixture(t);
  const source = path.join(root, 'source.jsonl');
  const staged = path.join(root, 'staged.jsonl');
  write(source, [JSON.stringify({ type: 'session_meta', payload: { id: 'session-a' } })]);
  fs.copyFileSync(source, staged);
  const expected = indexTrustedSessionFiles({ codexRoot: (() => {
    const codexRoot = path.join(root, 'codex');
    fs.mkdirSync(path.join(codexRoot, 'sessions'), { recursive: true });
    const trusted = path.join(codexRoot, 'sessions', 'source.jsonl');
    fs.copyFileSync(source, trusted);
    return codexRoot;
  })() }).get('session-a');
  const trustedPath = expected[0];
  const plan = buildSessionRestorePlan({
    sessionIds: new Set(['session-a']),
    sourceRoot: path.dirname(path.dirname(trustedPath)),
    destinationRoot: path.join(root, 'destination'),
  });
  const fingerprint = plan.trustedFiles[0].fingerprint;

  assert.doesNotThrow(() => assertFileContentMatchesFingerprint(staged, fingerprint));
  const contents = fs.readFileSync(staged);
  contents[contents.length - 2] ^= 1;
  fs.writeFileSync(staged, contents);
  assert.throws(
    () => assertFileContentMatchesFingerprint(staged, fingerprint),
    (error) => error.code === 'INVALID_SESSION_JSONL',
  );
});

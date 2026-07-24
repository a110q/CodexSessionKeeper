const assert = require('node:assert/strict');
const test = require('node:test');

const { runConfirmedUpdateAction } = require('../../src/update/update-action-gate');

test('declining download confirmation cannot invoke the download action', async () => {
  const auditEvents = [];
  let downloadCalls = 0;

  const outcome = await runConfirmedUpdateAction({
    action: 'download',
    version: '1.1.0',
    confirm: async () => false,
    audit: async (entry) => auditEvents.push(entry),
    perform: async () => {
      downloadCalls += 1;
      return 'unreachable';
    },
  });

  assert.deepEqual(outcome, { confirmed: false });
  assert.equal(downloadCalls, 0);
  assert.deepEqual(auditEvents.map(({ event }) => event), [
    'download_confirmation_requested',
    'download_cancelled',
  ]);
});

test('declining install confirmation cannot invoke the install action', async () => {
  const auditEvents = [];
  let installCalls = 0;

  const outcome = await runConfirmedUpdateAction({
    action: 'install',
    version: '1.1.0',
    confirm: async () => false,
    audit: async (entry) => auditEvents.push(entry),
    perform: async () => {
      installCalls += 1;
      return 'unreachable';
    },
  });

  assert.deepEqual(outcome, { confirmed: false });
  assert.equal(installCalls, 0);
  assert.deepEqual(auditEvents.map(({ event }) => event), [
    'install_confirmation_requested',
    'install_cancelled',
  ]);
});

test('confirmed update action is audited and performed exactly once', async () => {
  const auditEvents = [];
  let actionCalls = 0;

  const outcome = await runConfirmedUpdateAction({
    action: 'download',
    version: '1.1.0',
    confirm: async () => true,
    audit: async (entry) => auditEvents.push(entry),
    perform: async () => {
      actionCalls += 1;
      return { phase: 'downloading' };
    },
  });

  assert.deepEqual(outcome, {
    confirmed: true,
    result: { phase: 'downloading' },
  });
  assert.equal(actionCalls, 1);
  assert.deepEqual(auditEvents.map(({ event }) => event), [
    'download_confirmation_requested',
    'download_confirmed',
    'download_requested',
  ]);
});

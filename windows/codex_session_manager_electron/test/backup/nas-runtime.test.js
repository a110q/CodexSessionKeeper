'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { createNasRuntime } = require('../../src/backup/nas-runtime');
const { createSettingsStore } = require('../../src/settings');

test('settings store atomically preserves auto restore while patching NAS identity', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'nas-settings-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const store = createSettingsStore({ filePath: path.join(root, 'settings.json'), fs, pathImpl: path });

  store.savePatch({ autoRestoreOnLaunch: true });
  store.savePatch({ nasBackup: { department: '运营部', employee: '陈超' } });

  assert.equal(store.load().autoRestoreOnLaunch, true);
  assert.equal(store.load().nasBackup.employee, '陈超');
  assert.deepEqual(await fsp.readdir(root), ['settings.json']);
});

test('unconfigured startup creates no agent and activation starts one', async () => {
  const harness = runtimeHarness();
  await harness.runtime.initialize();
  assert.equal(harness.created.length, 0);
  assert.equal(harness.runtime.snapshot().state, 'unconfigured');

  await harness.runtime.activate({ department: '运营部', employee: '陈超' });
  assert.equal(harness.created.length, 1);
  assert.equal(harness.created[0].started, true);
});

test('disconnected startup schedules 30 second retry and reconnect starts one agent', async () => {
  const saved = configuration('运营部', '陈超');
  const harness = runtimeHarness({ saved, connected: false });

  await harness.runtime.initialize();
  assert.equal(harness.runtime.snapshot().state, 'disconnected');
  assert.deepEqual(harness.delays, [30000]);
  assert.equal(harness.created.length, 0);

  harness.connected.value = true;
  await harness.fireRetry();
  assert.equal(harness.created.length, 1);
  assert.equal(harness.runtime.snapshot().state, 'running');
});

test('manual retry revalidates and restarts current agent', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超') });
  await harness.runtime.initialize();

  await harness.runtime.retry();

  assert.equal(harness.created.length, 2);
  assert.equal(harness.created[0].stopped, true);
  assert.equal(harness.created[1].started, true);
});

test('failed reconfiguration preserves settings and restarts previous validated target', async () => {
  const saved = configuration('运营部', '陈超');
  const harness = runtimeHarness({ saved, failEmployee: '不存在' });
  await harness.runtime.initialize();

  await assert.rejects(
    harness.runtime.activate({ department: '运营部', employee: '不存在' }),
    /injected activation failure/
  );

  assert.deepEqual(harness.settings.load().nasBackup, saved);
  assert.equal(harness.created.length, 2);
  assert.equal(harness.created[0].stopped, true);
  assert.equal(harness.created[1].target.configuration.employee, '陈超');
});

function runtimeHarness(options = {}) {
  let settings = { autoRestoreOnLaunch: false, nasBackup: options.saved || null };
  const settingsStore = {
    load: () => structuredClone(settings),
    savePatch: (patch) => { settings = { ...settings, ...structuredClone(patch) }; return structuredClone(settings); }
  };
  const connected = { value: options.connected !== false };
  const created = [];
  const delays = [];
  const scheduled = [];
  const nasService = {
    async activate({ department, employee, previous }) {
      if (employee === options.failEmployee) throw new Error('injected activation failure');
      return target(previous || configuration(department, employee), department, employee);
    },
    async resolve(configurationValue) {
      if (!connected.value) throw new Error('NAS disconnected');
      return target(configurationValue, configurationValue.department, configurationValue.employee);
    }
  };
  const runtime = createNasRuntime({
    nasService,
    settingsStore,
    homeDir: '/home/alice',
    pathsFactory: ({ target: selectedTarget }) => ({ backupRoot: selectedTarget.backupRoot }),
    agentFactory: ({ target: selectedTarget, paths }) => {
      const agent = {
        target: selectedTarget,
        paths,
        started: false,
        stopped: false,
        async start() { this.started = true; },
        async stop() { this.stopped = true; }
      };
      created.push(agent);
      return agent;
    },
    scheduleRetry: (action, delay) => {
      delays.push(delay);
      scheduled.push(action);
    }
  });
  return {
    runtime,
    settings: settingsStore,
    connected,
    created,
    delays,
    async fireRetry() {
      const action = scheduled.shift();
      if (action) await action();
    }
  };
}

function configuration(department, employee) {
  return {
    version: 1,
    department,
    employee,
    deviceId: '11111111-1111-1111-1111-111111111111',
    deviceName: 'Runtime Mac',
    deviceDirectoryName: 'Runtime-Mac-11111111'
  };
}

function target(baseConfiguration, department, employee) {
  const configurationValue = { ...baseConfiguration, department, employee };
  return {
    configuration: configurationValue,
    backupRoot: `/nas/${department}/${employee}/${configurationValue.deviceDirectoryName}/incremental-backups`,
    localStateRoot: `/local/${configurationValue.deviceId}`
  };
}

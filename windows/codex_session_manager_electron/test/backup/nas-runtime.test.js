'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { createNasRuntime } = require('../../src/backup/nas-runtime');
const { createSettingsStore } = require('../../src/settings');

test('settings store atomically preserves all preferences across sequential patches', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'nas-settings-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const store = createSettingsStore({ filePath: path.join(root, 'settings.json'), fs, pathImpl: path });

  store.savePatch({ autoRestoreOnLaunch: true });
  store.savePatch({ onboardingInProgress: true });
  store.savePatch({ nasBackup: { department: '运营部', employee: '陈超' } });
  store.savePatch({ onboardingVersion: 1, onboardingInProgress: false });

  assert.equal(store.load().autoRestoreOnLaunch, true);
  assert.equal(store.load().nasBackup.employee, '陈超');
  assert.equal(store.load().onboardingVersion, 1);
  assert.equal(store.load().onboardingInProgress, false);
  assert.deepEqual(await fsp.readdir(root), ['settings.json']);
});

test('settings store fails safely to defaults when the existing file is malformed', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'nas-settings-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'settings.json');
  await fsp.writeFile(filePath, '{broken');
  const store = createSettingsStore({ filePath, fs, pathImpl: path });

  assert.deepEqual(store.load(), {
    autoRestoreOnLaunch: false,
    nasBackup: null,
    onboardingVersion: 0,
    onboardingInProgress: false,
  });
  store.savePatch({ autoRestoreOnLaunch: true });
  assert.equal(store.load().autoRestoreOnLaunch, true);
});

test('unconfigured startup creates no agent and activation starts one', async () => {
  const harness = runtimeHarness();
  await harness.runtime.initialize();
  assert.equal(harness.created.length, 0);
  assert.equal(harness.runtime.snapshot().state, 'unconfigured');

  await harness.runtime.activate({ department: '运营部', employee: '陈超' });
  assert.equal(harness.created.length, 1);
  assert.equal(harness.created[0].started, true);
  assert.deepEqual(harness.created[0].pollingIntervals, [30000]);
  assert.deepEqual(harness.created[0].triggers, ['activation']);
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
  assert.equal(harness.runtime.snapshot().state, 'validating');
  assert.deepEqual(harness.created[0].pollingIntervals, [30000]);
  assert.deepEqual(harness.created[0].triggers, ['reconnect']);
});

test('manual retry revalidates and restarts current agent', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超') });
  await harness.runtime.initialize();

  await harness.runtime.retry();

  assert.equal(harness.created.length, 2);
  assert.equal(harness.created[0].stopped, true);
  assert.equal(harness.created[1].started, true);
  assert.deepEqual(harness.created[1].triggers, ['activation']);
});

test('startup performs one explicit write probe while periodic target validation stays read-only', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超') });

  await harness.runtime.initialize();
  assert.equal(harness.writableChecks, 1);
  const settled = harness.sideEffectCounts();

  await harness.created[0].validateTarget();

  assert.equal(harness.writableChecks, 1);
  assert.equal(harness.sideEffectCounts().resolveCalls, settled.resolveCalls + 1);
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

test('verified state requires final status after readback progress', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超') });
  await harness.runtime.initialize();

  assert.equal(harness.runtime.snapshot().state, 'validating');
  harness.created[0].report({ phase: 'seeding', totalFiles: 3, completedFiles: 1, pendingFiles: 2 });
  assert.equal(harness.runtime.snapshot().state, 'seeding');
  harness.created[0].report({ phase: 'scanning', totalFiles: 3, completedFiles: 2, pendingFiles: 1 });
  assert.equal(harness.runtime.snapshot().state, 'pending');
  harness.created[0].report({ phase: 'verifying', totalFiles: 3, completedFiles: 2, pendingFiles: 1 });
  assert.equal(harness.runtime.snapshot().state, 'verifying');
  assert.equal(harness.runtime.backupStatus().status, 'verifying');
  harness.created[0].report({ phase: 'scanning', totalFiles: 3, completedFiles: 3, pendingFiles: 0 });
  assert.equal(harness.runtime.snapshot().state, 'verifying');
  harness.created[0].reportStatus({ status: 'running', mode: 'polling', lastError: null });
  assert.equal(harness.runtime.snapshot().state, 'running');
});

test('failedFiles remains truthful through runtime progress and final error status', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超') });
  await harness.runtime.initialize();

  harness.created[0].report({
    phase: 'scanning',
    totalFiles: 3,
    completedFiles: 3,
    failedFiles: 1,
    pendingFiles: 0,
  });
  harness.created[0].reportStatus({
    status: 'error',
    mode: 'polling',
    lastError: 'exact blocked path and reason',
  });

  assert.deepEqual(harness.runtime.backupStatus().progress, {
    phase: 'scanning',
    totalFiles: 3,
    completedFiles: 3,
    failedFiles: 1,
    pendingFiles: 0,
  });
  assert.equal(harness.runtime.backupStatus().status, 'error');
  assert.equal(harness.runtime.backupStatus().lastError, 'exact blocked path and reason');
});

test('persisted status is loaded once and repeated renderer status reads are memory-only', async () => {
  const savedStatus = {
    status: 'running',
    mode: 'polling',
    lastBackupAt: '2026-07-14T03:04:05.000Z',
    lastError: null,
    sessionCount: 7,
  };
  const harness = runtimeHarness({
    saved: configuration('运营部', '陈超'),
    persistedStatus: savedStatus,
  });

  await harness.runtime.initialize();
  const settledCounts = harness.sideEffectCounts();
  for (let index = 0; index < 100; index += 1) {
    assert.deepEqual(harness.runtime.backupStatus(), {
      ...savedStatus,
      status: 'validating',
      lastError: null,
      progress: null,
    });
  }

  assert.deepEqual(harness.sideEffectCounts(), settledCounts);
  assert.equal(harness.statusReads, 1);
  harness.created[0].reportStatus({
    ...savedStatus,
    status: 'error',
    lastError: 'NAS volume disappeared',
  });
  assert.equal(harness.runtime.backupStatus().status, 'error');
  assert.equal(harness.runtime.backupStatus().lastError, 'NAS volume disappeared');
});

test('lifecycle scan requests forward to the active agent', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超') });
  await harness.runtime.initialize();

  assert.deepEqual(harness.created[0].triggers, ['startup']);
  harness.runtime.requestImmediateScan('wake');

  assert.deepEqual(harness.created[0].triggers, ['startup', 'wake']);
});

test('out-of-order callback delivery cannot let stale progress overwrite final status', async () => {
  const deliveries = [];
  const harness = runtimeHarness({
    saved: configuration('运营部', '陈超'),
    callbackDelivery: (action) => deliveries.push(action),
  });
  await harness.runtime.initialize();

  harness.created[0].report({ phase: 'scanning', totalFiles: 1, completedFiles: 1, pendingFiles: 0 });
  harness.created[0].reportStatus({ status: 'error', mode: 'polling', lastError: 'final failure' });
  deliveries[1]();
  deliveries[0]();

  assert.equal(harness.runtime.snapshot().state, 'error');
  assert.equal(harness.runtime.backupStatus().lastError, 'final failure');
});

test('replacement defers until the previous writer reaches bounded quiescence', async () => {
  const harness = runtimeHarness({
    saved: configuration('运营部', '陈超'),
    replacementQuiescence: false,
  });
  await harness.runtime.initialize();

  await assert.rejects(harness.runtime.retry(), /still finishing its current work/);
  assert.equal(harness.created.length, 1);
  assert.equal(harness.runtime.snapshot().state, 'disconnected');
  assert.deepEqual(harness.delays, [30000]);

  harness.created[0].replacementQuiescence = true;
  await harness.fireRetry();
  assert.equal(harness.created.length, 2);
  assert.deepEqual(harness.created[1].triggers, ['reconnect']);
});

test('stale retry callback cannot reconnect after runtime shutdown', async () => {
  const harness = runtimeHarness({ saved: configuration('运营部', '陈超'), connected: false });
  await harness.runtime.initialize();
  await harness.runtime.stop();
  harness.connected.value = true;

  await harness.fireRetry();

  assert.equal(harness.created.length, 0);
});

test('manual retry supersedes an in-flight scheduled reconnect without leaking a writer', async () => {
  const reconnectEntered = controlledPromise();
  const releaseReconnect = controlledPromise();
  let resolveCall = 0;
  const harness = runtimeHarness({
    saved: configuration('运营部', '陈超'),
    connected: false,
    beforeResolve: async () => {
      resolveCall += 1;
      if (resolveCall !== 2) return;
      reconnectEntered.resolve();
      await releaseReconnect.promise;
    },
  });
  await harness.runtime.initialize();
  harness.connected.value = true;

  const scheduledReconnect = harness.fireRetry();
  await reconnectEntered.promise;
  const manualRetry = harness.runtime.retry();
  releaseReconnect.resolve();
  await Promise.all([scheduledReconnect, manualRetry]);

  assert.equal(harness.created.length, 1);
  assert.equal(harness.created.filter((agent) => !agent.stopped).length, 1);
  assert.deepEqual(harness.created[0].triggers, ['activation']);
});

test('retry supersedes an in-flight activation and only the latest operation starts a writer', async () => {
  const activationEntered = controlledPromise();
  const releaseActivation = controlledPromise();
  const saved = configuration('运营部', '陈超');
  const harness = runtimeHarness({
    saved,
    beforeActivate: async () => {
      activationEntered.resolve();
      await releaseActivation.promise;
    },
  });
  await harness.runtime.initialize();

  const activation = harness.runtime.activate({ department: '运营部', employee: '李雷' });
  await activationEntered.promise;
  const retry = harness.runtime.retry();
  releaseActivation.resolve();
  await Promise.all([activation, retry]);

  assert.equal(harness.created.length, 2);
  assert.equal(harness.created[0].stopped, true);
  assert.equal(harness.created.filter((agent) => !agent.stopped).length, 1);
  assert.equal(harness.created[1].target.configuration.employee, '陈超');
  assert.deepEqual(harness.settings.load().nasBackup, saved);
});

function runtimeHarness(options = {}) {
  let settings = { autoRestoreOnLaunch: false, nasBackup: options.saved || null };
  let settingsLoads = 0;
  const settingsStore = {
    load: () => { settingsLoads += 1; return structuredClone(settings); },
    savePatch: (patch) => { settings = { ...settings, ...structuredClone(patch) }; return structuredClone(settings); }
  };
  const connected = { value: options.connected !== false };
  const created = [];
  const delays = [];
  const scheduled = [];
  let resolveCalls = 0;
  let writableChecks = 0;
  let pathCalls = 0;
  let statusReads = 0;
  const nasService = {
    async activate({ department, employee, previous }) {
      await options.beforeActivate?.({ department, employee, previous });
      if (employee === options.failEmployee) throw new Error('injected activation failure');
      return target(previous || configuration(department, employee), department, employee);
    },
    async resolve(configurationValue) {
      resolveCalls += 1;
      await options.beforeResolve?.({ call: resolveCalls, configuration: configurationValue });
      if (!connected.value) throw new Error('NAS disconnected');
      return target(configurationValue, configurationValue.department, configurationValue.employee);
    },
    async verifyWritable() { writableChecks += 1; },
  };
  const runtime = createNasRuntime({
    nasService,
    settingsStore,
    homeDir: '/home/alice',
    pathsFactory: ({ target: selectedTarget }) => {
      pathCalls += 1;
      return {
        backupRoot: selectedTarget.backupRoot,
        localStatusPath: `/local/${selectedTarget.configuration.deviceId}/status.json`,
      };
    },
    statusLoader: async () => {
      statusReads += 1;
      return options.persistedStatus ? structuredClone(options.persistedStatus) : null;
    },
    callbackDelivery: options.callbackDelivery,
    agentFactory: ({ target: selectedTarget, paths, validateTarget, onProgress, onStatus }) => {
      const agent = {
        target: selectedTarget,
        paths,
        started: false,
        stopped: false,
        replacementQuiescence: options.replacementQuiescence !== false,
        pollingIntervals: [],
        triggers: [],
        report: onProgress,
        reportStatus: onStatus,
        validateTarget,
        async start() { this.started = true; },
        startPolling(interval) { this.started = true; this.pollingIntervals.push(interval); },
        requestImmediateScan(trigger) { this.triggers.push(trigger); },
        async stopAndAwaitQuiescence() { this.stopped = true; return this.replacementQuiescence; },
        stop() { this.stopped = true; },
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
    get writableChecks() { return writableChecks; },
    get statusReads() { return statusReads; },
    sideEffectCounts() {
      return { settingsLoads, resolveCalls, pathCalls, statusReads, created: created.length };
    },
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

function controlledPromise() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

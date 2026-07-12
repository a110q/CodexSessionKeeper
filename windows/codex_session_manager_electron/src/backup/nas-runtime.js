'use strict';

function createNasRuntime({
  nasService,
  settingsStore,
  agentFactory,
  pathsFactory,
  homeDir,
  retryDelay = 30000,
  scheduleRetry = defaultScheduleRetry
}) {
  if (!nasService || !settingsStore || !agentFactory || !pathsFactory) {
    throw new Error('createNasRuntime requires nasService, settingsStore, agentFactory, and pathsFactory');
  }
  let agent = null;
  let target = null;
  let retryScheduled = false;
  let stopped = false;
  let state = snapshotValue('unconfigured');

  async function initialize() {
    stopped = false;
    if (agent) return snapshot();
    const configuration = settingsStore.load().nasBackup;
    if (!configuration) {
      state = snapshotValue('unconfigured');
      return snapshot();
    }
    state = snapshotValue('validating', configuration);
    try {
      const resolved = await nasService.resolve(configuration);
      await startAgent(resolved);
    } catch (error) {
      markDisconnected(error, configuration);
    }
    return snapshot();
  }

  async function activate({ department, employee }) {
    stopped = false;
    const previous = settingsStore.load().nasBackup;
    await stopAgent();
    state = snapshotValue('validating', previous);
    try {
      const activated = await nasService.activate({ department, employee, previous });
      settingsStore.savePatch({ nasBackup: activated.configuration });
      await startAgent(activated);
      return snapshot();
    } catch (error) {
      if (previous) {
        try {
          await startAgent(await nasService.resolve(previous));
        } catch (restartError) {
          markDisconnected(restartError, previous);
        }
      } else {
        state = snapshotValue('unconfigured', null, error);
      }
      throw error;
    }
  }

  async function retry() {
    if (stopped) return snapshot();
    retryScheduled = false;
    await stopAgent();
    const configuration = settingsStore.load().nasBackup;
    if (!configuration) {
      state = snapshotValue('unconfigured');
      return snapshot();
    }
    state = snapshotValue('validating', configuration);
    try {
      await startAgent(await nasService.resolve(configuration));
      return snapshot();
    } catch (error) {
      markDisconnected(error, configuration);
      throw error;
    }
  }

  async function startAgent(selectedTarget) {
    const paths = pathsFactory({ homeDir, target: selectedTarget });
    const created = agentFactory({
      paths,
      target: selectedTarget,
      validateTarget: () => nasService.resolve(selectedTarget.configuration)
    });
    agent = created;
    target = selectedTarget;
    retryScheduled = false;
    if (typeof created.start === 'function') await created.start();
    else if (typeof created.startPolling === 'function') created.startPolling(10000);
    state = snapshotValue('running', selectedTarget.configuration);
  }

  async function stopAgent() {
    const current = agent;
    agent = null;
    target = null;
    if (!current) return;
    if (typeof current.stop === 'function') await current.stop();
  }

  function markDisconnected(error, configuration) {
    state = snapshotValue('disconnected', configuration, error);
    if (retryScheduled || stopped) return;
    retryScheduled = true;
    scheduleRetry(async () => {
      retryScheduled = false;
      if (stopped || agent) return;
      try { await retry(); } catch {}
    }, retryDelay);
  }

  async function stop() {
    stopped = true;
    retryScheduled = false;
    await stopAgent();
  }

  function snapshot() {
    return {
      ...state,
      configuration: state.configuration ? { ...state.configuration } : null,
      target: target ? { backupRoot: target.backupRoot, localStateRoot: target.localStateRoot } : null
    };
  }

  return Object.freeze({ initialize, activate, retry, stop, snapshot });
}

function snapshotValue(state, configuration = null, error = null) {
  return {
    state,
    configuration: configuration ? { ...configuration } : null,
    lastError: error ? (error.message || String(error)) : null
  };
}

function defaultScheduleRetry(action, delay) {
  const timer = setTimeout(() => { void action(); }, delay);
  timer.unref?.();
  return timer;
}

module.exports = { createNasRuntime };

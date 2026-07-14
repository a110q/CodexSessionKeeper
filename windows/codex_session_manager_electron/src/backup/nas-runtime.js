'use strict';

const fsp = require('node:fs/promises');

function createNasRuntime({
  nasService,
  settingsStore,
  agentFactory,
  pathsFactory,
  homeDir,
  retryDelay = 30000,
  pollInterval = 30000,
  replacementQuiescenceTimeout = 100,
  statusLoader = defaultStatusLoader,
  callbackDelivery = defaultCallbackDelivery,
  scheduleRetry = defaultScheduleRetry,
}) {
  if (!nasService || !settingsStore || !agentFactory || !pathsFactory) {
    throw new Error('createNasRuntime requires nasService, settingsStore, agentFactory, and pathsFactory');
  }
  let agent = null;
  let target = null;
  let cachedStatus = null;
  let retryScheduled = false;
  let retryGeneration = 0;
  let agentGeneration = 0;
  let lifecycleGeneration = 0;
  let lifecycleTail = Promise.resolve();
  let lastAppliedCallbackSequence = 0;
  let stopped = false;
  let state = snapshotValue('unconfigured');

  function initialize() {
    stopped = false;
    return runLifecycleOperation(initializeLocked);
  }

  async function initializeLocked(generation) {
    if (!ownsLifecycle(generation)) return snapshot();
    if (agent) return snapshot();
    const configuration = settingsStore.load().nasBackup;
    if (!configuration) {
      cachedStatus = null;
      state = snapshotValue('unconfigured');
      return snapshot();
    }
    state = snapshotValue('validating', configuration);
    try {
      const resolved = await nasService.resolve(configuration);
      if (!ownsLifecycle(generation)) return snapshot();
      await startAgent(resolved, 'startup', generation);
    } catch (error) {
      if (!ownsLifecycle(generation)) return snapshot();
      markDisconnected(error, configuration);
    }
    return snapshot();
  }

  function activate({ department, employee }) {
    stopped = false;
    invalidateScheduledRetry();
    return runLifecycleOperation((generation) => activateLocked({ department, employee }, generation));
  }

  async function activateLocked({ department, employee }, generation) {
    if (!ownsLifecycle(generation)) return snapshot();
    const previous = settingsStore.load().nasBackup;
    const quiesced = await stopAgentForReplacement();
    if (!ownsLifecycle(generation)) return snapshot();
    if (!quiesced) {
      const error = replacementQuiescenceError();
      markReplacementDeferred(error, previous);
      throw error;
    }
    state = snapshotValue('validating', previous);
    try {
      const activated = await nasService.activate({ department, employee, previous });
      if (!ownsLifecycle(generation)) return snapshot();
      settingsStore.savePatch({ nasBackup: activated.configuration });
      await startAgent(activated, 'activation', generation);
      return snapshot();
    } catch (error) {
      if (!ownsLifecycle(generation)) return snapshot();
      if (previous) {
        try {
          const resolved = await nasService.resolve(previous);
          if (!ownsLifecycle(generation)) return snapshot();
          await startAgent(resolved, 'activation', generation);
        } catch (restartError) {
          if (!ownsLifecycle(generation)) return snapshot();
          markDisconnected(restartError, previous);
        }
      } else {
        cachedStatus = null;
        state = snapshotValue('unconfigured', null, error);
      }
      throw error;
    }
  }

  function retry() {
    if (stopped) return Promise.resolve(snapshot());
    const trigger = state.state === 'disconnected' ? 'reconnect' : 'activation';
    invalidateScheduledRetry();
    return runLifecycleOperation((generation) => retryLocked(trigger, generation));
  }

  async function retryLocked(trigger, generation) {
    if (!ownsLifecycle(generation)) return snapshot();
    const quiesced = await stopAgentForReplacement();
    if (!ownsLifecycle(generation)) return snapshot();
    if (!quiesced) {
      const error = replacementQuiescenceError();
      markReplacementDeferred(error, state.configuration);
      throw error;
    }
    const configuration = settingsStore.load().nasBackup;
    if (!configuration) {
      cachedStatus = null;
      state = snapshotValue('unconfigured');
      return snapshot();
    }
    state = snapshotValue('validating', configuration);
    try {
      const resolved = await nasService.resolve(configuration);
      if (!ownsLifecycle(generation)) return snapshot();
      await startAgent(resolved, trigger, generation);
      return snapshot();
    } catch (error) {
      if (!ownsLifecycle(generation)) return snapshot();
      markDisconnected(error, configuration);
      throw error;
    }
  }

  async function startAgent(selectedTarget, trigger, lifecycle) {
    if (!ownsLifecycle(lifecycle)) return false;
    invalidateScheduledRetry();
    const paths = pathsFactory({ homeDir, target: selectedTarget });
    const initialStatus = await statusLoader(paths.localStatusPath);
    if (!ownsLifecycle(lifecycle)) return false;
    cachedStatus = initialStatus ? { ...initialStatus } : null;
    agentGeneration += 1;
    const generation = agentGeneration;
    let callbackSequence = 0;
    lastAppliedCallbackSequence = 0;
    target = selectedTarget;
    state = snapshotValue(
      initialStatus?.status === 'error' ? 'error' : 'running',
      selectedTarget.configuration,
      initialStatus?.lastError || null,
    );
    const deliver = (kind, value) => {
      callbackSequence += 1;
      const sequence = callbackSequence;
      callbackDelivery(() => {
        if (kind === 'progress') recordProgress(value, selectedTarget, generation, sequence);
        else recordStatus(value, selectedTarget, generation, sequence);
      });
    };
    const created = agentFactory({
      paths,
      target: selectedTarget,
      validateTarget: () => nasService.resolve(selectedTarget.configuration),
      initialStatus,
      onProgress: (progress) => deliver('progress', progress),
      onStatus: (status) => deliver('status', status),
    });
    agent = created;
    if (typeof created.startPolling === 'function') created.startPolling(pollInterval);
    else if (typeof created.start === 'function') await created.start();
    if (!ownsLifecycle(lifecycle)) {
      if (agent === created) {
        agent = null;
        target = null;
      }
      created.stop?.();
      return false;
    }
    if (typeof created.requestImmediateScan === 'function') {
      void Promise.resolve(created.requestImmediateScan(trigger)).catch(() => {});
    } else if (typeof created.performOneShotScan === 'function') {
      void Promise.resolve(created.performOneShotScan()).catch(() => {});
    }
    return true;
  }

  function runLifecycleOperation(operation) {
    lifecycleGeneration += 1;
    const generation = lifecycleGeneration;
    const run = () => operation(generation);
    const result = lifecycleTail.then(run, run);
    lifecycleTail = result.catch(() => {});
    return result;
  }

  function ownsLifecycle(generation) {
    return !stopped && generation === lifecycleGeneration;
  }

  async function stopAgentForReplacement() {
    agentGeneration += 1;
    lastAppliedCallbackSequence = 0;
    const current = agent;
    if (!current) {
      target = null;
      return true;
    }
    const quiesced = typeof current.stopAndAwaitQuiescence === 'function'
      ? await current.stopAndAwaitQuiescence(replacementQuiescenceTimeout)
      : (current.stop(), true);
    if (!quiesced) return false;
    if (agent === current) {
      agent = null;
      target = null;
    }
    return true;
  }

  function stopAgentImmediately() {
    agentGeneration += 1;
    lastAppliedCallbackSequence = 0;
    const current = agent;
    agent = null;
    target = null;
    current?.stop?.();
  }

  function markDisconnected(error, configuration) {
    stopAgentImmediately();
    state = snapshotValue('disconnected', configuration || state.configuration, error, state.progress);
    scheduleReconnectRetry();
  }

  function markReplacementDeferred(error, configuration) {
    state = snapshotValue('disconnected', configuration || state.configuration, error, state.progress);
    scheduleReconnectRetry();
  }

  function scheduleReconnectRetry() {
    if (stopped) return;
    retryGeneration += 1;
    const generation = retryGeneration;
    retryScheduled = true;
    scheduleRetry(async () => {
      if (stopped || !retryScheduled || retryGeneration !== generation) return;
      retryScheduled = false;
      try { await retry(); } catch {}
    }, retryDelay);
  }

  function invalidateScheduledRetry() {
    retryGeneration += 1;
    retryScheduled = false;
  }

  function stop() {
    stopped = true;
    lifecycleGeneration += 1;
    invalidateScheduledRetry();
    stopAgentImmediately();
  }

  function requestImmediateScan(trigger) {
    if (stopped || !agent) return;
    if (typeof agent.requestImmediateScan === 'function') {
      void Promise.resolve(agent.requestImmediateScan(trigger)).catch(() => {});
    }
  }

  function recordProgress(progress, selectedTarget, generation, sequence) {
    if (!shouldApplyCallback(selectedTarget, generation, sequence)) return;
    const progressState = progress?.pendingFiles > 0
      ? (progress.phase === 'seeding' ? 'seeding' : 'pending')
      : 'running';
    state = snapshotValue(
      progressState,
      selectedTarget.configuration,
      state.lastError,
      progress,
    );
  }

  function recordStatus(status, selectedTarget, generation, sequence) {
    if (!shouldApplyCallback(selectedTarget, generation, sequence)) return;
    cachedStatus = status ? { ...status } : null;
    const progress = state.progress;
    const statusState = status?.status === 'error'
      ? 'error'
      : progress?.pendingFiles > 0
        ? (progress.phase === 'seeding' ? 'seeding' : 'pending')
        : 'running';
    state = snapshotValue(
      statusState,
      selectedTarget.configuration,
      status?.lastError || null,
      progress,
    );
  }

  function shouldApplyCallback(selectedTarget, generation, sequence) {
    if (generation !== agentGeneration
      || selectedTarget.configuration.deviceId !== target?.configuration?.deviceId
      || sequence <= lastAppliedCallbackSequence) {
      return false;
    }
    lastAppliedCallbackSequence = sequence;
    return true;
  }

  function snapshot() {
    return {
      ...state,
      configuration: state.configuration ? { ...state.configuration } : null,
      progress: state.progress ? { ...state.progress } : null,
      target: target ? { backupRoot: target.backupRoot, localStateRoot: target.localStateRoot } : null,
    };
  }

  function backupStatus() {
    const base = cachedStatus ? { ...cachedStatus } : {
      status: state.state === 'unconfigured' ? 'waiting' : state.state,
      mode: 'polling',
    };
    const runtimeOwnsStatus = ['validating', 'disconnected', 'seeding', 'pending'].includes(state.state);
    return {
      ...base,
      status: runtimeOwnsStatus ? state.state : base.status,
      lastError: state.lastError || base.lastError || null,
      progress: state.progress ? { ...state.progress } : null,
    };
  }

  return Object.freeze({ initialize, activate, retry, stop, snapshot, backupStatus, requestImmediateScan });
}

function snapshotValue(state, configuration = null, error = null, progress = null) {
  return {
    state,
    configuration: configuration ? { ...configuration } : null,
    lastError: error ? (error.message || String(error)) : null,
    progress: progress ? { ...progress } : null,
  };
}

function replacementQuiescenceError() {
  return new Error('The previous backup writer is still finishing its current work; replacement was deferred.');
}

async function defaultStatusLoader(statusPath) {
  try {
    return JSON.parse(await fsp.readFile(statusPath, 'utf8'));
  } catch {
    return null;
  }
}

function defaultCallbackDelivery(action) {
  action();
}

function defaultScheduleRetry(action, delay) {
  const timer = setTimeout(() => { void action(); }, delay);
  timer.unref?.();
  return timer;
}

module.exports = { createNasRuntime };

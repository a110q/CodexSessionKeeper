'use strict';

const path = require('node:path');
const { Worker } = require('node:worker_threads');

const ISOLATED_VERIFICATION_THRESHOLD_BYTES = 8 * 1024 * 1024;
const WORKER_PATH = path.join(__dirname, 'backup-verification-worker.js');
const OPERATIONS = new Set(['verifyFull', 'verifyChangedChunks']);

function abortError() {
  const error = new Error('Backup verification was cancelled.');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

async function runIsolatedBackupVerification({
  operation,
  payload,
  signal = null,
  workerFactory = (workerData) => new Worker(WORKER_PATH, { workerData }),
  onLifecycle = null,
}) {
  if (!OPERATIONS.has(operation)) {
    throw new Error(`Unsupported backup verification operation: ${operation}`);
  }
  if (signal?.aborted) throw abortError();

  const worker = workerFactory({ version: 1, operation, payload });
  let response = null;
  let workerError = null;
  const abort = () => {
    try {
      Promise.resolve(worker.terminate()).catch(() => {});
    } catch (error) {
      workerError ||= error;
    }
  };
  const exit = new Promise((resolve) => {
    worker.once('message', (message) => {
      response = message;
      onLifecycle?.('message');
    });
    worker.once('error', (error) => {
      workerError = error;
    });
    worker.once('exit', resolve);
  });
  signal?.addEventListener('abort', abort, { once: true });
  onLifecycle?.('started');

  try {
    const exitCode = await exit;
    onLifecycle?.('exited');
    if (signal?.aborted) throw abortError();
    if (workerError) throw workerError;
    if (exitCode !== 0
      || !response
      || response.version !== 1
      || typeof response.ok !== 'boolean') {
      throw new Error(`Backup verification Worker failed with exit code ${exitCode}.`);
    }
    if (!response.ok) {
      const error = new Error(String(response.error?.message || 'Backup verification failed.'));
      error.name = String(response.error?.name || 'Error');
      if (response.error?.code !== undefined) error.code = response.error.code;
      throw error;
    }
    return response.result;
  } finally {
    signal?.removeEventListener('abort', abort);
  }
}

module.exports = {
  ISOLATED_VERIFICATION_THRESHOLD_BYTES,
  runIsolatedBackupVerification,
};

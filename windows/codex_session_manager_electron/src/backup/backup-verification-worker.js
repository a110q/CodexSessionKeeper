'use strict';

const { parentPort, workerData } = require('node:worker_threads');

const {
  verifyChangedBackupChunksInProcess,
  verifyFullBackupFileInProcess,
} = require('./backup-file-verifier');

async function main() {
  const { version, operation, payload } = workerData || {};
  if (version !== 1) throw new Error('Unsupported backup verification Worker protocol.');

  let result;
  if (operation === 'verifyFull') {
    result = await verifyFullBackupFileInProcess(payload);
  } else if (operation === 'verifyChangedChunks') {
    result = await verifyChangedBackupChunksInProcess(payload);
  } else {
    throw new Error(`Unsupported backup verification operation: ${operation}`);
  }

  parentPort.postMessage({ version: 1, ok: true, result });
  parentPort.close();
}

main().catch((error) => {
  parentPort.postMessage({
    version: 1,
    ok: false,
    error: {
      name: error.name,
      message: error.message,
      code: error.code,
    },
  });
  parentPort.close();
});

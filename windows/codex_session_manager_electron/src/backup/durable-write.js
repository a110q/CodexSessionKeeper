'use strict';

const fsp = require('node:fs/promises');
const path = require('node:path');

function temporaryPathFor(destination) {
  const nonce = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return path.join(path.dirname(destination), `.${path.basename(destination)}.tmp-${nonce}`);
}

async function writeSyncedTemporaryFile(destination, data, { sync = (handle) => handle.sync() } = {}) {
  const temporaryPath = temporaryPathFor(destination);
  let handle;

  try {
    handle = await fsp.open(temporaryPath, 'wx');
    await handle.writeFile(data);
    await sync(handle);
    await handle.close();
    handle = null;
    return temporaryPath;
  } catch (error) {
    await handle?.close().catch(() => {});
    await fsp.rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function replaceFileDurably(destination, data, options = {}) {
  const temporaryPath = await writeSyncedTemporaryFile(destination, data, options);

  try {
    await fsp.rename(temporaryPath, destination);
  } catch (error) {
    await fsp.rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function writeFileDurably(destination, data, options = {}) {
  const temporaryPath = await writeSyncedTemporaryFile(destination, data, options);

  try {
    // A same-directory hard link publishes the fully synced inode and fails if
    // another writer already created the destination.
    await fsp.link(temporaryPath, destination);
    await fsp.unlink(temporaryPath);
  } catch (error) {
    await fsp.rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

module.exports = {
  replaceFileDurably,
  writeFileDurably,
};

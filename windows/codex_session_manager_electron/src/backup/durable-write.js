'use strict';

const fsp = require('node:fs/promises');
const path = require('node:path');

function temporaryPathFor(destination) {
  const nonce = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return path.join(path.dirname(destination), `.${path.basename(destination)}.tmp-${nonce}`);
}

async function writeSyncedTemporaryFileWithWriter(
  destination,
  writer,
  { sync = (handle) => handle.sync() } = {},
) {
  const temporaryPath = temporaryPathFor(destination);
  let handle;

  try {
    handle = await fsp.open(temporaryPath, 'wx');
    await writer(handle);
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

async function writeSyncedTemporaryFile(destination, data, options = {}) {
  return writeSyncedTemporaryFileWithWriter(
    destination,
    (handle) => handle.writeFile(data),
    options,
  );
}

async function durableReplaceWithWriter(destination, writer, options = {}) {
  const temporaryPath = await writeSyncedTemporaryFileWithWriter(destination, writer, options);

  try {
    await fsp.rename(temporaryPath, destination);
  } catch (error) {
    await fsp.rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function publishSyncedTemporaryFileIfAbsent(temporaryPath, destination, options = {}) {
  const link = options.link || fsp.link;
  const rename = options.rename || fsp.rename;

  try {
    await link(temporaryPath, destination);
    await fsp.unlink(temporaryPath);
    return;
  } catch (error) {
    const unsupported = new Set(['ENOTSUP', 'EOPNOTSUPP', 'EPERM', 'EINVAL']);
    if (!unsupported.has(error.code)) throw error;
  }

  try {
    await fsp.lstat(destination);
    const existsError = new Error(`Destination already exists: ${destination}`);
    existsError.code = 'EEXIST';
    throw existsError;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  await rename(temporaryPath, destination);
}

async function replaceFileDurably(destination, data, options = {}) {
  return durableReplaceWithWriter(destination, (handle) => handle.writeFile(data), options);
}

async function writeFileDurably(destination, data, options = {}) {
  const temporaryPath = await writeSyncedTemporaryFile(destination, data, options);

  try {
    await publishSyncedTemporaryFileIfAbsent(temporaryPath, destination, options);
  } catch (error) {
    await fsp.rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

module.exports = {
  durableReplaceWithWriter,
  publishSyncedTemporaryFileIfAbsent,
  replaceFileDurably,
  writeFileDurably,
};

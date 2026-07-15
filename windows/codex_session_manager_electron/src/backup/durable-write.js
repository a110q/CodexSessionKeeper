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
  const unlink = options.unlink || fsp.unlink;

  try {
    await link(temporaryPath, destination);
  } catch (error) {
    const unsupported = new Set(['ENOTSUP', 'EOPNOTSUPP', 'EPERM', 'EINVAL']);
    if (!unsupported.has(error.code)) throw error;
    const publicationError = new Error(
      `Atomic no-replace publication is unsupported for: ${destination}`,
      { cause: error },
    );
    publicationError.code = 'ATOMIC_NO_REPLACE_UNSUPPORTED';
    throw publicationError;
  }

  // The destination is committed once link succeeds. Temporary cleanup is
  // best effort so a later unlink failure cannot be mistaken for a failed
  // publication; caller-owned orphan cleanup can remove a surviving temp.
  try {
    await unlink(temporaryPath);
  } catch {
    // Publication already succeeded; cleanup is deferred.
  }
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

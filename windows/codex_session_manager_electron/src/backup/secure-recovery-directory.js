'use strict';

const fsp = require('node:fs/promises');
const path = require('node:path');

const { assertSafeDestinationPath } = require('./restore-filesystem');

async function lstatIfExists(targetPath) {
  try {
    return await fsp.lstat(targetPath);
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null;
    throw error;
  }
}

function rejectUnsafeWindowsRoot(root) {
  if (process.platform !== 'win32') return;
  const value = String(root);
  if (/^(?:\\\\[?.]\\|\\\\)/.test(value) || /^[A-Za-z]:[^\\/]/.test(value)) {
    throw new Error(`Unsafe Windows recovery root: ${value}`);
  }
  const parsed = path.win32.parse(value);
  if (value.slice(parsed.root.length).includes(':')) {
    throw new Error(`Windows ADS is not allowed in recovery root: ${value}`);
  }
}

async function validateRealDirectory(directoryPath) {
  const stats = await fsp.lstat(directoryPath);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new Error(`Recovery directory is not a trusted real directory: ${directoryPath}`);
  }
  return fsp.realpath(directoryPath);
}

async function ensureRealDirectory(directoryPath) {
  const existing = await lstatIfExists(directoryPath);
  if (existing) return validateRealDirectory(directoryPath);

  const parent = path.dirname(directoryPath);
  const realParent = await validateRealDirectory(parent);
  try {
    await fsp.mkdir(directoryPath);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  const realDirectory = await validateRealDirectory(directoryPath);
  if (path.dirname(realDirectory) !== realParent) {
    throw new Error(`Recovery directory escaped its trusted parent: ${directoryPath}`);
  }
  return realDirectory;
}

async function createSecureRecoveryDirectory(codexRoot) {
  const root = path.resolve(String(codexRoot || ''));
  if (!path.isAbsolute(String(codexRoot || '')) || root === path.parse(root).root) {
    throw new Error(`Invalid recovery root: ${String(codexRoot)}`);
  }
  rejectUnsafeWindowsRoot(codexRoot);

  const canonicalRoot = await ensureRealDirectory(root);
  const sessions = path.join(root, 'sessions');
  assertSafeDestinationPath(sessions, root);
  await ensureRealDirectory(sessions);
  assertSafeDestinationPath(sessions, root);

  const recovered = path.join(sessions, 'recovered');
  assertSafeDestinationPath(recovered, root);
  const canonicalRecovered = await ensureRealDirectory(recovered);
  assertSafeDestinationPath(recovered, root);
  const relative = path.relative(canonicalRoot, canonicalRecovered);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`Recovery directory escaped the Codex root: ${recovered}`);
  }
  return recovered;
}

module.exports = { createSecureRecoveryDirectory };

const fs = require('node:fs');
const path = require('node:path');

class UnsafeRestoreFilesystemPathError extends Error {
  constructor(targetPath) {
    super(`快照包含不安全的符号链接或真实路径，已拒绝恢复：${String(targetPath)}`);
    this.name = 'UnsafeRestoreFilesystemPathError';
    this.code = 'INVALID_SNAPSHOT_PATH';
    this.targetPath = targetPath;
  }
}

function lstatIfExists(targetPath) {
  try {
    return fs.lstatSync(targetPath);
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null;
    throw error;
  }
}

function relativeDescendant(candidate, root) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new UnsafeRestoreFilesystemPathError(candidate);
  }
  return relative;
}

function canonicalRoot(root) {
  const resolvedRoot = path.resolve(root);
  const rootStat = lstatIfExists(resolvedRoot);
  if (rootStat) {
    if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
      throw new UnsafeRestoreFilesystemPathError(root);
    }
    return fs.realpathSync.native(resolvedRoot);
  }

  const missing = [];
  let existing = resolvedRoot;
  while (!lstatIfExists(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) throw new UnsafeRestoreFilesystemPathError(root);
    missing.unshift(path.basename(existing));
    existing = parent;
  }
  return path.join(fs.realpathSync.native(existing), ...missing);
}

function assertNoLinkedComponents(candidate, root) {
  const relative = relativeDescendant(candidate, root);
  let current = path.resolve(root);
  for (const component of relative.split(path.sep)) {
    current = path.join(current, component);
    const stat = lstatIfExists(current);
    if (!stat) return;
    if (stat.isSymbolicLink()) throw new UnsafeRestoreFilesystemPathError(current);
  }
}

function isContained(candidate, root) {
  const relative = path.relative(root, candidate);
  return !relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative);
}

function assertSafeSourcePath(sourcePath, sourceRoot, { allowMissing = false, recursive = false } = {}) {
  assertNoLinkedComponents(sourcePath, sourceRoot);
  const stat = lstatIfExists(sourcePath);
  if (!stat) {
    if (allowMissing) return path.resolve(sourcePath);
    throw new UnsafeRestoreFilesystemPathError(sourcePath);
  }
  if (stat.isSymbolicLink() || (!stat.isFile() && !stat.isDirectory())) {
    throw new UnsafeRestoreFilesystemPathError(sourcePath);
  }

  const canonicalSourceRoot = canonicalRoot(sourceRoot);
  const canonicalSource = fs.realpathSync.native(sourcePath);
  if (!isContained(canonicalSource, canonicalSourceRoot)) {
    throw new UnsafeRestoreFilesystemPathError(sourcePath);
  }

  if (recursive && stat.isDirectory()) {
    for (const entry of fs.readdirSync(sourcePath)) {
      assertSafeSourcePath(path.join(sourcePath, entry), sourceRoot, { recursive: true });
    }
  }
  return canonicalSource;
}

function assertSafeDestinationPath(destinationPath, destinationRoot, { recursive = false } = {}) {
  assertNoLinkedComponents(destinationPath, destinationRoot);
  const canonicalDestinationRoot = canonicalRoot(destinationRoot);
  const stat = lstatIfExists(destinationPath);
  if (stat?.isSymbolicLink()) throw new UnsafeRestoreFilesystemPathError(destinationPath);
  if (stat && !stat.isFile() && !stat.isDirectory()) {
    throw new UnsafeRestoreFilesystemPathError(destinationPath);
  }

  if (stat) {
    const canonicalDestination = fs.realpathSync.native(destinationPath);
    if (!isContained(canonicalDestination, canonicalDestinationRoot)) {
      throw new UnsafeRestoreFilesystemPathError(destinationPath);
    }
    if (recursive && stat.isDirectory()) {
      for (const entry of fs.readdirSync(destinationPath)) {
        assertSafeDestinationPath(path.join(destinationPath, entry), destinationRoot, { recursive: true });
      }
    }
    return canonicalDestination;
  }

  const relative = relativeDescendant(destinationPath, destinationRoot);
  return path.join(canonicalDestinationRoot, relative);
}

function validateRestoreFilesystem({ restorePaths, sourceRoot, destinationRoot }) {
  for (const restorePath of restorePaths) {
    if (lstatIfExists(restorePath.sourcePath)) {
      assertSafeSourcePath(restorePath.sourcePath, sourceRoot, { recursive: true });
    }
    assertSafeDestinationPath(restorePath.destinationPath, destinationRoot, { recursive: true });
  }
  return Object.freeze([...restorePaths]);
}

function copyRestoreEntry({ sourcePath, destinationPath, sourceRoot, destinationRoot }) {
  assertSafeSourcePath(sourcePath, sourceRoot, { recursive: true });
  assertSafeDestinationPath(destinationPath, destinationRoot, { recursive: true });
  const sourceStat = fs.lstatSync(sourcePath);

  if (lstatIfExists(destinationPath)) fs.rmSync(destinationPath, { recursive: true, force: true });
  assertSafeDestinationPath(destinationPath, destinationRoot);
  if (sourceStat.isDirectory()) {
    fs.mkdirSync(destinationPath, { recursive: true });
    for (const entry of fs.readdirSync(sourcePath)) {
      copyRestoreEntry({
        sourcePath: path.join(sourcePath, entry),
        destinationPath: path.join(destinationPath, entry),
        sourceRoot,
        destinationRoot,
      });
    }
  } else {
    fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
    assertSafeDestinationPath(destinationPath, destinationRoot);
    fs.copyFileSync(sourcePath, destinationPath);
  }
}

function mergeRestoreDirectory({ sourcePath, destinationPath, sourceRoot, destinationRoot }) {
  assertSafeSourcePath(sourcePath, sourceRoot, { recursive: true });
  assertSafeDestinationPath(destinationPath, destinationRoot, { recursive: true });
  fs.mkdirSync(destinationPath, { recursive: true });

  for (const entry of fs.readdirSync(sourcePath)) {
    const entrySource = path.join(sourcePath, entry);
    const entryDestination = path.join(destinationPath, entry);
    const stat = fs.lstatSync(entrySource);
    if (stat.isDirectory()) {
      mergeRestoreDirectory({
        sourcePath: entrySource,
        destinationPath: entryDestination,
        sourceRoot,
        destinationRoot,
      });
    } else {
      copyRestoreEntry({
        sourcePath: entrySource,
        destinationPath: entryDestination,
        sourceRoot,
        destinationRoot,
      });
    }
  }
}

module.exports = {
  UnsafeRestoreFilesystemPathError,
  assertSafeDestinationPath,
  assertSafeSourcePath,
  copyRestoreEntry,
  mergeRestoreDirectory,
  validateRestoreFilesystem,
};

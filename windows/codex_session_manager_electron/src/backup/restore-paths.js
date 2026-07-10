const path = require('node:path').win32;

class InvalidRestorePathError extends Error {
  constructor(relativePath) {
    super(`快照包含不安全路径，已拒绝恢复：${String(relativePath)}`);
    this.name = 'InvalidRestorePathError';
    this.code = 'INVALID_SNAPSHOT_PATH';
    this.relativePath = relativePath;
  }
}

function normalizedRelativePath(rawPath) {
  if (typeof rawPath !== 'string' || !rawPath || rawPath.includes('\0')) {
    throw new InvalidRestorePathError(rawPath);
  }

  const normalized = rawPath.replaceAll('/', '\\');
  const components = normalized.split('\\');
  if (
    path.isAbsolute(normalized)
    || /^[A-Za-z]:/.test(normalized)
    || components.some((component) => !component || component === '.' || component === '..')
  ) {
    throw new InvalidRestorePathError(rawPath);
  }

  return components.join('/');
}

function isDescendant(candidate, root) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return Boolean(relative)
    && relative !== '..'
    && !relative.startsWith('..\\')
    && !path.isAbsolute(relative);
}

function validateRestorePaths({ includedPaths, sourceRoot, destinationRoot }) {
  if (!Array.isArray(includedPaths)) throw new InvalidRestorePathError(includedPaths);

  const validated = includedPaths.map((rawPath) => {
    const relativePath = normalizedRelativePath(rawPath);
    const components = relativePath.split('/');
    const sourcePath = path.resolve(sourceRoot, ...components);
    const destinationPath = path.resolve(destinationRoot, ...components);
    if (!isDescendant(sourcePath, sourceRoot) || !isDescendant(destinationPath, destinationRoot)) {
      throw new InvalidRestorePathError(rawPath);
    }
    return Object.freeze({ relativePath, sourcePath, destinationPath });
  });

  return Object.freeze(validated);
}

module.exports = {
  InvalidRestorePathError,
  validateRestorePaths,
};

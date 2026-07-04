const fs = require('node:fs');
const path = require('node:path');

const { MANIFEST_VERSION } = require('./models');

function isoString(value) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function loadOrCreateManifest(paths, now = new Date()) {
  if (fs.existsSync(paths.manifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(paths.manifestPath, 'utf8'));
    if (!manifest.sessions || typeof manifest.sessions !== 'object') {
      manifest.sessions = {};
    }
    return manifest;
  }

  const timestamp = isoString(now);
  return {
    version: MANIFEST_VERSION,
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    createdAt: timestamp,
    updatedAt: timestamp,
    sessions: {},
  };
}

function sortedValue(value) {
  if (Array.isArray(value)) {
    return value.map(sortedValue);
  }

  if (!value || typeof value !== 'object') {
    return value;
  }

  return Object.keys(value).sort().reduce((result, key) => {
    result[key] = sortedValue(value[key]);
    return result;
  }, {});
}

function saveManifest(paths, manifest) {
  fs.mkdirSync(path.dirname(paths.manifestPath), { recursive: true });

  const tempPath = `${paths.manifestPath}.tmp-${process.pid}-${Date.now()}`;
  const payload = `${JSON.stringify(sortedValue(manifest), null, 2)}\n`;

  try {
    fs.writeFileSync(tempPath, payload, 'utf8');
    fs.renameSync(tempPath, paths.manifestPath);
  } catch (error) {
    try {
      fs.rmSync(tempPath, { force: true });
    } catch {
      // Best effort cleanup after a failed temp write.
    }
    throw error;
  }
}

module.exports = {
  loadOrCreateManifest,
  saveManifest,
};

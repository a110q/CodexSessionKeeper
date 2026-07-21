const crypto = require('node:crypto');

const INVALID_MESSAGE = '更新信息验证失败，请联系管理员';
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SHA256 = /^[a-f0-9]{64}$/;
const PUBLISHED_AT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
const TOP_FIELDS = [
  'schemaVersion', 'channel', 'version', 'build',
  'publishedAt', 'required', 'notes', 'platforms',
];
const ARTIFACT_FIELDS = ['url', 'size', 'sha256'];
const PLATFORM_KEYS = ['macos-arm64', 'windows-x64'];

function invalid(reason) {
  return new Error(`Invalid release manifest: ${reason}`);
}

function exactKeys(value, expected, scope) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw invalid(`${scope} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    const unknown = actual.find((key) => !wanted.includes(key));
    if (unknown) throw invalid(`unknown ${scope} field ${unknown}`);
    throw invalid(`missing ${scope} fields`);
  }
}

function parseVersion(value) {
  if (typeof value !== 'string' || !VERSION.test(value)) {
    throw invalid('version must use numeric X.Y.Z format');
  }
  const components = value.split('.').map(Number);
  if (components.some((component) => !Number.isSafeInteger(component))) {
    throw invalid('version components must be safe integers');
  }
  return components;
}

function validatePublishedAt(value) {
  if (typeof value !== 'string' || !PUBLISHED_AT.test(value)) {
    throw invalid('publishedAt must be an ISO-8601 UTC timestamp');
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw invalid('publishedAt must be an ISO-8601 UTC timestamp');
  }
  const canonical = value.includes('.')
    ? date.toISOString()
    : date.toISOString().replace('.000Z', 'Z');
  if (canonical !== value) {
    throw invalid('publishedAt must be an ISO-8601 UTC timestamp');
  }
}

function validateRelativeArtifactURL(value) {
  if (typeof value !== 'string'
      || value.length === 0
      || value.startsWith('/')
      || value.includes('\\')
      || value.includes('?')
      || value.includes('#')) {
    throw invalid('artifact url must be a safe relative URL');
  }

  let parsed;
  try {
    parsed = new URL(value, 'https://release.invalid/');
  } catch {
    throw invalid('artifact url must be a safe relative URL');
  }
  if (parsed.origin !== 'https://release.invalid' || parsed.username || parsed.password) {
    throw invalid('artifact url must be a safe relative URL');
  }

  const segments = value.split('/');
  if (segments.some((segment) => segment.length === 0)) {
    throw invalid('artifact url must be a safe relative URL');
  }
  for (const segment of segments) {
    let decoded;
    try {
      decoded = decodeURIComponent(segment);
    } catch {
      throw invalid('artifact url must be a safe relative URL');
    }
    if (decoded === '.' || decoded === '..' || decoded.includes('/') || decoded.includes('\\')) {
      throw invalid('artifact url must be a safe relative URL');
    }
  }
}

function validateArtifact(artifact) {
  exactKeys(artifact, ARTIFACT_FIELDS, 'artifact');
  validateRelativeArtifactURL(artifact.url);
  if (!Number.isSafeInteger(artifact.size) || artifact.size <= 0) {
    throw invalid('artifact size must be a positive safe integer');
  }
  if (typeof artifact.sha256 !== 'string' || !SHA256.test(artifact.sha256)) {
    throw invalid('artifact sha256 must be 64 lowercase hexadecimal characters');
  }
}

function validateManifest(manifest) {
  exactKeys(manifest, TOP_FIELDS, 'top level');
  if (manifest.schemaVersion !== 1) throw invalid('schemaVersion must be 1');
  if (manifest.channel !== 'stable') throw invalid('channel must be stable');
  parseVersion(manifest.version);
  if (!Number.isSafeInteger(manifest.build) || manifest.build <= 0) {
    throw invalid('build must be a positive safe integer');
  }
  validatePublishedAt(manifest.publishedAt);
  if (manifest.required !== false) throw invalid('required must be false');
  if (!Array.isArray(manifest.notes) || manifest.notes.length > 20) {
    throw invalid('notes must contain at most 20 entries');
  }
  if (manifest.notes.some((note) => typeof note !== 'string'
      || Buffer.byteLength(note, 'utf8') > 500)) {
    throw invalid('every note must be at most 500 UTF-8 bytes');
  }
  exactKeys(manifest.platforms, PLATFORM_KEYS, 'platforms');
  for (const platform of PLATFORM_KEYS) validateArtifact(manifest.platforms[platform]);
  return manifest;
}

function decodeCanonicalBase64(value, expectedLength, label) {
  const encoded = Buffer.isBuffer(value) ? value.toString('utf8').trim() : String(value).trim();
  const decoded = Buffer.from(encoded, 'base64');
  if (decoded.length !== expectedLength || decoded.toString('base64') !== encoded) {
    throw invalid(`${label} is malformed`);
  }
  return decoded;
}

function parseAndVerifyManifest(manifestBytes, signatureBytes, publicKeyBase64) {
  const bytes = Buffer.from(manifestBytes);
  const signature = decodeCanonicalBase64(signatureBytes, 64, 'signature');
  const rawPublicKey = decodeCanonicalBase64(publicKeyBase64, 32, 'public key');
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, rawPublicKey]),
    format: 'der',
    type: 'spki',
  });
  if (!crypto.verify(null, bytes, publicKey, signature)) {
    throw invalid('signature verification failed');
  }

  let manifest;
  try {
    manifest = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw invalid('JSON does not match schema version 1');
  }
  return validateManifest(manifest);
}

function compareVersions(lhs, rhs) {
  const left = parseVersion(lhs);
  const right = parseVersion(rhs);
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

function selectUpdate(manifest, currentVersion, currentBuild, platform) {
  try {
    validateManifest(manifest);
    parseVersion(currentVersion);
    if (!Number.isSafeInteger(currentBuild) || currentBuild < 0) {
      throw invalid('current build must be a non-negative safe integer');
    }
    if (!PLATFORM_KEYS.includes(platform)) throw invalid('unsupported platform');

    const comparison = compareVersions(manifest.version, currentVersion);
    if (comparison > 0 || (comparison === 0 && manifest.build > currentBuild)) {
      return { status: 'available', manifest, artifact: manifest.platforms[platform] };
    }
    if (comparison === 0 && manifest.build === currentBuild) {
      return { status: 'up-to-date' };
    }
    return { status: 'invalid', message: INVALID_MESSAGE };
  } catch {
    return { status: 'invalid', message: INVALID_MESSAGE };
  }
}

module.exports = {
  INVALID_MESSAGE,
  parseAndVerifyManifest,
  selectUpdate,
};

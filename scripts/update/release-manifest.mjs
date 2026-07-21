import {
  createHash,
  createPublicKey,
  sign,
  verify,
} from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';

const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const VERSION_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
const TOP_LEVEL_FIELDS = [
  'schemaVersion',
  'channel',
  'version',
  'build',
  'publishedAt',
  'required',
  'notes',
  'platforms',
];
const ARTIFACT_FIELDS = ['url', 'size', 'sha256'];
const PLATFORM_KEYS = ['macos-arm64', 'windows-x64'];

function invalid(reason) {
  throw new Error(`Invalid release manifest: ${reason}`);
}

function isPlainObject(value) {
  return value !== null
    && typeof value === 'object'
    && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function rejectUnknownFields(value, allowedFields, scope) {
  for (const field of Object.keys(value)) {
    if (!allowedFields.includes(field)) {
      invalid(`unknown ${scope} field ${field}`);
    }
  }
}

function validateVersion(version) {
  const match = typeof version === 'string' ? VERSION_PATTERN.exec(version) : null;
  if (!match) invalid('version must use numeric X.Y.Z format');
  for (const component of match.slice(1)) {
    if (!Number.isSafeInteger(Number(component))) {
      invalid('version component exceeds the safe integer range');
    }
  }
}

function validateTimestamp(timestamp) {
  if (typeof timestamp !== 'string' || !TIMESTAMP_PATTERN.test(timestamp)) {
    invalid('publishedAt must be an ISO-8601 UTC timestamp');
  }
  const parsed = new Date(timestamp);
  if (Number.isNaN(parsed.valueOf())) {
    invalid('publishedAt must be an ISO-8601 UTC timestamp');
  }
  const normalized = parsed.toISOString();
  const expected = timestamp.includes('.')
    ? timestamp
    : timestamp.replace(/Z$/, '.000Z');
  if (normalized !== expected) {
    invalid('publishedAt must be a canonical ISO-8601 UTC timestamp');
  }
}

function validateRelativeURL(value) {
  if (typeof value !== 'string' || value.length === 0 || value.startsWith('/')) {
    invalid('artifact url must be a safe relative URL');
  }
  if (value.includes('\\') || value.includes('?') || value.includes('#')) {
    invalid('artifact url must be a safe relative URL');
  }
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) {
    invalid('artifact url must be a safe relative URL');
  }

  const segments = value.split('/');
  if (segments.some((segment) => segment.length === 0)) {
    invalid('artifact url must be a safe relative URL');
  }
  for (const segment of segments) {
    let decoded;
    try {
      decoded = decodeURIComponent(segment);
    } catch {
      invalid('artifact url must be a safe relative URL');
    }
    if (decoded === '.' || decoded === '..' || decoded.includes('/') || decoded.includes('\\')) {
      invalid('artifact url must be a safe relative URL');
    }
  }
}

function validateArtifact(value, platform) {
  if (!isPlainObject(value)) invalid(`${platform} artifact must be an object`);
  rejectUnknownFields(value, ARTIFACT_FIELDS, platform);
  for (const field of ARTIFACT_FIELDS) {
    if (!Object.hasOwn(value, field)) invalid(`${platform} artifact is missing ${field}`);
  }

  validateRelativeURL(value.url);
  if (!Number.isSafeInteger(value.size) || value.size <= 0) {
    invalid(`${platform} size must be a positive safe integer`);
  }
  if (typeof value.sha256 !== 'string' || !SHA256_PATTERN.test(value.sha256)) {
    invalid(`${platform} sha256 must be 64 lowercase hexadecimal characters`);
  }

  return {
    url: value.url,
    size: value.size,
    sha256: value.sha256,
  };
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!isPlainObject(value)) return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, stableValue(value[key])]),
  );
}

function decodeBase64(value, expectedLength) {
  if (typeof value !== 'string') return null;
  const encoded = value.trim();
  if (encoded.length === 0 || encoded.length % 4 !== 0 || !BASE64_PATTERN.test(encoded)) {
    return null;
  }
  const decoded = Buffer.from(encoded, 'base64');
  if (decoded.length !== expectedLength || decoded.toString('base64') !== encoded) {
    return null;
  }
  return decoded;
}

export function validateManifest(value) {
  if (!isPlainObject(value)) invalid('top level must be an object');
  rejectUnknownFields(value, TOP_LEVEL_FIELDS, 'top-level');
  for (const field of TOP_LEVEL_FIELDS) {
    if (!Object.hasOwn(value, field)) invalid(`missing top-level field ${field}`);
  }

  if (value.schemaVersion !== 1) invalid('schemaVersion must be 1');
  if (value.channel !== 'stable') invalid('channel must be stable');
  validateVersion(value.version);
  if (!Number.isSafeInteger(value.build) || value.build <= 0) {
    invalid('build must be a positive safe integer');
  }
  validateTimestamp(value.publishedAt);
  if (value.required !== false) invalid('required must be false');

  if (!Array.isArray(value.notes) || value.notes.length > 20) {
    invalid('notes must contain at most 20 entries');
  }
  const notes = value.notes.map((note) => {
    if (typeof note !== 'string') invalid('every note must be a string');
    if (Buffer.byteLength(note, 'utf8') > 500) {
      invalid('every note must be at most 500 UTF-8 bytes');
    }
    return note;
  });

  if (!isPlainObject(value.platforms)) invalid('platforms must be an object');
  const actualPlatforms = Object.keys(value.platforms).sort();
  if (actualPlatforms.length !== PLATFORM_KEYS.length
      || !actualPlatforms.every((key, index) => key === PLATFORM_KEYS[index])) {
    invalid('platforms must contain macos-arm64 and windows-x64 only');
  }

  return {
    schemaVersion: 1,
    channel: 'stable',
    version: value.version,
    build: value.build,
    publishedAt: value.publishedAt,
    required: false,
    notes,
    platforms: {
      'macos-arm64': validateArtifact(value.platforms['macos-arm64'], 'macos-arm64'),
      'windows-x64': validateArtifact(value.platforms['windows-x64'], 'windows-x64'),
    },
  };
}

export function stableManifestBytes(manifest) {
  return Buffer.from(`${JSON.stringify(stableValue(manifest), null, 2)}\n`, 'utf8');
}

export function signManifest(bytes, privateKeyPem) {
  return sign(null, bytes, privateKeyPem).toString('base64');
}

export function verifyManifest(bytes, signatureBase64, publicKeyBase64) {
  const signature = decodeBase64(signatureBase64, 64);
  const rawPublicKey = decodeBase64(publicKeyBase64, 32);
  if (signature === null || rawPublicKey === null) return false;

  try {
    const publicKey = createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, rawPublicKey]),
      format: 'der',
      type: 'spki',
    });
    return verify(null, bytes, publicKey, signature);
  } catch {
    return false;
  }
}

export async function sha256File(filePath) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  const metadata = await stat(filePath);
  if (!metadata.isFile()) throw new Error(`Release artifact is not a regular file: ${filePath}`);
  return { size: metadata.size, sha256: hash.digest('hex') };
}

const assert = require('node:assert/strict');
const { generateKeyPairSync, sign } = require('node:crypto');
const test = require('node:test');

const {
  parseAndVerifyManifest,
  selectUpdate,
} = require('../../src/update/release-manifest');

function fixture(overrides = {}) {
  return {
    schemaVersion: 1,
    channel: 'stable',
    version: '1.1.0',
    build: 10100,
    publishedAt: '2026-07-21T00:00:00Z',
    required: false,
    notes: ['新增公司内网更新功能'],
    platforms: {
      'macos-arm64': {
        url: 'macos/CodexSessionKeeper-1.1.0-macos-arm64.zip',
        size: 12,
        sha256: 'a'.repeat(64),
      },
      'windows-x64': {
        url: 'windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe',
        size: 34,
        sha256: 'b'.repeat(64),
      },
    },
    ...overrides,
  };
}

function signedManifest(manifest = fixture()) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  const signature = Buffer.from(sign(null, bytes, privateKey).toString('base64'));
  const publicKeyBase64 = publicKey.export({ format: 'der', type: 'spki' })
    .subarray(-32)
    .toString('base64');
  return { bytes, publicKeyBase64, signature };
}

test('verifies exact manifest bytes and selects a newer Windows release', () => {
  const signed = signedManifest();
  const manifest = parseAndVerifyManifest(
    signed.bytes,
    signed.signature,
    signed.publicKeyBase64,
  );

  const result = selectUpdate(manifest, '1.0.99', 10099, 'windows-x64');
  assert.equal(result.status, 'available');
  assert.equal(result.manifest.version, '1.1.0');
  assert.match(result.artifact.url, /windows-x64-Setup\.exe$/);
});

test('rejects a one-byte manifest change before parsing it', () => {
  const signed = signedManifest();
  signed.bytes[signed.bytes.length - 2] ^= 1;
  assert.throws(
    () => parseAndVerifyManifest(signed.bytes, signed.signature, signed.publicKeyBase64),
    /signature/i,
  );
});

test('rejects forced updates and unsafe artifact fields', () => {
  const forced = signedManifest(fixture({ required: true }));
  assert.throws(
    () => parseAndVerifyManifest(forced.bytes, forced.signature, forced.publicKeyBase64),
    /required must be false/,
  );

  const unsafeManifest = fixture();
  unsafeManifest.platforms['windows-x64'].url = 'http://attacker.invalid/update.exe';
  const unsafe = signedManifest(unsafeManifest);
  assert.throws(
    () => parseAndVerifyManifest(unsafe.bytes, unsafe.signature, unsafe.publicKeyBase64),
    /relative URL/,
  );
});

test('uses numeric versions and rejects downgrades', () => {
  const signed = signedManifest(fixture({ version: '1.10.0', build: 11000 }));
  const manifest = parseAndVerifyManifest(signed.bytes, signed.signature, signed.publicKeyBase64);
  assert.equal(selectUpdate(manifest, '1.9.9', 10909, 'windows-x64').status, 'available');
  assert.deepEqual(selectUpdate(manifest, '1.10.0', 11000, 'windows-x64'), {
    status: 'up-to-date',
  });
  assert.deepEqual(selectUpdate(manifest, '2.0.0', 20000, 'windows-x64'), {
    status: 'invalid',
    message: '更新信息验证失败，请联系管理员',
  });
});

test('rejects version components above the safe integer range', () => {
  const signed = signedManifest(fixture({ version: '9007199254740992.0.0' }));
  assert.throws(
    () => parseAndVerifyManifest(signed.bytes, signed.signature, signed.publicKeyBase64),
    /version/i,
  );
});

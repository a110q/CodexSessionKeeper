import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  sha256File,
  signManifest,
  stableManifestBytes,
  validateManifest,
  verifyManifest,
} from './release-manifest.mjs';

function fixture() {
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
  };
}

test('serializes equivalent manifests to identical stable UTF-8 bytes', () => {
  const manifest = fixture();
  const reordered = {
    platforms: {
      'windows-x64': { ...manifest.platforms['windows-x64'] },
      'macos-arm64': { ...manifest.platforms['macos-arm64'] },
    },
    notes: [...manifest.notes],
    required: manifest.required,
    publishedAt: manifest.publishedAt,
    build: manifest.build,
    version: manifest.version,
    channel: manifest.channel,
    schemaVersion: manifest.schemaVersion,
  };

  const first = stableManifestBytes(validateManifest(manifest));
  const second = stableManifestBytes(validateManifest(reordered));

  assert.deepEqual(first, second);
  assert.equal(first.at(-1), 0x0a);
});

test('signs exact manifest bytes and rejects one-byte tampering', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const bytes = stableManifestBytes(validateManifest(fixture()));
  const signature = signManifest(
    bytes,
    privateKey.export({ type: 'pkcs8', format: 'pem' }),
  );
  const publicKeyBase64 = publicKey
    .export({ type: 'spki', format: 'der' })
    .subarray(-32)
    .toString('base64');

  assert.equal(verifyManifest(bytes, signature, publicKeyBase64), true);
  const tampered = Buffer.from(bytes);
  tampered[tampered.length - 2] ^= 1;
  assert.equal(verifyManifest(tampered, signature, publicKeyBase64), false);
  assert.equal(verifyManifest(bytes, 'not-base64', publicKeyBase64), false);
  assert.equal(verifyManifest(bytes, signature, Buffer.alloc(31).toString('base64')), false);
});

test('rejects forced updates and unsafe artifact URLs', () => {
  assert.throws(
    () => validateManifest({ ...fixture(), required: true }),
    /required must be false/,
  );

  for (const unsafeURL of [
    'http://attacker.invalid/app.zip',
    '/macos/app.zip',
    '../macos/app.zip',
    'macos/../app.zip',
    'macos/app.zip?token=x',
    'macos/app.zip#fragment',
    'macos\\app.zip',
  ]) {
    const manifest = fixture();
    manifest.platforms['macos-arm64'].url = unsafeURL;
    assert.throws(() => validateManifest(manifest), /relative URL/);
  }
});

test('rejects unknown fields and an incomplete platform set', () => {
  assert.throws(
    () => validateManifest({ ...fixture(), extra: true }),
    /unknown top-level field extra/,
  );

  const unknownArtifactField = fixture();
  unknownArtifactField.platforms['macos-arm64'].extra = true;
  assert.throws(
    () => validateManifest(unknownArtifactField),
    /unknown macos-arm64 field extra/,
  );

  const missingPlatform = fixture();
  delete missingPlatform.platforms['windows-x64'];
  assert.throws(
    () => validateManifest(missingPlatform),
    /platforms must contain macos-arm64 and windows-x64 only/,
  );
});

test('rejects invalid versions, hashes, sizes, dates, and excessive notes', () => {
  for (const version of ['1.1', '1.1.0-beta', '01.1.0', '1.-1.0']) {
    assert.throws(() => validateManifest({ ...fixture(), version }), /version/);
  }

  const badHash = fixture();
  badHash.platforms['macos-arm64'].sha256 = 'A'.repeat(64);
  assert.throws(() => validateManifest(badHash), /sha256/);

  const badSize = fixture();
  badSize.platforms['windows-x64'].size = 0;
  assert.throws(() => validateManifest(badSize), /size/);

  assert.throws(
    () => validateManifest({ ...fixture(), publishedAt: 'not-a-date' }),
    /publishedAt/,
  );
  assert.throws(
    () => validateManifest({ ...fixture(), notes: Array(21).fill('note') }),
    /at most 20/,
  );
  assert.throws(
    () => validateManifest({ ...fixture(), notes: ['字'.repeat(167)] }),
    /500 UTF-8 bytes/,
  );
});

test('returns a deep clone rather than caller-owned manifest objects', () => {
  const source = fixture();
  const validated = validateManifest(source);
  validated.platforms['macos-arm64'].size = 99;
  validated.notes[0] = 'changed';

  assert.equal(source.platforms['macos-arm64'].size, 12);
  assert.equal(source.notes[0], '新增公司内网更新功能');
});

test('hashes a release artifact and reports its exact size', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codex-release-manifest-'));
  try {
    const artifactPath = path.join(root, 'artifact.bin');
    await writeFile(artifactPath, Buffer.from('signed artifact', 'utf8'));

    assert.deepEqual(await sha256File(artifactPath), {
      size: 15,
      sha256: 'd47929d2c71abeb96335f7c202caec40c34f2a38699f503fa4adc43c45b383c9',
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

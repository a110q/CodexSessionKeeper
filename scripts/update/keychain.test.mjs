import test from 'node:test';
import assert from 'node:assert/strict';
import { createPrivateKey, generateKeyPairSync } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  MANIFEST_KEY_ACCOUNT,
  MANIFEST_KEY_SERVICE,
  ensureManifestKey,
} from './keychain.mjs';
import { writePublicKeyConfig } from './generate-update-keys.mjs';

function generatedKey() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return {
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    publicKeyBase64: publicKey
      .export({ type: 'spki', format: 'der' })
      .subarray(-32)
      .toString('base64'),
  };
}

function storedPrivateKey(privateKeyPem) {
  return createPrivateKey(privateKeyPem)
    .export({ type: 'pkcs8', format: 'der' })
    .toString('base64');
}

test('reuses an existing manifest key without replacing it', () => {
  const existing = generatedKey();
  const calls = [];
  const result = ensureManifestKey({
    runSecurity(args) {
      calls.push(args);
      return existing.privateKeyPem;
    },
    generateKeyPair() {
      assert.fail('must not generate a replacement key');
    },
  });

  assert.equal(result.created, false);
  assert.equal(result.privateKeyPem, existing.privateKeyPem);
  assert.equal(result.publicKeyBase64, existing.publicKeyBase64);
  assert.deepEqual(calls, [[
    'find-generic-password',
    '-a', MANIFEST_KEY_ACCOUNT,
    '-s', MANIFEST_KEY_SERVICE,
    '-w',
  ]]);
});

test('creates and stores a manifest key only when Keychain has no item', () => {
  const generated = generatedKey();
  const calls = [];
  const missing = Object.assign(new Error('not found'), { status: 44 });
  const result = ensureManifestKey({
    runSecurity(args) {
      calls.push(args);
      if (args[0] === 'find-generic-password') throw missing;
      return '';
    },
    generateKeyPair() {
      return generated;
    },
  });

  assert.equal(result.created, true);
  assert.equal(result.publicKeyBase64, generated.publicKeyBase64);
  assert.deepEqual(calls[1], [
    'add-generic-password',
    '-U',
    '-a', MANIFEST_KEY_ACCOUNT,
    '-s', MANIFEST_KEY_SERVICE,
    '-l', MANIFEST_KEY_SERVICE,
    '-w', storedPrivateKey(generated.privateKeyPem),
  ]);
});

test('migrates macOS security hex output to printable base64 DER', () => {
  const existing = generatedKey();
  const securityHexOutput = Buffer.from(existing.privateKeyPem, 'utf8').toString('hex');
  const calls = [];

  const result = ensureManifestKey({
    runSecurity(args) {
      calls.push(args);
      if (args[0] === 'find-generic-password') return securityHexOutput;
      return '';
    },
  });

  assert.equal(result.created, false);
  assert.equal(result.privateKeyPem, existing.privateKeyPem);
  assert.equal(result.publicKeyBase64, existing.publicKeyBase64);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].at(-2), '-w');
  assert.equal(calls[1].at(-1), storedPrivateKey(existing.privateKeyPem));
  assert.doesNotMatch(calls[1].at(-1), /PRIVATE KEY|\n/);
});

test('writes only validated public keys to tracked configuration', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codex-update-keys-'));
  try {
    const configPath = path.join(root, 'Config', 'UpdateKeys.json');
    const manifestKey = generatedKey();
    const sparkleKey = generatedKey();

    await writePublicKeyConfig({
      configPath,
      manifestPublicKey: manifestKey.publicKeyBase64,
      sparklePublicEDKey: sparkleKey.publicKeyBase64,
    });

    const text = await readFile(configPath, 'utf8');
    assert.deepEqual(JSON.parse(text), {
      schemaVersion: 1,
      manifestPublicKey: manifestKey.publicKeyBase64,
      sparklePublicEDKey: sparkleKey.publicKeyBase64,
    });
    assert.doesNotMatch(text, /PRIVATE KEY|privateKey/);
    assert.equal(text.endsWith('\n'), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('rejects malformed raw public keys before writing configuration', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codex-update-keys-'));
  try {
    await assert.rejects(
      () => writePublicKeyConfig({
        configPath: path.join(root, 'UpdateKeys.json'),
        manifestPublicKey: Buffer.alloc(31).toString('base64'),
      }),
      /manifestPublicKey must encode exactly 32 bytes/,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  sha256File,
  signManifest,
  stableManifestBytes,
  validateManifest,
  verifyManifest,
} from './release-manifest.mjs';
import { assembleRelease } from './build-release-manifest.mjs';
import { UPDATE_SERVER, updateServerForScope } from './update-server.mjs';
import { verifyReleaseDirectory } from './verify-release-directory.mjs';

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

function ephemeralKey() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return {
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    publicKeyBase64: publicKey.export({ type: 'spki', format: 'der' })
      .subarray(-32)
      .toString('base64'),
  };
}

function signedAppcast({
  version,
  build,
  zipName,
  zipBytes,
  privateKeyPem,
  downloadPrefix = UPDATE_SERVER.macDownloadPrefix,
}) {
  const enclosureSignature = signManifest(zipBytes, privateKeyPem);
  const prefix = Buffer.from(
    `<?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><title>${version}</title><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${version}</sparkle:shortVersionString><enclosure url="${downloadPrefix}${zipName}" length="${zipBytes.length}" type="application/octet-stream" sparkle:edSignature="${enclosureSignature}"></enclosure></item></channel></rss>`,
  );
  const feedSignature = signManifest(prefix, privateKeyPem);
  return Buffer.concat([
    prefix,
    Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${feedSignature}\nlength: ${prefix.length}\n-->\n`),
  ]);
}

async function makeReleaseFixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codex-release-directory-'));
  const stableRoot = path.join(root, 'codex-session-keeper', 'stable');
  const macDirectory = path.join(stableRoot, 'macos');
  const windowsDirectory = path.join(stableRoot, 'windows');
  await mkdir(macDirectory, { recursive: true });
  await mkdir(windowsDirectory, { recursive: true });

  const manifestKey = ephemeralKey();
  const sparkleKey = ephemeralKey();
  const macName = 'CodexSessionKeeper-1.1.0-macos-arm64.zip';
  const windowsName = 'CodexSessionKeeper-1.1.0-windows-x64-Setup.exe';
  const macZip = path.join(macDirectory, macName);
  const windowsInstaller = path.join(windowsDirectory, windowsName);
  const macBytes = Buffer.from('mac archive');
  const windowsBytes = Buffer.from('windows installer');
  await writeFile(macZip, macBytes);
  await writeFile(windowsInstaller, windowsBytes);
  await writeFile(
    path.join(macDirectory, 'appcast.xml'),
    signedAppcast({
      version: '1.1.0',
      build: 10100,
      zipName: macName,
      zipBytes: macBytes,
      privateKeyPem: sparkleKey.privateKeyPem,
    }),
  );
  await writeFile(
    path.join(windowsDirectory, 'latest.yml'),
    `version: 1.1.0\nfiles:\n  - url: ${windowsName}\n    size: ${windowsBytes.length}\npath: ${windowsName}\n`,
  );

  const manifest = validateManifest({
    ...fixture(),
    platforms: {
      'macos-arm64': { url: `macos/${macName}`, ...(await sha256File(macZip)) },
      'windows-x64': { url: `windows/${windowsName}`, ...(await sha256File(windowsInstaller)) },
    },
  });
  const bytes = stableManifestBytes(manifest);
  await writeFile(path.join(stableRoot, 'release.json'), bytes);
  await writeFile(
    path.join(stableRoot, 'release.json.sig'),
    `${signManifest(bytes, manifestKey.privateKeyPem)}\n`,
  );
  return {
    manifestKey,
    root,
    sparkleKey,
    stableRoot,
    windowsInstaller,
  };
}

test('assembles signed release metadata with actual artifact hashes', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codex-release-assembly-'));
  try {
    const inputs = path.join(root, 'inputs');
    await mkdir(inputs);
    const macZip = path.join(inputs, 'CodexSessionKeeper-1.1.0-macos-arm64.zip');
    const windowsExe = path.join(inputs, 'CodexSessionKeeper-1.1.0-windows-x64-Setup.exe');
    const windowsYml = path.join(inputs, 'latest.yml');
    const notesFile = path.join(inputs, 'notes.json');
    await writeFile(macZip, 'mac archive');
    await writeFile(windowsExe, 'windows installer');
    await writeFile(windowsYml, `version: 1.1.0\npath: ${path.basename(windowsExe)}\nfiles:\n  - url: ${path.basename(windowsExe)}\n`);
    await writeFile(notesFile, JSON.stringify(['新增公司内网更新功能']));

    const manifestKey = ephemeralKey();
    const sparkleKey = ephemeralKey();
    const output = path.join(root, 'output');
    const result = await assembleRelease({
      build: 10100,
      generateAppcast: async ({ macDirectory, zipName, zipBytes }) => {
        await writeFile(
          path.join(macDirectory, 'appcast.xml'),
          signedAppcast({
            version: '1.1.0',
            build: 10100,
            zipName,
            zipBytes,
            privateKeyPem: sparkleKey.privateKeyPem,
          }),
        );
      },
      macZip,
      manifestPrivateKeyPem: manifestKey.privateKeyPem,
      manifestPublicKeyBase64: manifestKey.publicKeyBase64,
      notesFile,
      output,
      publishedAt: '2026-07-21T00:00:00Z',
      sparklePublicKeyBase64: sparkleKey.publicKeyBase64,
      version: '1.1.0',
      windowsExe,
      windowsYml,
    });
    const manifest = JSON.parse(await readFile(path.join(result.stableRoot, 'release.json')));
    assert.equal(manifest.platforms['macos-arm64'].url, 'macos/CodexSessionKeeper-1.1.0-macos-arm64.zip');
    assert.equal(manifest.platforms['windows-x64'].url, 'windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe');
    assert.deepEqual(await verifyReleaseDirectory(
      result.stableRoot,
      manifestKey.publicKeyBase64,
      { sparklePublicKeyBase64: sparkleKey.publicKeyBase64 },
    ), { verified: true, version: '1.1.0', build: 10100 });

    const candidateOutput = path.join(root, 'candidate-output');
    const candidate = await assembleRelease({
      build: 10100,
      generateAppcast: async ({
        downloadPrefix,
        macDirectory,
        zipName,
        zipBytes,
      }) => {
        await writeFile(
          path.join(macDirectory, 'appcast.xml'),
          signedAppcast({
            version: '1.1.0',
            build: 10100,
            zipName,
            zipBytes,
            privateKeyPem: sparkleKey.privateKeyPem,
            downloadPrefix,
          }),
        );
      },
      macZip,
      manifestPrivateKeyPem: manifestKey.privateKeyPem,
      manifestPublicKeyBase64: manifestKey.publicKeyBase64,
      notesFile,
      output: candidateOutput,
      publishedAt: '2026-07-21T00:00:00Z',
      sparklePublicKeyBase64: sparkleKey.publicKeyBase64,
      updateServer: updateServerForScope('testing'),
      version: '1.1.0',
      windowsExe,
      windowsYml,
    });
    const appcast = await readFile(
      path.join(candidate.releaseRoot, 'macos', 'appcast.xml'),
      'utf8',
    );
    assert.match(
      appcast,
      /http:\/\/192\.168\.10\.54:18080\/codex-session-keeper\/testing\/macos\//,
    );
    assert.doesNotMatch(appcast, /\/stable\/macos\//);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('release verifier detects artifact tampering', async () => {
  const release = await makeReleaseFixture();
  try {
    await verifyReleaseDirectory(release.stableRoot, release.manifestKey.publicKeyBase64, {
      sparklePublicKeyBase64: release.sparkleKey.publicKeyBase64,
    });
    await appendFile(release.windowsInstaller, Buffer.from([0]));
    await assert.rejects(
      () => verifyReleaseDirectory(release.stableRoot, release.manifestKey.publicKeyBase64, {
        sparklePublicKeyBase64: release.sparkleKey.publicKeyBase64,
      }),
      /sha256 mismatch/,
    );
  } finally {
    await rm(release.root, { recursive: true, force: true });
  }
});

test('release verifier rejects mismatched Electron and Sparkle metadata', async () => {
  const release = await makeReleaseFixture();
  try {
    const latestPath = path.join(release.stableRoot, 'windows', 'latest.yml');
    await writeFile(latestPath, 'version: 1.1.1\npath: wrong.exe\n');
    await assert.rejects(
      () => verifyReleaseDirectory(release.stableRoot, release.manifestKey.publicKeyBase64, {
        sparklePublicKeyBase64: release.sparkleKey.publicKeyBase64,
      }),
      /latest\.yml/,
    );

    const refreshed = await makeReleaseFixture();
    try {
      const appcastPath = path.join(refreshed.stableRoot, 'macos', 'appcast.xml');
      const appcast = await readFile(appcastPath, 'utf8');
      await writeFile(appcastPath, appcast.replaceAll('1.1.0', '1.1.1'));
      await assert.rejects(
        () => verifyReleaseDirectory(refreshed.stableRoot, refreshed.manifestKey.publicKeyBase64, {
          sparklePublicKeyBase64: refreshed.sparkleKey.publicKeyBase64,
        }),
        /appcast|Sparkle/i,
      );
    } finally {
      await rm(refreshed.root, { recursive: true, force: true });
    }
  } finally {
    await rm(release.root, { recursive: true, force: true });
  }
});

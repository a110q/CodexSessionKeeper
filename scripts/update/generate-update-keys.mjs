import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { ensureManifestKey } from './keychain.mjs';

function decodeRawPublicKey(name, value) {
  if (typeof value !== 'string') {
    throw new Error(`${name} must encode exactly 32 bytes`);
  }
  const encoded = value.trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length % 4 !== 0) {
    throw new Error(`${name} must encode exactly 32 bytes`);
  }
  const decoded = Buffer.from(encoded, 'base64');
  if (decoded.length !== 32 || decoded.toString('base64') !== encoded) {
    throw new Error(`${name} must encode exactly 32 bytes`);
  }
  return encoded;
}

export async function writePublicKeyConfig({
  configPath,
  manifestPublicKey,
  sparklePublicEDKey,
}) {
  const output = {
    schemaVersion: 1,
    manifestPublicKey: decodeRawPublicKey('manifestPublicKey', manifestPublicKey),
  };
  if (sparklePublicEDKey !== undefined) {
    output.sparklePublicEDKey = decodeRawPublicKey('sparklePublicEDKey', sparklePublicEDKey);
  }

  await mkdir(path.dirname(configPath), { recursive: true });
  await writeFile(configPath, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
}

function parseArguments(argv) {
  if (argv.length === 0) return {};
  if (argv.length === 2 && argv[0] === '--sparkle-public-key') {
    return { sparklePublicEDKey: argv[1] };
  }
  throw new Error('usage: generate-update-keys.mjs [--sparkle-public-key BASE64]');
}

async function main() {
  const { sparklePublicEDKey } = parseArguments(process.argv.slice(2));
  const projectRoot = fileURLToPath(new URL('../../', import.meta.url));
  const manifestKey = ensureManifestKey();
  await writePublicKeyConfig({
    configPath: path.join(projectRoot, 'Config', 'UpdateKeys.json'),
    manifestPublicKey: manifestKey.publicKeyBase64,
    sparklePublicEDKey,
  });
  const action = manifestKey.created ? 'created' : 'reused';
  process.stdout.write(`Manifest signing key ${action}; public configuration updated.\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

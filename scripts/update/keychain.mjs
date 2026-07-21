import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
} from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const MANIFEST_KEY_SERVICE = 'CodexSessionKeeper Update Manifest Ed25519';
export const MANIFEST_KEY_ACCOUNT = 'release';

function defaultRunSecurity(args) {
  return execFileSync('/usr/bin/security', args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function defaultGenerateKeyPair() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return {
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    publicKeyBase64: publicKey
      .export({ type: 'spki', format: 'der' })
      .subarray(-32)
      .toString('base64'),
  };
}

function publicKeyBase64(privateKey) {
  const der = createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  if (der.length !== prefix.length + 32 || !der.subarray(0, prefix.length).equals(prefix)) {
    throw new Error('Keychain item is not an Ed25519 PKCS#8 private key');
  }
  return der.subarray(prefix.length).toString('base64');
}

function storedPrivateKey(privateKey) {
  return privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
}

function decodeStoredPrivateKey(value) {
  const stored = String(value).trim();
  if (stored.startsWith('-----BEGIN PRIVATE KEY-----')) {
    return { privateKey: createPrivateKey(`${stored}\n`), needsMigration: false };
  }

  if (stored.length > 0 && stored.length % 2 === 0 && /^[0-9a-f]+$/i.test(stored)) {
    const legacyPem = Buffer.from(stored, 'hex').toString('utf8');
    return { privateKey: createPrivateKey(legacyPem), needsMigration: true };
  }

  if (stored.length > 0 && stored.length % 4 === 0 && /^[A-Za-z0-9+/]+={0,2}$/.test(stored)) {
    const der = Buffer.from(stored, 'base64');
    if (der.toString('base64') === stored) {
      return {
        privateKey: createPrivateKey({ key: der, type: 'pkcs8', format: 'der' }),
        needsMigration: false,
      };
    }
  }

  throw new Error('Keychain item is not a supported Ed25519 private key');
}

function storeArguments(secret) {
  return [
    'add-generic-password',
    '-U',
    '-a', MANIFEST_KEY_ACCOUNT,
    '-s', MANIFEST_KEY_SERVICE,
    '-l', MANIFEST_KEY_SERVICE,
    '-w', secret,
  ];
}

export function ensureManifestKey({
  runSecurity = defaultRunSecurity,
  generateKeyPair = defaultGenerateKeyPair,
} = {}) {
  const findArguments = [
    'find-generic-password',
    '-a', MANIFEST_KEY_ACCOUNT,
    '-s', MANIFEST_KEY_SERVICE,
    '-w',
  ];

  try {
    const decoded = decodeStoredPrivateKey(runSecurity(findArguments));
    if (decoded.needsMigration) {
      runSecurity(storeArguments(storedPrivateKey(decoded.privateKey)));
    }
    const privateKeyPem = decoded.privateKey.export({ type: 'pkcs8', format: 'pem' });
    return {
      created: false,
      privateKeyPem,
      publicKeyBase64: publicKeyBase64(decoded.privateKey),
    };
  } catch (error) {
    if (error?.status !== 44) throw error;
  }

  const generated = generateKeyPair();
  const privateKey = createPrivateKey(generated.privateKeyPem);
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const derivedPublicKey = publicKeyBase64(privateKey);
  if (derivedPublicKey !== generated.publicKeyBase64) {
    throw new Error('Generated Ed25519 public key does not match its private key');
  }

  runSecurity(storeArguments(storedPrivateKey(privateKey)));

  return {
    created: true,
    privateKeyPem,
    publicKeyBase64: derivedPublicKey,
  };
}

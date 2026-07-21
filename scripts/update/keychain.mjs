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

function publicKeyBase64(privateKeyPem) {
  const privateKey = createPrivateKey(privateKeyPem);
  const der = createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  if (der.length !== prefix.length + 32 || !der.subarray(0, prefix.length).equals(prefix)) {
    throw new Error('Keychain item is not an Ed25519 PKCS#8 private key');
  }
  return der.subarray(prefix.length).toString('base64');
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
    const privateKeyPem = `${String(runSecurity(findArguments)).trimEnd()}\n`;
    return {
      created: false,
      privateKeyPem,
      publicKeyBase64: publicKeyBase64(privateKeyPem),
    };
  } catch (error) {
    if (error?.status !== 44) throw error;
  }

  const generated = generateKeyPair();
  const privateKeyPem = String(generated.privateKeyPem);
  const derivedPublicKey = publicKeyBase64(privateKeyPem);
  if (derivedPublicKey !== generated.publicKeyBase64) {
    throw new Error('Generated Ed25519 public key does not match its private key');
  }

  runSecurity([
    'add-generic-password',
    '-U',
    '-a', MANIFEST_KEY_ACCOUNT,
    '-s', MANIFEST_KEY_SERVICE,
    '-l', MANIFEST_KEY_SERVICE,
    '-w', privateKeyPem,
  ]);

  return {
    created: true,
    privateKeyPem,
    publicKeyBase64: derivedPublicKey,
  };
}


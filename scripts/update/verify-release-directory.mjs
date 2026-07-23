#!/usr/bin/env node
import { realpathSync } from 'node:fs';
import { readFile, readdir, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  sha256File,
  stableManifestBytes,
  validateManifest,
  verifyManifest,
} from './release-manifest.mjs';
import { UPDATE_SERVER } from './update-server.mjs';

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(MODULE_DIRECTORY, '..', '..');
const UPDATE_KEYS_PATH = path.join(REPOSITORY_ROOT, 'Config', 'UpdateKeys.json');

function releaseError(message) {
  return new Error(`Release verification failed: ${message}`);
}

function isBelow(root, target) {
  const relative = path.relative(root, target);
  return relative.length > 0 && relative !== '..'
    && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

async function listReleaseFiles(directory, prefix = '') {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    const absolute = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) throw releaseError(`symlink is not allowed: ${relative}`);
    if (entry.isDirectory()) files.push(...await listReleaseFiles(absolute, relative));
    else if (entry.isFile()) files.push(relative);
    else throw releaseError(`unsupported filesystem entry: ${relative}`);
  }
  return files.sort();
}

function readTag(item, tag) {
  const match = item.match(new RegExp(`<${tag}>([^<]+)</${tag}>`));
  return match?.[1] ?? null;
}

function enclosureAttributes(item) {
  const enclosure = item.match(/<enclosure\s+([^>]+)>/);
  if (!enclosure) throw releaseError('appcast is missing an enclosure');
  const attributes = {};
  for (const match of enclosure[1].matchAll(/([A-Za-z_:][A-Za-z0-9_.:-]*)="([^"]*)"/g)) {
    attributes[match[1]] = match[2];
  }
  return attributes;
}

async function verifyAppcast({
  appcastPath,
  build,
  macZipPath,
  sparklePublicKeyBase64,
  version,
}) {
  const appcastBytes = await readFile(appcastPath);
  const signatureMarker = Buffer.from('<!-- sparkle-signatures:');
  const markerOffset = appcastBytes.lastIndexOf(signatureMarker);
  if (markerOffset < 0) throw releaseError('appcast lacks Sparkle signed-feed metadata');
  const signatureBlock = appcastBytes.subarray(markerOffset).toString('utf8');
  const signatureMatch = signatureBlock.match(
    /^<!-- sparkle-signatures:\s*\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: (\d+)\n-->\s*$/,
  );
  if (!signatureMatch) throw releaseError('appcast Sparkle signed-feed metadata is malformed');
  const signedLength = Number(signatureMatch[2]);
  if (!Number.isSafeInteger(signedLength) || signedLength !== markerOffset) {
    throw releaseError('appcast Sparkle signed-feed length mismatch');
  }
  if (!verifyManifest(
    appcastBytes.subarray(0, signedLength),
    signatureMatch[1],
    sparklePublicKeyBase64,
  )) {
    throw releaseError('appcast Sparkle signed-feed signature mismatch');
  }

  const signedXML = appcastBytes.subarray(0, signedLength).toString('utf8');
  const items = [...signedXML.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((match) => match[1]);
  if (items.length !== 1) throw releaseError('appcast must contain exactly one release item');
  const item = items[0];
  if (readTag(item, 'sparkle:shortVersionString') !== version) {
    throw releaseError('appcast version does not match release.json');
  }
  if (readTag(item, 'sparkle:version') !== String(build)) {
    throw releaseError('appcast build does not match release.json');
  }

  const attributes = enclosureAttributes(item);
  const zipName = path.basename(macZipPath);
  if (attributes.url !== `${UPDATE_SERVER.macDownloadPrefix}${zipName}`) {
    throw releaseError('appcast enclosure URL does not match the macOS artifact');
  }
  const metadata = await stat(macZipPath);
  if (attributes.length !== String(metadata.size)) {
    throw releaseError('appcast enclosure length does not match the macOS artifact');
  }
  if (!verifyManifest(
    await readFile(macZipPath),
    attributes['sparkle:edSignature'],
    sparklePublicKeyBase64,
  )) {
    throw releaseError('appcast enclosure Sparkle signature mismatch');
  }
}

function cleanYAMLScalar(value) {
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"'))
      || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function verifyLatestYML(text, version, installerName) {
  const versionMatch = text.match(/^version:\s*(.+?)\s*$/m);
  const pathMatch = text.match(/^path:\s*(.+?)\s*$/m);
  const fileURLs = [...text.matchAll(/^\s*-?\s*url:\s*(.+?)\s*$/gm)]
    .map((match) => cleanYAMLScalar(match[1]));
  if (!versionMatch || cleanYAMLScalar(versionMatch[1]) !== version) {
    throw releaseError('latest.yml version does not match release.json');
  }
  if (!pathMatch || cleanYAMLScalar(pathMatch[1]) !== installerName) {
    throw releaseError('latest.yml path does not match the Windows installer');
  }
  if (fileURLs.length === 0 || fileURLs.some((value) => value !== installerName)) {
    throw releaseError('latest.yml file URL does not match the Windows installer');
  }
}

async function defaultPublicKeys() {
  const keys = JSON.parse(await readFile(UPDATE_KEYS_PATH, 'utf8'));
  return keys;
}

export async function verifyReleaseDirectory(
  root,
  manifestPublicKeyBase64,
  { sparklePublicKeyBase64 } = {},
) {
  if (typeof root !== 'string' || !path.isAbsolute(root)) {
    throw releaseError('staging root must be an absolute path');
  }
  const stableRoot = await realpath(root);
  const rootMetadata = await stat(stableRoot);
  if (!rootMetadata.isDirectory()) throw releaseError('staging root must be a directory');

  const defaults = manifestPublicKeyBase64 && sparklePublicKeyBase64
    ? null
    : await defaultPublicKeys();
  const manifestPublicKey = manifestPublicKeyBase64 ?? defaults?.manifestPublicKey;
  const sparklePublicKey = sparklePublicKeyBase64 ?? defaults?.sparklePublicEDKey;

  const manifestPath = path.join(stableRoot, 'release.json');
  const signaturePath = path.join(stableRoot, 'release.json.sig');
  const manifestBytes = await readFile(manifestPath);
  const signature = (await readFile(signaturePath, 'utf8')).trim();
  if (!verifyManifest(manifestBytes, signature, manifestPublicKey)) {
    throw releaseError('release.json detached signature is invalid');
  }

  let manifest;
  try {
    manifest = validateManifest(JSON.parse(manifestBytes.toString('utf8')));
  } catch (error) {
    throw releaseError(error.message);
  }
  if (!manifestBytes.equals(stableManifestBytes(manifest))) {
    throw releaseError('release.json bytes are not in stable canonical form');
  }

  const expectedMacName = `CodexSessionKeeper-${manifest.version}-macos-arm64.zip`;
  const expectedWindowsName = `CodexSessionKeeper-${manifest.version}-windows-x64-Setup.exe`;
  const expectedURLs = {
    'macos-arm64': `macos/${expectedMacName}`,
    'windows-x64': `windows/${expectedWindowsName}`,
  };

  for (const [platform, artifact] of Object.entries(manifest.platforms)) {
    if (artifact.url !== expectedURLs[platform]) {
      throw releaseError(`${platform} artifact filename does not match the version`);
    }
    const artifactPath = path.resolve(stableRoot, artifact.url);
    const canonicalArtifact = await realpath(artifactPath);
    if (!isBelow(stableRoot, canonicalArtifact)) {
      throw releaseError(`${platform} artifact escapes the staging root`);
    }
    const actual = await sha256File(canonicalArtifact);
    if (actual.sha256 !== artifact.sha256) throw releaseError(`${platform} sha256 mismatch`);
    if (actual.size !== artifact.size) throw releaseError(`${platform} size mismatch`);
  }

  const macZipPath = path.join(stableRoot, expectedURLs['macos-arm64']);
  await verifyAppcast({
    appcastPath: path.join(stableRoot, 'macos', 'appcast.xml'),
    build: manifest.build,
    macZipPath,
    sparklePublicKeyBase64: sparklePublicKey,
    version: manifest.version,
  });
  const latestYML = await readFile(path.join(stableRoot, 'windows', 'latest.yml'), 'utf8');
  verifyLatestYML(latestYML, manifest.version, expectedWindowsName);

  const expectedFiles = [
    'release.json',
    'release.json.sig',
    'macos/appcast.xml',
    `macos/${expectedMacName}`,
    'windows/latest.yml',
    `windows/${expectedWindowsName}`,
  ].sort();
  const actualFiles = await listReleaseFiles(stableRoot);
  if (actualFiles.length !== expectedFiles.length
      || actualFiles.some((value, index) => value !== expectedFiles[index])) {
    throw releaseError(`unexpected staging file: ${actualFiles.find((file) => !expectedFiles.includes(file)) ?? 'missing required file'}`);
  }

  for (const textPath of [manifestPath, signaturePath, path.join(stableRoot, 'macos', 'appcast.xml'), path.join(stableRoot, 'windows', 'latest.yml')]) {
    const text = await readFile(textPath, 'utf8');
    if (/-----BEGIN (?:OPENSSH |EC |RSA )?PRIVATE KEY-----/.test(text)) {
      throw releaseError(`private key material found in ${path.relative(stableRoot, textPath)}`);
    }
  }

  return { verified: true, version: manifest.version, build: manifest.build };
}

async function runCLI() {
  if (process.argv.length !== 4 || process.argv[2] !== '--root') {
    throw new Error('usage: verify-release-directory.mjs --root /absolute/stable/root');
  }
  const result = await verifyReleaseDirectory(process.argv[3]);
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

function isMainModule(moduleURL, argumentPath) {
  if (!argumentPath) return false;
  try {
    return pathToFileURL(realpathSync(fileURLToPath(moduleURL))).href
      === pathToFileURL(realpathSync(argumentPath)).href;
  } catch {
    return false;
  }
}

if (isMainModule(import.meta.url, process.argv[1])) {
  runCLI().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

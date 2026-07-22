#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import {
  copyFile,
  lstat,
  mkdir,
  readFile,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { ensureManifestKey } from './keychain.mjs';
import {
  sha256File,
  signManifest,
  stableManifestBytes,
  validateManifest,
} from './release-manifest.mjs';
import { UPDATE_SERVER } from './update-server.mjs';
import { verifyReleaseDirectory } from './verify-release-directory.mjs';

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(MODULE_DIRECTORY, '..', '..');
const UPDATE_KEYS_PATH = path.join(REPOSITORY_ROOT, 'Config', 'UpdateKeys.json');
const SPARKLE_APPCAST_TOOL = path.join(
  REPOSITORY_ROOT,
  '.build', 'artifacts', 'sparkle', 'Sparkle', 'bin', 'generate_appcast',
);
const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

async function requireRegularAbsoluteFile(filePath, label) {
  if (typeof filePath !== 'string' || !path.isAbsolute(filePath)) {
    throw new Error(`${label} must be an absolute path`);
  }
  const metadata = await lstat(filePath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error(`${label} must be a regular file`);
  }
}

async function defaultGenerateAppcast({ macDirectory }) {
  execFileSync(SPARKLE_APPCAST_TOOL, [
    '--account', 'local.codex.session-manager',
    '--download-url-prefix', UPDATE_SERVER.macDownloadPrefix,
    macDirectory,
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
}

export async function assembleRelease({
  build,
  generateAppcast = defaultGenerateAppcast,
  macZip,
  manifestPrivateKeyPem,
  manifestPublicKeyBase64,
  notesFile,
  output,
  publishedAt = new Date().toISOString(),
  sparklePublicKeyBase64,
  version,
  windowsExe,
  windowsYml,
}) {
  if (typeof version !== 'string' || !VERSION.test(version)) {
    throw new Error('version must use numeric X.Y.Z format');
  }
  if (!Number.isSafeInteger(build) || build <= 0) {
    throw new Error('build must be a positive safe integer');
  }
  if (typeof output !== 'string' || !path.isAbsolute(output)) {
    throw new Error('output must be an absolute path');
  }
  await requireRegularAbsoluteFile(macZip, 'mac-zip');
  await requireRegularAbsoluteFile(windowsExe, 'windows-exe');
  await requireRegularAbsoluteFile(windowsYml, 'windows-yml');
  await requireRegularAbsoluteFile(notesFile, 'notes-file');

  const macName = `CodexSessionKeeper-${version}-macos-arm64.zip`;
  const windowsName = `CodexSessionKeeper-${version}-windows-x64-Setup.exe`;
  if (path.basename(macZip) !== macName) throw new Error(`mac-zip must be named ${macName}`);
  if (path.basename(windowsExe) !== windowsName) throw new Error(`windows-exe must be named ${windowsName}`);
  if (path.basename(windowsYml) !== 'latest.yml') throw new Error('windows-yml must be named latest.yml');

  let notes;
  try {
    notes = JSON.parse(await readFile(notesFile, 'utf8'));
  } catch {
    throw new Error('notes-file must contain valid JSON');
  }
  if (!Array.isArray(notes)) throw new Error('notes-file must contain a JSON array');

  let manifestPrivateKey = manifestPrivateKeyPem;
  let manifestPublicKey = manifestPublicKeyBase64;
  let sparklePublicKey = sparklePublicKeyBase64;
  if (!manifestPrivateKey || !manifestPublicKey || !sparklePublicKey) {
    const keys = JSON.parse(await readFile(UPDATE_KEYS_PATH, 'utf8'));
    const keychain = ensureManifestKey();
    if (keychain.publicKeyBase64 !== keys.manifestPublicKey) {
      throw new Error('Keychain manifest key does not match Config/UpdateKeys.json');
    }
    manifestPrivateKey = keychain.privateKeyPem;
    manifestPublicKey = keys.manifestPublicKey;
    sparklePublicKey = keys.sparklePublicEDKey;
  }

  await mkdir(path.dirname(output), { recursive: true });
  await mkdir(output);
  const stableRoot = path.join(output, 'codex-session-keeper', 'stable');
  const macDirectory = path.join(stableRoot, 'macos');
  const windowsDirectory = path.join(stableRoot, 'windows');
  await mkdir(macDirectory, { recursive: true });
  await mkdir(windowsDirectory, { recursive: true });
  const stagedMacZip = path.join(macDirectory, macName);
  const stagedWindowsExe = path.join(windowsDirectory, windowsName);
  await copyFile(macZip, stagedMacZip);
  await copyFile(windowsExe, stagedWindowsExe);
  await copyFile(windowsYml, path.join(windowsDirectory, 'latest.yml'));

  const zipBytes = await readFile(stagedMacZip);
  await generateAppcast({
    build,
    macDirectory,
    version,
    zipBytes,
    zipName: macName,
  });
  await requireRegularAbsoluteFile(path.join(macDirectory, 'appcast.xml'), 'generated appcast.xml');

  const manifest = validateManifest({
    schemaVersion: 1,
    channel: 'stable',
    version,
    build,
    publishedAt,
    required: false,
    notes,
    platforms: {
      'macos-arm64': {
        url: `macos/${macName}`,
        ...await sha256File(stagedMacZip),
      },
      'windows-x64': {
        url: `windows/${windowsName}`,
        ...await sha256File(stagedWindowsExe),
      },
    },
  });
  const manifestBytes = stableManifestBytes(manifest);
  const signature = signManifest(manifestBytes, manifestPrivateKey);
  await writeFile(path.join(stableRoot, 'release.json'), manifestBytes, { flag: 'wx', mode: 0o644 });
  await writeFile(path.join(stableRoot, 'release.json.sig'), `${signature}\n`, { flag: 'wx', mode: 0o644 });

  const verified = await verifyReleaseDirectory(stableRoot, manifestPublicKey, {
    sparklePublicKeyBase64: sparklePublicKey,
  });
  return { stableRoot, verified };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--version', '--build', '--mac-zip', '--windows-exe',
    '--windows-yml', '--notes-file', '--output',
  ]);
  if (argv.length !== allowed.size * 2) throw new Error('all release arguments are required');
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || Object.hasOwn(values, flag)) {
      throw new Error(`invalid release argument: ${flag}`);
    }
    values[flag] = value;
  }
  for (const flag of allowed) {
    if (!Object.hasOwn(values, flag)) throw new Error(`missing release argument: ${flag}`);
  }
  return values;
}

async function runCLI() {
  const args = parseArguments(process.argv.slice(2));
  const build = Number(args['--build']);
  const result = await assembleRelease({
    build,
    macZip: args['--mac-zip'],
    notesFile: args['--notes-file'],
    output: args['--output'],
    version: args['--version'],
    windowsExe: args['--windows-exe'],
    windowsYml: args['--windows-yml'],
  });
  process.stdout.write(`${JSON.stringify(result.verified)}\n${result.stableRoot}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runCLI().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

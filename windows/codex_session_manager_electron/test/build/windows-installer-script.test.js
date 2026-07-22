const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const appRoot = path.join(__dirname, '..', '..');
const packageJsonPath = path.join(appRoot, 'package.json');
const packageLockPath = path.join(appRoot, 'package-lock.json');
const electronWindowsX64Sha256 =
  'a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0';

const buildScriptPath = path.join(
  __dirname,
  '..',
  '..',
  '..',
  '..',
  'scripts',
  'build_windows_installer.ps1'
);

test('Windows installer build stops when any native build step fails', () => {
  const source = fs.readFileSync(buildScriptPath, 'utf8');

  assert.match(
    source,
    /function Invoke-CheckedNative[\s\S]*& \$Command[\s\S]*\$LASTEXITCODE[\s\S]*throw/
  );
  assert.match(
    source,
    /\$PreviousErrorActionPreference = \$ErrorActionPreference[\s\S]*\$ErrorActionPreference = "Continue"[\s\S]*& \$Command[\s\S]*finally[\s\S]*\$ErrorActionPreference = \$PreviousErrorActionPreference/
  );

  for (const command of [
    'npm ci',
    'npm run prepare:sqlite-win',
    'node -e',
    'npm install --package-lock-only --ignore-scripts',
    'npm test',
    'npm run package:win',
  ]) {
    const escaped = command.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(
      source,
      new RegExp(`Invoke-CheckedNative[^\\r\\n]*\\{[^\\r\\n]*${escaped}`),
      `${command} must run through Invoke-CheckedNative`
    );
  }
});

test('Windows installer build prepares bundled SQLite before running tests', () => {
  const source = fs.readFileSync(buildScriptPath, 'utf8');
  const prepareIndex = source.indexOf('npm run prepare:sqlite-win');
  const testIndex = source.indexOf('npm test');

  assert.notEqual(prepareIndex, -1);
  assert.notEqual(testIndex, -1);
  assert.ok(prepareIndex < testIndex);
});

test('Windows build validates cached Electron against its pinned official checksum', () => {
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  const packageLock = JSON.parse(fs.readFileSync(packageLockPath, 'utf8'));
  const electronVersion = packageLock.packages['node_modules/electron'].version;
  const artifactName = `electron-v${electronVersion}-win32-x64.zip`;

  assert.equal(electronVersion, '43.1.0');
  assert.equal(packageJson.build.electronDownload.unsafelyDisableChecksums, false);
  assert.deepEqual(packageJson.build.electronDownload.checksums, {
    [artifactName]: electronWindowsX64Sha256,
  });
});

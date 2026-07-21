const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

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

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const appRoot = path.resolve(__dirname, '..');
const repositoryRoot = path.resolve(appRoot, '..', '..');

test('Windows installer is a stable per-user NSIS package with login cleanup', () => {
  const packageJson = JSON.parse(fs.readFileSync(path.join(appRoot, 'package.json'), 'utf8'));
  const configuration = fs.readFileSync(path.join(appRoot, 'electron-builder.yml'), 'utf8');
  const installerInclude = fs.readFileSync(path.join(appRoot, 'build', 'installer.nsh'), 'utf8');

  assert.match(packageJson.scripts['dist:win'], /electron-builder/);
  assert.match(packageJson.scripts['postdist:win'], /write-installer-checksum/);
  assert.ok(packageJson.devDependencies['electron-builder']);
  assert.match(configuration, /^appId: com\.codexsessionkeeper\.desktop$/m);
  assert.match(configuration, /^asar: false$/m);
  assert.match(configuration, /^\s+executableName: codex_session_manager$/m);
  assert.match(configuration, /^\s+- target: nsis$/m);
  assert.match(configuration, /^\s+perMachine: false$/m);
  assert.match(configuration, /^\s+allowElevation: false$/m);
  assert.match(configuration, /^\s+packElevateHelper: false$/m);
  assert.match(configuration, /src\/lifecycle\.js/);
  assert.match(configuration, /src\/backup\/\*\*\/\*/);
  assert.match(configuration, /vendor\/sqlite3\.exe/);
  assert.match(configuration, /internal-test-unsigned/);
  assert.match(installerInclude, /DeleteRegValue HKCU .*CodexSessionKeeper/);
  const checksumWriter = fs.readFileSync(path.join(appRoot, 'scripts', 'write-installer-checksum.js'), 'utf8');
  assert.match(checksumWriter, /sha256/);
  assert.match(checksumWriter, /\.sha256/);
});

test('macOS packaging produces an internal-test DMG with an Applications link', () => {
  const appBuilder = fs.readFileSync(path.join(repositoryRoot, 'scripts', 'build_app.sh'), 'utf8');
  const dmgBuilder = fs.readFileSync(path.join(repositoryRoot, 'scripts', 'build_macos_dmg.sh'), 'utf8');

  assert.match(appBuilder, /APP_VERSION/);
  assert.match(appBuilder, /local\.codex\.session-manager/);
  assert.match(dmgBuilder, /internal-test-unsigned\.dmg/);
  assert.match(dmgBuilder, /ln -s \/Applications/);
  assert.match(dmgBuilder, /ServiceManagement/);
  assert.match(dmgBuilder, /\$\{APP_NAME\}（内部测试）/);
  assert.match(dmgBuilder, /hdiutil create/);
});

test('Windows acceptance executes the modules shipped beside the selected packaged runtime', () => {
  const wrapper = fs.readFileSync(path.join(repositoryRoot, 'scripts', 'acceptance', 'run_p0_windows.ps1'), 'utf8');
  const runner = fs.readFileSync(path.join(repositoryRoot, 'scripts', 'acceptance', 'p0-windows-runner.js'), 'utf8');
  assert.match(wrapper, /CODEX_P0_APP_ROOT/);
  assert.match(wrapper, /resources\\app/);
  assert.match(runner, /process\.env\.CODEX_P0_APP_ROOT/);
});

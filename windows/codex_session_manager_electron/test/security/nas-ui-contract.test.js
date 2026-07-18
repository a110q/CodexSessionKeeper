'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

test('NAS onboarding uses fixed catalogs and logical recovery device IDs', () => {
  const sourceRoot = path.join(__dirname, '..', '..', 'src');
  const html = fs.readFileSync(path.join(sourceRoot, 'index.html'), 'utf8');
  const renderer = fs.readFileSync(path.join(sourceRoot, 'renderer.js'), 'utf8');

  for (const id of [
    'nasSetupModal',
    'nasDepartment',
    'nasEmployee',
    'nasRetryBtn',
    'nasConfirmBtn',
    'nasReconfigureBtn',
    'nasRecoveryDevice',
  ]) {
    assert.match(html, new RegExp(`id="${id}"`));
  }

  assert.doesNotMatch(html, /type="file"/);
  assert.doesNotMatch(renderer, /backupPathInput|nasPathInput|selectDirectory/);
  assert.match(renderer, /activateNasBackup/);
  assert.match(renderer, /selectedNasRecoveryDeviceId/);
  assert.match(renderer, /loadIncrementalBackupSessions\(state\.selectedNasRecoveryDeviceId\)/);
  assert.match(renderer, /restoreIncrementalBackupSessions\(state\.selectedNasRecoveryDeviceId,/);
  assert.match(renderer, /公司 NAS 会话备份/);
});

test('unconfigured NAS modal has no dismiss action and shows the fixed endpoint', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'index.html'), 'utf8');
  const modal = html.slice(html.indexOf('id="nasSetupModal"'), html.indexOf('id="busyOverlay"'));

  assert.match(modal, /192\.168\.10\.99/);
  assert.match(modal, /文件中转站/);
  assert.doesNotMatch(modal, /data-dismiss|nasSetupClose|关闭/);
});

test('Electron backup lifecycle uses cached status, resume wiring, and prompt shutdown', () => {
  const mainPath = path.join(__dirname, '..', '..', 'src', 'main.js');
  const main = fs.readFileSync(mainPath, 'utf8');
  const statusGetter = main.slice(
    main.indexOf('function readBackupStatus()'),
    main.indexOf('function readLines('),
  );
  const readyBlock = main.slice(
    main.indexOf('if (hasSingleInstanceLock)'),
    main.indexOf("app.on('second-instance'"),
  );

  assert.match(statusGetter, /nasRuntime\.backupStatus\(\)/);
  assert.doesNotMatch(statusGetter, /status\.json|readText|readFile|exists\(/);
  assert.doesNotMatch(main.split('\n')[0], /powerMonitor/);
  assert.match(main, /const \{ powerMonitor \} = require\('electron'\)/);
  assert.match(readyBlock, /await nasRuntime\.initialize\(\);[\s\S]*installBackupLifecycleListeners\(\)/);
  assert.match(main, /const resumeHandler = \(\) => nasRuntime\.requestImmediateScan\('wake'\)/);
  assert.match(main, /powerMonitor\.on\('resume', resumeHandler\)/);
  assert.match(main, /powerMonitor\.removeListener\('resume'/);
  assert.match(main, /app\.on\('activate',[\s\S]*requestImmediateScan\('activation'\)/);
  assert.match(main, /createLoginItemController/);
  assert.match(main, /createBackgroundLifecycle/);
  assert.match(main, /new Tray\(/);
  assert.match(main, /backgroundLifecycle\.attachWindow\(mainWindow\)/);
  assert.match(main, /app\.on\('before-quit',[\s\S]*backgroundLifecycle\.requestQuit\(\)[\s\S]*backgroundLifecycle\.beforeQuit\(\)/);
  assert.match(main, /app\.on\('second-instance', \(_event, commandLine\)/);
  assert.match(main, /backgroundLifecycle\.handleSecondInstance\(commandLine\)/);
  assert.doesNotMatch(main, /app\.on\('window-all-closed',[\s\S]{0,120}app\.quit\(\)/);
  assert.doesNotMatch(main, /installBackupExitGuard|backupExitConfirmed/);
});

test('launch-at-login warning and repair actions are exposed through guarded IPC', () => {
  const sourceRoot = path.join(__dirname, '..', '..', 'src');
  const main = fs.readFileSync(path.join(sourceRoot, 'main.js'), 'utf8');
  const preload = fs.readFileSync(path.join(sourceRoot, 'preload.js'), 'utf8');
  const html = fs.readFileSync(path.join(sourceRoot, 'index.html'), 'utf8');
  const renderer = fs.readFileSync(path.join(sourceRoot, 'renderer.js'), 'utf8');

  for (const channel of ['retry-launch-at-login', 'open-login-item-settings']) {
    assert.match(main, new RegExp(`handleTrustedIpc\\('${channel}'`));
    assert.match(preload, new RegExp(`ipcRenderer\\.invoke\\('${channel}'`));
  }
  assert.match(html, /id="launchAtLoginWarning"/);
  assert.match(html, /id="retryLaunchAtLoginBtn"/);
  assert.match(html, /id="openLoginItemSettingsBtn"/);
  assert.match(renderer, /launchAtLogin\.enabled/);
});

test('NAS onboarding renders truthful Chinese processed and failure counts', () => {
  const renderer = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'renderer.js'), 'utf8');

  assert.match(renderer, /已发现 \$\{total\} · 已检查 \$\{completed\} · 待处理 \$\{pending\}/);
  assert.match(renderer, /已发现 \$\{total\} · 成功 \$\{completed - failed\} · 异常 \$\{failed\} · 待处理 \$\{pending\}/);
  assert.doesNotMatch(renderer, /已发现 \$\{total\} · 已完成/);
});

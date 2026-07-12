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

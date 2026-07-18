'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  CURRENT_ONBOARDING_VERSION,
  onboardingDecision,
  stateGuidance,
  helpTopics,
} = require('../src/user-guidance');

test('unconfigured setup is forced until a real running state', () => {
  const required = onboardingDecision({
    setup: { state: 'unconfigured', configured: false },
    settings: { onboardingVersion: 0, onboardingInProgress: false },
    catalogReady: false,
    selectionValid: false,
  });
  assert.equal(required.step, 1);
  assert.equal(required.presentSetup, true);
  assert.equal(required.preventDismissal, true);
  assert.equal(required.nextInProgress, true);
  assert.equal(required.canActivate, false);

  const identity = onboardingDecision({
    setup: { state: 'unconfigured', configured: false },
    settings: { onboardingVersion: 0, onboardingInProgress: true },
    catalogReady: true,
    selectionValid: true,
  });
  assert.equal(identity.step, 2);
  assert.equal(identity.canActivate, true);

  const completed = onboardingDecision({
    setup: { state: 'running', configured: true },
    settings: { onboardingVersion: 0, onboardingInProgress: true },
  });
  assert.equal(completed.shouldMarkComplete, true);
  assert.equal(completed.nextInProgress, false);
  assert.equal(CURRENT_ONBOARDING_VERSION, 1);
});

test('configured upgrades are never forced back through identity selection', () => {
  const decision = onboardingDecision({
    setup: { state: 'disconnected', configured: true },
    settings: { onboardingVersion: 0, onboardingInProgress: false },
    catalogReady: true,
    selectionValid: true,
  });

  assert.equal(decision.presentSetup, false);
  assert.equal(decision.preventDismissal, false);
  assert.equal(decision.nextInProgress, false);
  assert.equal(decision.canActivate, false);
});

test('first run remains forced for every non-running runtime state', () => {
  for (const state of ['disconnected', 'validating', 'seeding', 'verifying', 'pending', 'error']) {
    const decision = onboardingDecision({
      setup: { state, configured: true },
      settings: { onboardingVersion: 0, onboardingInProgress: true },
    });
    assert.equal(decision.presentSetup, true, state);
    assert.equal(decision.preventDismissal, true, state);
    assert.equal(decision.shouldMarkComplete, false, state);
    assert.equal(decision.nextInProgress, true, state);
  }
});

test('guidance exposes exact shared labels and four topics', () => {
  assert.deepEqual(
    ['unconfigured', 'disconnected', 'validating', 'seeding', 'verifying', 'running', 'pending', 'error']
      .map((state) => stateGuidance(state).title),
    [
      '尚未选择部门和姓名',
      '未检测到公司 NAS',
      '正在验证备份目录',
      '正在进行首次备份',
      '正在确认 NAS 文件完整',
      '备份已验证',
      '有会话等待补传',
      '备份出现异常',
    ]
  );
  assert.deepEqual(helpTopics.map((topic) => topic.title), [
    '安装与首次启动',
    '备份状态说明',
    'NAS 断开与异常处理',
    '会话恢复和更换电脑',
  ]);
});

test('main process persists onboarding through existing state and status channels', () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
  const activationStart = source.indexOf("handleTrustedIpc('activate-nas-backup'");
  const activationEnd = source.indexOf("handleTrustedIpc('retry-nas-backup'", activationStart);
  const activation = source.slice(activationStart, activationEnd);

  assert.match(source, /require\('\.\/user-guidance'\)/);
  assert.match(source, /function reconcileOnboarding\(setup\)/);
  assert.match(source, /function backupStatusWithOnboarding\(/);
  assert.match(source, /handleTrustedIpc\('load-backup-status', async \(\) => backupStatusWithOnboarding\(\)\)/);
  assert.match(source, /appVersion,\s*\n\s*currentState:/);
  assert.ok(activationStart >= 0 && activationEnd > activationStart);
  assert.ok(activation.indexOf('saveSettings({ onboardingInProgress: true })') >= 0);
  assert.ok(activation.indexOf('saveSettings({ onboardingInProgress: true })')
    < activation.indexOf('nasRuntime.activate('));
  assert.ok(activation.includes('reconcileOnboarding(nasSetupState())'));
  assert.equal(source.includes("handleTrustedIpc('set-onboarding"), false);
});

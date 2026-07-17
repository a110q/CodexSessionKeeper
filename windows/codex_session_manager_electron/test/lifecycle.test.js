'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  BACKGROUND_ARGUMENT,
  createBackgroundLifecycle,
  createLoginItemController,
} = require('../src/lifecycle');

test('packaged Windows app registers and verifies a stable background login item', () => {
  let saved = { openAtLogin: false };
  const calls = [];
  const app = {
    isPackaged: true,
    setLoginItemSettings(options) {
      calls.push(options);
      saved = { openAtLogin: options.openAtLogin };
    },
    getLoginItemSettings(options) {
      calls.push({ read: options });
      return saved;
    },
  };
  const controller = createLoginItemController({
    app,
    execPath: 'C:\\Users\\Ada\\AppData\\Local\\Programs\\CodexSessionKeeper\\codex_session_manager.exe',
    platform: 'win32',
  });

  const state = controller.ensureEnabled();

  assert.deepEqual(state, { enabled: true, requiresApproval: false, message: null });
  const registration = calls.find((call) => !call.read);
  assert.deepEqual(registration, {
    openAtLogin: true,
    path: 'C:\\Users\\Ada\\AppData\\Local\\Programs\\CodexSessionKeeper\\codex_session_manager.exe',
    args: [BACKGROUND_ARGUMENT],
    enabled: true,
    name: 'CodexSessionKeeper',
  });
  assert.ok(calls.filter((call) => call.read).every((call) => (
    call.read.path === registration.path
      && call.read.args[0] === BACKGROUND_ARGUMENT
      && call.read.name === registration.name
  )));
});

test('login registration failure is surfaced and never reported as enabled', () => {
  const controller = createLoginItemController({
    app: {
      isPackaged: true,
      setLoginItemSettings() { throw new Error('registry denied'); },
      getLoginItemSettings() { return { openAtLogin: false }; },
    },
    execPath: 'C:\\app.exe',
    platform: 'win32',
  });

  assert.deepEqual(controller.ensureEnabled(), {
    enabled: false,
    requiresApproval: false,
    message: '无法启用开机自启：registry denied',
  });
});

test('development or non-Windows runtime does not register the Electron executable', () => {
  let writes = 0;
  const controller = createLoginItemController({
    app: {
      isPackaged: false,
      setLoginItemSettings() { writes += 1; },
      getLoginItemSettings() { return { openAtLogin: false }; },
    },
    execPath: '/Applications/Electron.app/Contents/MacOS/Electron',
    platform: 'darwin',
  });

  assert.equal(controller.ensureEnabled().enabled, false);
  assert.equal(writes, 0);
});

test('window close hides to tray while manual launch restores the window', () => {
  const window = fakeWindow();
  let hiddenNotices = 0;
  let quitCalls = 0;
  const lifecycle = createBackgroundLifecycle({
    getWindow: () => window,
    getBackupState: () => 'running',
    confirmBusyQuit: async () => true,
    quitApplication: () => { quitCalls += 1; },
    stopRuntime: () => {},
    teardown: () => {},
    notifyHidden: () => { hiddenNotices += 1; },
  });
  lifecycle.attachWindow(window);
  const event = preventableEvent();

  window.listeners.get('close')(event);
  lifecycle.handleSecondInstance(['codex_session_manager.exe']);

  assert.equal(event.prevented, true);
  assert.equal(window.hidden, 1);
  assert.equal(window.shown, 1);
  assert.equal(window.focused, 1);
  assert.equal(hiddenNotices, 1);
  assert.equal(quitCalls, 0);
});

test('background login second instance does not display the window', () => {
  const window = fakeWindow();
  const lifecycle = createBackgroundLifecycle({
    getWindow: () => window,
    getBackupState: () => 'running',
    confirmBusyQuit: async () => true,
    quitApplication: () => {},
    stopRuntime: () => {},
    teardown: () => {},
    notifyHidden: () => {},
  });

  lifecycle.handleSecondInstance(['codex_session_manager.exe', BACKGROUND_ARGUMENT]);

  assert.equal(window.shown, 0);
  assert.equal(window.focused, 0);
});

test('explicit quit confirms busy work, then permits close and cleans up once', async () => {
  const window = fakeWindow();
  let allowQuit = false;
  let confirmations = 0;
  let quitCalls = 0;
  let stops = 0;
  let teardowns = 0;
  const lifecycle = createBackgroundLifecycle({
    getWindow: () => window,
    getBackupState: () => 'verifying',
    confirmBusyQuit: async () => { confirmations += 1; return allowQuit; },
    quitApplication: () => { quitCalls += 1; },
    stopRuntime: () => { stops += 1; },
    teardown: () => { teardowns += 1; },
    notifyHidden: () => {},
  });
  lifecycle.attachWindow(window);

  await lifecycle.requestQuit();
  assert.equal(confirmations, 1);
  assert.equal(quitCalls, 0);

  allowQuit = true;
  await lifecycle.requestQuit();
  assert.equal(confirmations, 2);
  assert.equal(quitCalls, 1);

  lifecycle.beforeQuit();
  lifecycle.beforeQuit();
  const event = preventableEvent();
  window.listeners.get('close')(event);

  assert.equal(event.prevented, false);
  assert.equal(stops, 1);
  assert.equal(teardowns, 1);
});

function fakeWindow() {
  return {
    listeners: new Map(),
    hidden: 0,
    shown: 0,
    focused: 0,
    minimized: false,
    destroyed: false,
    on(name, handler) { this.listeners.set(name, handler); },
    hide() { this.hidden += 1; },
    show() { this.shown += 1; },
    focus() { this.focused += 1; },
    isDestroyed() { return this.destroyed; },
    isMinimized() { return this.minimized; },
    restore() { this.minimized = false; },
  };
}

function preventableEvent() {
  return {
    prevented: false,
    preventDefault() { this.prevented = true; },
  };
}

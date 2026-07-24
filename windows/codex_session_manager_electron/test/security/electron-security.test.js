const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  createTrustedIpcRegistrar,
  installNavigationGuards,
  resolveTrustedSessionFile,
  strictZeroArgumentHandler,
} = require('../../src/security');

function trustedIpcFixture() {
  const handlers = new Map();
  const ipcMain = {
    handle(channel, handler) {
      handlers.set(channel, handler);
    },
  };
  const mainFrame = { url: 'file:///app/index.html' };
  const webContents = {
    isDestroyed: () => false,
    mainFrame,
  };
  const mainWindow = {
    isDestroyed: () => false,
    webContents,
  };
  const handleTrustedIpc = createTrustedIpcRegistrar({
    ipcMain,
    getMainWindow: () => mainWindow,
    expectedURL: mainFrame.url,
  });

  return { handleTrustedIpc, handlers, mainFrame, mainWindow, webContents };
}

test('trusted IPC registrar invokes handlers only for the main application frame', async () => {
  const fixture = trustedIpcFixture();
  let invocationCount = 0;
  fixture.handleTrustedIpc('secure-channel', async (_event, value) => {
    invocationCount += 1;
    return value;
  });

  const result = await fixture.handlers.get('secure-channel')({
    sender: fixture.webContents,
    senderFrame: fixture.mainFrame,
  }, 'accepted');

  assert.equal(result, 'accepted');
  assert.equal(invocationCount, 1);
});

test('trusted IPC registrar rejects untrusted senders before invoking the handler', async () => {
  const fixture = trustedIpcFixture();
  let invocationCount = 0;
  fixture.handleTrustedIpc('secure-channel', async () => {
    invocationCount += 1;
  });
  const handler = fixture.handlers.get('secure-channel');
  const validEvent = {
    sender: fixture.webContents,
    senderFrame: fixture.mainFrame,
  };

  const invalidEvents = [
    { ...validEvent, sender: {} },
    { ...validEvent, senderFrame: { url: fixture.mainFrame.url } },
    { ...validEvent, senderFrame: { ...fixture.mainFrame, url: 'https://attacker.example/' } },
    { ...validEvent, senderFrame: { ...fixture.mainFrame, url: 'file:///app/other.html' } },
  ];

  for (const event of invalidEvents) {
    await assert.rejects(handler(event), /不受信任的 IPC 来源/);
  }
  assert.equal(invocationCount, 0);
});

test('trusted IPC registrar rejects missing or destroyed application windows', async () => {
  const handlers = new Map();
  const ipcMain = { handle: (channel, handler) => handlers.set(channel, handler) };
  let mainWindow = null;
  const handleTrustedIpc = createTrustedIpcRegistrar({
    ipcMain,
    getMainWindow: () => mainWindow,
    expectedURL: 'file:///app/index.html',
  });
  handleTrustedIpc('secure-channel', async () => 'unreachable');
  const handler = handlers.get('secure-channel');

  await assert.rejects(handler({}), /不受信任的 IPC 来源/);

  mainWindow = {
    isDestroyed: () => true,
    webContents: { isDestroyed: () => false, mainFrame: {} },
  };
  await assert.rejects(handler({}), /不受信任的 IPC 来源/);

  mainWindow = {
    isDestroyed: () => false,
    webContents: { isDestroyed: () => true, mainFrame: {} },
  };
  await assert.rejects(handler({}), /不受信任的 IPC 来源/);
});

test('navigation guards allow only the exact application URL and deny all new windows', () => {
  const listeners = new Map();
  let openHandler = null;
  const webContents = {
    on(name, listener) {
      listeners.set(name, listener);
    },
    setWindowOpenHandler(handler) {
      openHandler = handler;
    },
  };
  const expectedURL = 'file:///app/index.html';
  installNavigationGuards(webContents, expectedURL);

  for (const eventName of ['will-navigate', 'will-redirect']) {
    let prevented = false;
    listeners.get(eventName)({ preventDefault: () => { prevented = true; } }, expectedURL);
    assert.equal(prevented, false);

    listeners.get(eventName)({ preventDefault: () => { prevented = true; } }, 'https://attacker.example/');
    assert.equal(prevented, true);
  }

  assert.deepEqual(openHandler({ url: 'https://attacker.example/' }), { action: 'deny' });
});

test('trusted session file resolver accepts active and archived JSONL files', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'electron-session-security-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const codexRoot = path.join(root, '.codex');
  const active = path.join(codexRoot, 'sessions', '2026', 'session.jsonl');
  const archived = path.join(codexRoot, 'archived_sessions', 'archive.jsonl');
  await fsp.mkdir(path.dirname(active), { recursive: true });
  await fsp.mkdir(path.dirname(archived), { recursive: true });
  await fsp.writeFile(active, '{}\n');
  await fsp.writeFile(archived, '{}\n');

  assert.equal(resolveTrustedSessionFile(active, codexRoot), fs.realpathSync.native(active));
  assert.equal(resolveTrustedSessionFile(archived, codexRoot), fs.realpathSync.native(archived));
});

test('trusted session file resolver rejects unsafe filesystem targets', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'electron-session-security-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const codexRoot = path.join(root, '.codex');
  const sessionsRoot = path.join(codexRoot, 'sessions');
  const outsideRoot = path.join(root, 'outside');
  const outsideFile = path.join(outsideRoot, 'outside.jsonl');
  const executable = path.join(sessionsRoot, 'attacker.exe');
  const directory = path.join(sessionsRoot, 'directory.jsonl');
  const linkedOutside = path.join(sessionsRoot, 'linked-outside');
  await fsp.mkdir(sessionsRoot, { recursive: true });
  await fsp.mkdir(outsideRoot, { recursive: true });
  await fsp.mkdir(directory, { recursive: true });
  await fsp.writeFile(outsideFile, '{}\n');
  await fsp.writeFile(executable, 'not executable in this test');
  await fsp.symlink(outsideRoot, linkedOutside, process.platform === 'win32' ? 'junction' : 'dir');

  const unsafeTargets = [
    outsideFile,
    executable,
    directory,
    path.join(sessionsRoot, 'missing.jsonl'),
    path.join(linkedOutside, 'outside.jsonl'),
    'relative/session.jsonl',
    String.raw`\\attacker.example\share\attacker.exe`,
    String.raw`\\?\C:\Windows\System32\cmd.exe`,
    path.join(sessionsRoot, 'safe.jsonl:payload.exe'),
  ];

  for (const target of unsafeTargets) {
    assert.throws(() => resolveTrustedSessionFile(target, codexRoot), /会话文件路径不安全/);
  }
});

test('Electron source contract exposes no renderer-controlled filesystem path channel', () => {
  const sourceRoot = path.join(__dirname, '..', '..', 'src');
  const mainSource = fs.readFileSync(path.join(sourceRoot, 'main.js'), 'utf8');
  const indexSource = fs.readFileSync(path.join(sourceRoot, 'index.html'), 'utf8');
  const preloadSource = fs.readFileSync(path.join(sourceRoot, 'preload.js'), 'utf8');
  const rendererSource = fs.readFileSync(path.join(sourceRoot, 'renderer.js'), 'utf8');

  assert.doesNotMatch(mainSource, /ipcMain\.handle\s*\(/);
  assert.doesNotMatch(mainSource, /['"](?:open-path|reveal-path)['"]/);
  assert.doesNotMatch(preloadSource, /\b(?:openPath|revealPath)\b|['"](?:open-path|reveal-path)['"]/);
  assert.doesNotMatch(rendererSource, /codexManager\.(?:openPath|revealPath)|(?:openSessionFile|revealSessionFile)\(session\.rolloutPath\)/);

  assert.match(preloadSource, /openSessionFile:\s*\(sessionId\).*'open-session-file'/s);
  assert.match(preloadSource, /revealSessionFile:\s*\(sessionId\).*'reveal-session-file'/s);
  assert.match(rendererSource, /openSessionFile\(session\.id\)/);
  assert.match(rendererSource, /revealSessionFile\(session\.id\)/);

  for (const channel of [
    'update:get-state',
    'update:check',
    'update:download',
    'update:defer-restart',
    'update:install',
  ]) {
    assert.match(mainSource, new RegExp(`handleTrustedIpc\\('${channel.replace(':', '\\:')}'`));
  }
  assert.match(preloadSource, /ipcRenderer\.invoke\('update:install'\)/);
  assert.doesNotMatch(preloadSource, /update:install'\s*,\s*(url|path|options)/);
  assert.match(preloadSource, /ipcRenderer\.on\('update:state'/);
  assert.match(indexSource, /role="dialog"[^>]+aria-modal="true"/);
  for (const id of [
    'updateLaterButton',
    'updateNowButton',
    'updateRestartLaterButton',
    'updateInstallButton',
  ]) {
    assert.match(indexSource, new RegExp(`id="${id}"`));
  }
  assert.match(rendererSource, /function renderUpdate\(\)/);
  assert.doesNotMatch(rendererSource, /updateNotes[^\n]*innerHTML/);

  const preloadChannels = [...preloadSource.matchAll(/ipcRenderer\.invoke\('([^']+)'/g)]
    .map((match) => match[1])
    .sort();
  const mainChannels = [...mainSource.matchAll(/handleTrustedIpc\('([^']+)'/g)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual(mainChannels, preloadChannels);
});

test('NAS setup and recovery IPC stays guarded and accepts identities instead of paths', () => {
  const sourceRoot = path.join(__dirname, '..', '..', 'src');
  const mainSource = fs.readFileSync(path.join(sourceRoot, 'main.js'), 'utf8');
  const preloadSource = fs.readFileSync(path.join(sourceRoot, 'preload.js'), 'utf8');
  const requiredChannels = [
    'get-nas-setup-state',
    'detect-company-nas',
    'list-nas-departments',
    'list-nas-employees',
    'activate-nas-backup',
    'retry-nas-backup',
    'list-nas-backup-devices',
    'load-incremental-backup-sessions',
    'restore-incremental-backup-sessions',
  ];

  for (const channel of requiredChannels) {
    assert.match(mainSource, new RegExp(`handleTrustedIpc\\('${channel}'`));
    assert.match(preloadSource, new RegExp(`ipcRenderer\\.invoke\\('${channel}'`));
  }
  assert.doesNotMatch(mainSource, /\blocalBackupPaths\b|\blocalBackupAgent\b|buildIncrementalRecoveryPackage/);
  assert.doesNotMatch(preloadSource, /backupRoot|targetPath|sourcePath|destinationPath/);
  assert.match(preloadSource, /loadIncrementalBackupSessions:\s*\(deviceId\)/);
  assert.match(preloadSource, /restoreIncrementalBackupSessions:\s*\(deviceId, sessionIds, protectionMode\)/);

  const restoreHandler = mainSource.slice(mainSource.indexOf("handleTrustedIpc('restore-incremental-backup-sessions'"));
  assert.ok(restoreHandler.indexOf('resolveRecoveryDevicePaths(deviceId)') < restoreHandler.indexOf('createRestoreProtectionSnapshot('));
  assert.ok(restoreHandler.indexOf('preflightIncrementalRecovery(') < restoreHandler.indexOf('createRestoreProtectionSnapshot('));
  assert.doesNotMatch(restoreHandler, /recovery-packages|buildIncrementalRecoveryPackage/);
});

test('Electron enforces one backup writer per device identity', () => {
  const mainSource = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'main.js'), 'utf8');
  assert.match(mainSource, /app\.requestSingleInstanceLock\(\)/);
  assert.match(mainSource, /app\.on\('second-instance'/);
});

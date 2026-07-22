const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { UpdateService } = require('../../src/update/update-service');
const { UpdateStateStore } = require('../../src/update/update-state-store');

const updateServer = require('../../../../Config/UpdateServer.json');
const RELEASE_BASE = updateServer.releaseBaseURL;
const WINDOWS_FEED = new URL('windows/', RELEASE_BASE).href;
const INSTALLER_NAME = 'CodexSessionKeeper-1.1.0-windows-x64-Setup.exe';

async function makeTempDir(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-update-service-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

function makeSignedRelease(installerBytes = Buffer.from('installer')) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const manifest = {
    schemaVersion: 1,
    channel: 'stable',
    version: '1.1.0',
    build: 10100,
    publishedAt: '2026-07-21T00:00:00Z',
    required: false,
    notes: ['新增公司内网更新功能'],
    platforms: {
      'macos-arm64': {
        url: 'macos/CodexSessionKeeper-1.1.0-macos-arm64.zip',
        size: 12,
        sha256: 'a'.repeat(64),
      },
      'windows-x64': {
        url: `windows/${INSTALLER_NAME}`,
        size: installerBytes.length,
        sha256: crypto.createHash('sha256').update(installerBytes).digest('hex'),
      },
    },
  };
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  const signatureBytes = Buffer.from(
    crypto.sign(null, manifestBytes, privateKey).toString('base64'),
  );
  const publicKeyBase64 = publicKey.export({ type: 'spki', format: 'der' })
    .subarray(-32)
    .toString('base64');
  return { installerBytes, manifest, manifestBytes, publicKeyBase64, signatureBytes };
}

function makeFetch(release) {
  const responses = new Map([
    [`${RELEASE_BASE}release.json`, release.manifestBytes],
    [`${RELEASE_BASE}release.json.sig`, release.signatureBytes],
  ]);
  return async (url) => {
    const body = responses.get(String(url));
    if (!body) return { ok: false, status: 404 };
    return { ok: true, arrayBuffer: async () => body };
  };
}

class FakeUpdater extends EventEmitter {
  constructor() {
    super();
    this.autoDownload = true;
    this.autoInstallOnAppQuit = true;
    this.allowDowngrade = true;
    this.downloadCalls = 0;
    this.quitCalls = [];
    this.updateInfo = {
      version: '1.1.0',
      files: [{ url: INSTALLER_NAME }],
    };
  }

  setFeedURL(value) {
    this.feedURL = value;
  }

  async checkForUpdates() {
    return { updateInfo: this.updateInfo };
  }

  async downloadUpdate() {
    this.downloadCalls += 1;
    return [];
  }

  quitAndInstall(...args) {
    this.quitCalls.push(args);
  }
}

class FakeStateStore {
  constructor() {
    this.value = { schemaVersion: 1 };
    this.pendingWrites = [];
  }

  async read() {
    return { ...this.value };
  }

  async write(patch) {
    this.value = { ...this.value, ...patch };
    return this.read();
  }

  async consumeCompletion(currentVersion) {
    if (this.value.pendingVersion !== currentVersion) return null;
    delete this.value.pendingVersion;
    return { phase: 'completed', version: currentVersion };
  }

  async markPending(version) {
    this.pendingWrites.push(version);
    this.value.pendingVersion = version;
  }
}

function makeService({
  release = makeSignedRelease(),
  fetchImpl,
  updater = new FakeUpdater(),
  stateStore = new FakeStateStore(),
  backupAgent = { stopAndDrain: async () => true, startPolling() {} },
  timeoutMs = 5000,
} = {}) {
  const emitted = [];
  const service = new UpdateService({
    autoUpdater: updater,
    backupAgent,
    currentBuild: 10099,
    currentVersion: '1.0.99',
    fetchImpl: fetchImpl || makeFetch(release),
    publicKeyBase64: release.publicKeyBase64,
    releaseBaseURL: RELEASE_BASE,
    sendState: (state) => emitted.push(state),
    stateStore,
    timeoutMs,
  });
  return { backupAgent, emitted, release, service, stateStore, updater };
}

test('derives the only Windows feed from the fixed release root', async () => {
  const setup = makeService();
  await setup.service.check({ manual: true });
  await setup.service.download();
  assert.deepEqual(setup.updater.feedURL, {
    provider: 'generic',
    url: 'http://192.168.10.54:18080/codex-session-keeper/stable/windows/',
  });
});

test('checks, downloads, verifies, and exposes only sanitized progress', async (t) => {
  const root = await makeTempDir(t);
  const setup = makeService();
  const installerPath = path.join(root, INSTALLER_NAME);
  await fs.writeFile(installerPath, setup.release.installerBytes);

  assert.deepEqual(setup.service.getState(), { phase: 'idle' });
  await setup.service.check({ manual: false });
  assert.equal(setup.service.getState().phase, 'available');
  await setup.service.download();
  assert.equal(setup.updater.downloadCalls, 1);

  setup.updater.emit('download-progress', { transferred: 5, total: 10, percent: 50 });
  assert.deepEqual(setup.service.getState(), {
    phase: 'downloading', version: '1.1.0', transferred: 5, total: 10, percent: 50,
  });
  setup.updater.emit('update-downloaded', { downloadedFile: installerPath, version: '1.1.0' });
  await setup.service.waitForVerificationForTest();
  assert.deepEqual(setup.service.getState(), { phase: 'ready', version: '1.1.0' });
  assert.equal(JSON.stringify(setup.emitted).includes(installerPath), false);
  assert.equal(JSON.stringify(setup.emitted).includes(setup.release.manifest.platforms['windows-x64'].sha256), false);
});

test('keeps a scheduled timeout silent and shows a manual timeout', async () => {
  const fetchImpl = (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener('abort', () => {
      const error = new Error('aborted');
      error.name = 'AbortError';
      reject(error);
    }, { once: true });
  });
  const setup = makeService({ fetchImpl, timeoutMs: 20 });

  await setup.service.check({ manual: false });
  assert.deepEqual(setup.service.getState(), { phase: 'idle' });
  await setup.service.check({ manual: true });
  assert.deepEqual(setup.service.getState(), {
    phase: 'failed', message: '暂时无法连接公司更新服务器，请稍后重试',
  });
});

test('shows invalid signed metadata instead of silently ignoring it', async () => {
  const release = makeSignedRelease();
  release.manifestBytes[release.manifestBytes.length - 2] ^= 1;
  const setup = makeService({ release });
  await setup.service.check({ manual: false });
  assert.deepEqual(setup.service.getState(), {
    phase: 'failed', message: '更新信息验证失败，请联系管理员',
  });
});

test('refuses latest.yml versions or URLs that differ from the signed manifest', async () => {
  const setup = makeService();
  await setup.service.check({ manual: true });
  setup.updater.updateInfo.version = '1.1.1';
  await setup.service.download();
  assert.equal(setup.updater.downloadCalls, 0);
  assert.equal(setup.service.getState().phase, 'failed');

  const wrongURL = makeService();
  await wrongURL.service.check({ manual: true });
  wrongURL.updater.updateInfo.files = [{ url: 'https://attacker.invalid/update.exe' }];
  await wrongURL.service.download();
  assert.equal(wrongURL.updater.downloadCalls, 0);
  assert.equal(wrongURL.service.getState().phase, 'failed');
});

test('deletes a downloaded installer when size or hash verification fails', async (t) => {
  const root = await makeTempDir(t);
  const setup = makeService();
  const installerPath = path.join(root, INSTALLER_NAME);
  await fs.writeFile(installerPath, 'tampered');
  await setup.service.check({ manual: true });
  await setup.service.download();

  setup.updater.emit('update-downloaded', { downloadedFile: installerPath, version: '1.1.0' });
  await setup.service.waitForVerificationForTest();
  assert.equal(setup.service.getState().phase, 'failed');
  await assert.rejects(fs.access(installerPath), /ENOENT/);
});

test('drains backup before installing and restarts polling on timeout', async () => {
  const calls = [];
  const backupAgent = {
    async stopAndDrain(timeout) { calls.push(['drain', timeout]); return false; },
    startPolling(interval) { calls.push(['poll', interval]); },
  };
  const setup = makeService({ backupAgent });
  setup.service.setReadyForTest('1.1.0');

  await setup.service.restartAndInstall();
  assert.deepEqual(calls, [['drain', 5000], ['poll', 10000]]);
  assert.equal(setup.updater.quitCalls.length, 0);
  assert.deepEqual(setup.service.getState(), {
    phase: 'failed', message: '备份仍在写入，已取消更新重启，请稍后重试',
  });
});

test('writes the pending marker before invoking quitAndInstall', async () => {
  const order = [];
  const stateStore = new FakeStateStore();
  stateStore.markPending = async (version) => {
    order.push(['pending', version]);
    stateStore.value.pendingVersion = version;
  };
  const updater = new FakeUpdater();
  updater.quitAndInstall = (...args) => order.push(['quit', ...args]);
  const setup = makeService({ stateStore, updater });
  setup.service.setReadyForTest('1.1.0');

  await setup.service.restartAndInstall();
  assert.deepEqual(order, [
    ['pending', '1.1.0'],
    ['quit', false, true],
  ]);
});

test('restores backup polling and clears the marker if installation cannot start', async () => {
  const calls = [];
  const backupAgent = {
    async stopAndDrain(timeout) { calls.push(['drain', timeout]); return true; },
    startPolling(interval) { calls.push(['poll', interval]); },
  };
  const stateStore = new FakeStateStore();
  const updater = new FakeUpdater();
  updater.quitAndInstall = () => {
    throw new Error('installer launch failed');
  };
  const setup = makeService({ backupAgent, stateStore, updater });
  setup.service.setReadyForTest('1.1.0');

  await setup.service.restartAndInstall();

  assert.deepEqual(calls, [['drain', 5000], ['poll', 10000]]);
  assert.equal(stateStore.value.pendingVersion, null);
  assert.deepEqual(setup.service.getState(), {
    phase: 'failed', message: '更新失败，请稍后重试',
  });
});

test('state store atomically consumes a matching completion marker once', async (t) => {
  const vaultRoot = await makeTempDir(t);
  const store = new UpdateStateStore({ vaultRoot });
  await store.write({ lastCheckAt: '2026-07-21T00:00:00.000Z' });
  await store.markPending('1.1.0');

  assert.deepEqual(await store.consumeCompletion('1.1.0'), {
    phase: 'completed', version: '1.1.0',
  });
  assert.equal(await store.consumeCompletion('1.1.0'), null);
  assert.deepEqual(await store.read(), {
    schemaVersion: 1,
    lastCheckAt: '2026-07-21T00:00:00.000Z',
  });
});

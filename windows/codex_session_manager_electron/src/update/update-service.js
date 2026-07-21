const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const {
  INVALID_MESSAGE,
  parseAndVerifyManifest,
  selectUpdate,
} = require('./release-manifest');

const RELEASE_BASE_URL = 'http://192.168.10.99:18080/codex-session-keeper/stable/';
const WINDOWS_FEED_URL = `${RELEASE_BASE_URL}windows/`;
const CONNECTION_MESSAGE = '暂时无法连接公司更新服务器，请稍后重试';
const UPDATE_FAILURE_MESSAGE = '更新失败，请稍后重试';
const BACKUP_BUSY_MESSAGE = '备份仍在写入，已取消更新重启，请稍后重试';
const EIGHT_HOURS_MS = 8 * 60 * 60 * 1000;

class UpdateService {
  constructor({
    autoUpdater,
    backupAgent,
    currentBuild,
    currentVersion,
    fetchImpl = globalThis.fetch,
    now = () => new Date(),
    publicKeyBase64,
    releaseBaseURL = RELEASE_BASE_URL,
    sendState = () => {},
    stateStore,
    timeoutMs = 5000,
    windowsFeedURL = WINDOWS_FEED_URL,
  }) {
    if (!autoUpdater || !backupAgent || !stateStore) {
      throw new TypeError('UpdateService requires updater, backup agent, and state store.');
    }
    if (!Number.isSafeInteger(currentBuild) || currentBuild <= 0) {
      throw new TypeError('currentBuild must be a positive safe integer.');
    }
    if (typeof currentVersion !== 'string' || typeof publicKeyBase64 !== 'string') {
      throw new TypeError('UpdateService requires current version and public key.');
    }
    if (typeof fetchImpl !== 'function') throw new TypeError('fetchImpl must be a function.');

    this.autoUpdater = autoUpdater;
    this.backupAgent = backupAgent;
    this.currentBuild = currentBuild;
    this.currentVersion = currentVersion;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.publicKeyBase64 = publicKeyBase64;
    this.releaseBaseURL = new URL(releaseBaseURL).href;
    this.windowsFeedURL = new URL(windowsFeedURL).href;
    this.sendState = sendState;
    this.stateStore = stateStore;
    this.timeoutMs = timeoutMs;

    this.state = { phase: 'idle' };
    this.verifiedRelease = null;
    this.verificationPromise = Promise.resolve();
    this.initialTimer = null;
    this.intervalTimer = null;
    this.disposed = false;
    this.started = false;

    this.autoUpdater.autoDownload = false;
    this.autoUpdater.autoInstallOnAppQuit = false;
    this.autoUpdater.allowDowngrade = false;

    this.onDownloadProgress = (progress) => this.handleDownloadProgress(progress);
    this.onUpdateDownloaded = (event) => {
      this.verificationPromise = this.verifyDownloadedInstaller(event).catch(() => {
        this.setState({ phase: 'failed', message: UPDATE_FAILURE_MESSAGE });
      });
    };
    this.onUpdaterError = () => {
      this.setState({ phase: 'failed', message: UPDATE_FAILURE_MESSAGE });
    };
    this.autoUpdater.on('download-progress', this.onDownloadProgress);
    this.autoUpdater.on('update-downloaded', this.onUpdateDownloaded);
    this.autoUpdater.on('error', this.onUpdaterError);
  }

  async start() {
    if (this.started || this.disposed) return this.getState();
    this.started = true;
    const completed = await this.stateStore.consumeCompletion(this.currentVersion);
    if (completed) this.setState(completed);

    const persisted = await this.stateStore.read();
    const lastCheckTime = Date.parse(persisted.lastCheckAt || '');
    const delay = Number.isFinite(lastCheckTime)
      ? Math.max(5000, lastCheckTime + EIGHT_HOURS_MS - this.now().getTime())
      : 5000;
    this.initialTimer = setTimeout(async () => {
      this.initialTimer = null;
      await this.check({ manual: false });
      if (this.disposed) return;
      this.intervalTimer = setInterval(() => {
        this.check({ manual: false }).catch(() => {});
      }, EIGHT_HOURS_MS);
      this.intervalTimer.unref?.();
    }, delay);
    this.initialTimer.unref?.();
    return this.getState();
  }

  async check({ manual }) {
    if (this.disposed) return this.getState();
    if (['downloading', 'verifying', 'ready'].includes(this.state.phase)) {
      return this.getState();
    }
    if (manual) this.setState({ phase: 'checking' });
    await this.stateStore.write({ lastCheckAt: this.now().toISOString() }).catch(() => {});

    let manifestBytes;
    let signatureBytes;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      manifestBytes = await this.fetchBytes(
        new URL('release.json', this.releaseBaseURL),
        controller.signal,
        1024 * 1024,
      );
      signatureBytes = await this.fetchBytes(
        new URL('release.json.sig', this.releaseBaseURL),
        controller.signal,
        1024,
      );
    } catch {
      if (manual) this.setState({ phase: 'failed', message: CONNECTION_MESSAGE });
      else if (this.state.phase === 'checking') this.setState({ phase: 'idle' });
      return this.getState();
    } finally {
      clearTimeout(timer);
    }

    let manifest;
    try {
      manifest = parseAndVerifyManifest(manifestBytes, signatureBytes, this.publicKeyBase64);
    } catch {
      this.verifiedRelease = null;
      this.setState({ phase: 'failed', message: INVALID_MESSAGE });
      return this.getState();
    }

    const result = selectUpdate(
      manifest,
      this.currentVersion,
      this.currentBuild,
      'windows-x64',
    );
    if (result.status === 'available') {
      this.verifiedRelease = result;
      this.setState({
        phase: 'available',
        version: result.manifest.version,
        notes: [...result.manifest.notes],
      });
    } else if (result.status === 'up-to-date') {
      this.verifiedRelease = null;
      if (manual) this.setState({ phase: 'up-to-date', version: this.currentVersion });
    } else {
      this.verifiedRelease = null;
      this.setState({ phase: 'failed', message: result.message });
    }
    return this.getState();
  }

  async fetchBytes(url, signal, maximumBytes) {
    const response = await this.fetchImpl(url, { cache: 'no-store', signal });
    if (!response || response.ok !== true) throw new Error('bad update response');
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length === 0 || bytes.length > maximumBytes) throw new Error('bad update size');
    return bytes;
  }

  async download() {
    const release = this.verifiedRelease;
    if (!release || this.state.phase !== 'available') {
      this.setState({ phase: 'failed', message: UPDATE_FAILURE_MESSAGE });
      return this.getState();
    }

    try {
      this.autoUpdater.setFeedURL({ provider: 'generic', url: this.windowsFeedURL });
      const result = await this.autoUpdater.checkForUpdates();
      this.validateUpdaterResult(result?.updateInfo, release);
      this.setState({
        phase: 'downloading',
        version: release.manifest.version,
        transferred: 0,
        total: release.artifact.size,
        percent: 0,
      });
      await this.autoUpdater.downloadUpdate();
    } catch {
      this.setState({ phase: 'failed', message: INVALID_MESSAGE });
    }
    return this.getState();
  }

  validateUpdaterResult(updateInfo, release) {
    if (!updateInfo || updateInfo.version !== release.manifest.version
        || !Array.isArray(updateInfo.files) || updateInfo.files.length === 0) {
      throw new Error('updater metadata does not match signed release');
    }
    const expectedURL = new URL(release.artifact.url, this.releaseBaseURL);
    const feedURL = new URL(this.windowsFeedURL);
    if (!expectedURL.href.startsWith(feedURL.href)) {
      throw new Error('signed Windows artifact is outside the fixed feed');
    }
    const expectedName = path.posix.basename(decodeURIComponent(expectedURL.pathname));
    for (const file of updateInfo.files) {
      if (!file || typeof file.url !== 'string') throw new Error('invalid updater file');
      const resolved = new URL(file.url, feedURL);
      const basename = path.posix.basename(decodeURIComponent(resolved.pathname));
      if (!resolved.href.startsWith(feedURL.href)
          || resolved.href !== expectedURL.href
          || basename !== expectedName) {
        throw new Error('updater file does not match signed artifact');
      }
    }
  }

  handleDownloadProgress(progress) {
    if (!this.verifiedRelease || this.state.phase !== 'downloading') return;
    const transferred = finiteNonNegative(progress?.transferred);
    const total = finiteNonNegative(progress?.total);
    const percent = Math.min(100, finiteNonNegative(progress?.percent));
    this.setState({
      phase: 'downloading',
      version: this.verifiedRelease.manifest.version,
      transferred,
      total,
      percent,
    });
  }

  async verifyDownloadedInstaller(event) {
    const release = this.verifiedRelease;
    const downloadedFile = event?.downloadedFile;
    if (!release || typeof downloadedFile !== 'string' || !path.isAbsolute(downloadedFile)) {
      this.setState({ phase: 'failed', message: UPDATE_FAILURE_MESSAGE });
      return;
    }
    this.setState({ phase: 'verifying', version: release.manifest.version });

    let matches = event.version === release.manifest.version;
    try {
      const metadata = await fsp.lstat(downloadedFile);
      matches = matches && metadata.isFile() && !metadata.isSymbolicLink()
        && metadata.size === release.artifact.size;
      if (matches) {
        const hash = await sha256File(downloadedFile);
        matches = hash === release.artifact.sha256;
      }
    } catch {
      matches = false;
    }

    if (!matches) {
      await fsp.unlink(downloadedFile).catch(() => {});
      this.setState({ phase: 'failed', message: INVALID_MESSAGE });
      return;
    }
    this.setState({ phase: 'ready', version: release.manifest.version });
  }

  deferRestart() {
    return this.getState();
  }

  async restartAndInstall() {
    if (this.state.phase !== 'ready') return this.getState();
    const version = this.state.version;
    let drained = false;
    try {
      drained = await this.backupAgent.stopAndDrain(5000);
    } catch {
      drained = false;
    }
    if (!drained) {
      this.backupAgent.startPolling(10000);
      this.setState({ phase: 'failed', message: BACKUP_BUSY_MESSAGE });
      return this.getState();
    }

    try {
      await this.stateStore.markPending(version);
    } catch {
      this.backupAgent.startPolling(10000);
      this.setState({ phase: 'failed', message: UPDATE_FAILURE_MESSAGE });
      return this.getState();
    }
    try {
      await this.autoUpdater.quitAndInstall(false, true);
    } catch {
      await this.stateStore.write({ pendingVersion: null }).catch(() => {});
      this.backupAgent.startPolling(10000);
      this.setState({ phase: 'failed', message: UPDATE_FAILURE_MESSAGE });
    }
    return this.getState();
  }

  getState() {
    return JSON.parse(JSON.stringify(this.state));
  }

  setState(state) {
    this.state = JSON.parse(JSON.stringify(state));
    try {
      this.sendState(this.getState());
    } catch {
      // A closed renderer must not interrupt update verification.
    }
  }

  waitForVerificationForTest() {
    return this.verificationPromise;
  }

  setReadyForTest(version) {
    this.setState({ phase: 'ready', version });
  }

  dispose() {
    this.disposed = true;
    if (this.initialTimer) clearTimeout(this.initialTimer);
    if (this.intervalTimer) clearInterval(this.intervalTimer);
    this.initialTimer = null;
    this.intervalTimer = null;
    this.autoUpdater.off('download-progress', this.onDownloadProgress);
    this.autoUpdater.off('update-downloaded', this.onUpdateDownloaded);
    this.autoUpdater.off('error', this.onUpdaterError);
  }
}

function finiteNonNegative(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(0, number) : 0;
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

module.exports = {
  RELEASE_BASE_URL,
  UpdateService,
  WINDOWS_FEED_URL,
};

'use strict';

const BACKGROUND_ARGUMENT = '--background';
const BUSY_BACKUP_STATES = new Set(['seeding', 'pending', 'verifying']);

function createLoginItemController({
  app,
  execPath = process.execPath,
  platform = process.platform,
  backgroundArgument = BACKGROUND_ARGUMENT,
  openSettings = () => {},
}) {
  const options = Object.freeze({
    openAtLogin: true,
    path: execPath,
    args: Object.freeze([backgroundArgument]),
    enabled: true,
    name: 'CodexSessionKeeper',
  });

  function unsupportedState() {
    return {
      enabled: false,
      requiresApproval: false,
      message: '开机自启仅在已安装的 Windows 版本中启用。',
    };
  }

  function currentState() {
    if (platform !== 'win32' || !app.isPackaged) return unsupportedState();
    try {
      const settings = app.getLoginItemSettings(options);
      return {
        enabled: Boolean(settings.openAtLogin),
        requiresApproval: false,
        message: settings.openAtLogin ? null : '开机自启尚未启用。',
      };
    } catch (error) {
      return {
        enabled: false,
        requiresApproval: false,
        message: `无法检查开机自启：${error.message}`,
      };
    }
  }

  function ensureEnabled() {
    if (platform !== 'win32' || !app.isPackaged) return unsupportedState();
    const current = currentState();
    if (current.enabled) return current;
    try {
      app.setLoginItemSettings(options);
      return currentState();
    } catch (error) {
      return {
        enabled: false,
        requiresApproval: false,
        message: `无法启用开机自启：${error.message}`,
      };
    }
  }

  return Object.freeze({ currentState, ensureEnabled, openSettings });
}

function createBackgroundLifecycle({
  getWindow,
  getBackupState,
  confirmBusyQuit,
  quitApplication,
  stopRuntime,
  teardown,
  notifyHidden,
}) {
  let quitRequested = false;
  let cleanedUp = false;

  function attachWindow(window) {
    window.on('close', (event) => {
      if (quitRequested) return;
      event.preventDefault();
      window.hide();
      notifyHidden();
    });
  }

  function showWindow() {
    const window = getWindow();
    if (!window || window.isDestroyed()) return;
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
  }

  function handleSecondInstance(commandLine = []) {
    if (commandLine.includes(BACKGROUND_ARGUMENT)) return;
    showWindow();
  }

  async function requestQuit() {
    if (quitRequested) return true;
    if (BUSY_BACKUP_STATES.has(getBackupState())) {
      const confirmed = await confirmBusyQuit();
      if (!confirmed) return false;
    }
    quitRequested = true;
    quitApplication();
    return true;
  }

  function beforeQuit() {
    quitRequested = true;
    if (cleanedUp) return;
    cleanedUp = true;
    teardown();
    stopRuntime();
  }

  return Object.freeze({
    attachWindow,
    beforeQuit,
    handleSecondInstance,
    isQuitRequested: () => quitRequested,
    requestQuit,
    showWindow,
  });
}

module.exports = {
  BACKGROUND_ARGUMENT,
  createBackgroundLifecycle,
  createLoginItemController,
};

const fs = require('node:fs');
const path = require('node:path');

const UNTRUSTED_IPC_ERROR = '不受信任的 IPC 来源。';
const UNSAFE_SESSION_FILE_ERROR = '会话文件路径不安全。';

function createTrustedIpcRegistrar({ ipcMain, getMainWindow, expectedURL }) {
  return function handleTrustedIpc(channel, handler) {
    ipcMain.handle(channel, async (event, ...args) => {
      const mainWindow = getMainWindow();
      const webContents = mainWindow?.webContents;
      const senderFrame = event?.senderFrame;
      const trusted = Boolean(
        mainWindow
        && !mainWindow.isDestroyed()
        && webContents
        && !webContents.isDestroyed()
        && event?.sender === webContents
        && senderFrame === webContents.mainFrame
        && senderFrame?.url === expectedURL
      );
      if (!trusted) throw new Error(UNTRUSTED_IPC_ERROR);
      return handler(event, ...args);
    });
  };
}

function installNavigationGuards(webContents, expectedURL) {
  const preventUnexpectedNavigation = (event, targetURL) => {
    if (targetURL !== expectedURL) event.preventDefault();
  };
  webContents.on('will-navigate', preventUnexpectedNavigation);
  webContents.on('will-redirect', preventUnexpectedNavigation);
  webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
}

function resolveTrustedSessionFile(targetPath, codexRoot) {
  try {
    if (typeof targetPath !== 'string'
      || typeof codexRoot !== 'string'
      || !path.isAbsolute(targetPath)
      || !path.isAbsolute(codexRoot)
      || targetPath.includes('\0')
      || codexRoot.includes('\0')) {
      throw new Error(UNSAFE_SESSION_FILE_ERROR);
    }

    const canonicalRoot = fs.realpathSync.native(codexRoot);
    const canonicalTarget = fs.realpathSync.native(targetPath);
    const relative = path.relative(canonicalRoot, canonicalTarget);
    const firstComponent = relative.split(path.sep)[0];
    const isContained = relative
      && relative !== '..'
      && !relative.startsWith(`..${path.sep}`)
      && !path.isAbsolute(relative);
    const isSessionPath = firstComponent === 'sessions'
      || firstComponent === 'archived_sessions';
    const isJsonlFile = path.extname(canonicalTarget).toLowerCase() === '.jsonl'
      && fs.statSync(canonicalTarget).isFile();

    if (!isContained || !isSessionPath || !isJsonlFile) {
      throw new Error(UNSAFE_SESSION_FILE_ERROR);
    }
    return canonicalTarget;
  } catch (error) {
    if (error?.message === UNSAFE_SESSION_FILE_ERROR) throw error;
    throw new Error(UNSAFE_SESSION_FILE_ERROR, { cause: error });
  }
}

module.exports = {
  createTrustedIpcRegistrar,
  installNavigationGuards,
  resolveTrustedSessionFile,
};

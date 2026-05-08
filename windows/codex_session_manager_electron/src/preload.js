const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('codexManager', {
  loadState: () => ipcRenderer.invoke('load-state'),
  setAutoRestore: (enabled) => ipcRenderer.invoke('set-auto-restore', enabled),
  createSnapshot: (name) => ipcRenderer.invoke('create-snapshot', name),
  loadSnapshotSessions: (snapshotId) => ipcRenderer.invoke('load-snapshot-sessions', snapshotId),
  openSnapshot: (snapshotId) => ipcRenderer.invoke('open-snapshot', snapshotId),
  chooseRestoreProtectionMode: (options) => ipcRenderer.invoke('choose-restore-protection-mode', options),
  restoreSnapshotConversations: (snapshotId, protectionMode) => ipcRenderer.invoke('restore-snapshot-conversations', snapshotId, protectionMode),
  restoreSnapshotFull: (snapshotId, protectionMode) => ipcRenderer.invoke('restore-snapshot-full', snapshotId, protectionMode),
  restoreSnapshotSession: (snapshotId, sessionId, protectionMode) => ipcRenderer.invoke('restore-snapshot-session', snapshotId, sessionId, protectionMode),
  restoreSnapshotSessions: (snapshotId, sessionIds, protectionMode) => ipcRenderer.invoke('restore-snapshot-sessions', snapshotId, sessionIds, protectionMode),
  deleteSnapshot: (snapshotId) => ipcRenderer.invoke('delete-snapshot', snapshotId),
  deleteSnapshots: (snapshotIds) => ipcRenderer.invoke('delete-snapshots', snapshotIds),
  restoreSession: (sessionId, protectionMode) => ipcRenderer.invoke('restore-session', sessionId, protectionMode),
  deleteSession: (sessionId) => ipcRenderer.invoke('delete-session', sessionId),
  deleteSessions: (sessionIds) => ipcRenderer.invoke('delete-sessions', sessionIds),
  loadConversation: (sessionId) => ipcRenderer.invoke('load-conversation', sessionId),
  openPath: (targetPath) => ipcRenderer.invoke('open-path', targetPath),
  revealPath: (targetPath) => ipcRenderer.invoke('reveal-path', targetPath),
  openCodexRoot: () => ipcRenderer.invoke('open-codex-root'),
  openVaultRoot: () => ipcRenderer.invoke('open-vault-root')
});

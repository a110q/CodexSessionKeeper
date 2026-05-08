const { app, BrowserWindow, Menu, ipcMain, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

let mainWindow;
let sqlPromise;

const appVersion = '1.0.8';
const codexRoot = path.join(os.homedir(), '.codex');
const vaultRoot = path.join(os.homedir(), '.codex-session-vault');
const snapshotRoot = path.join(vaultRoot, 'snapshots');
const settingsPath = path.join(vaultRoot, 'settings.json');

const backupCandidates = [
  'config.toml',
  'auth.json',
  '.codex-global-state.json',
  '.codex-global-state.json.bak',
  'history.jsonl',
  'history.jsonl.bak',
  'session_index.jsonl',
  'sessions',
  'archived_sessions',
  'state_5.sqlite',
  'state_5.sqlite-shm',
  'state_5.sqlite-wal',
  'logs_2.sqlite',
  'logs_2.sqlite-shm',
  'logs_2.sqlite-wal',
  'sqlite',
  'shell_snapshots',
  'ambient-suggestions'
];

const conversationBackupCandidates = [
  'history.jsonl',
  'history.jsonl.bak',
  'session_index.jsonl',
  'sessions',
  'archived_sessions',
  'state_5.sqlite',
  'shell_snapshots',
  'ambient-suggestions'
];

const conversationDirectoryPaths = [
  'sessions',
  'archived_sessions',
  'shell_snapshots',
  'ambient-suggestions'
];

const conversationLineMergePaths = [
  'history.jsonl',
  'history.jsonl.bak',
  'session_index.jsonl'
];

const conversationStateTables = [
  'threads',
  'thread_goals',
  'thread_dynamic_tools',
  'thread_spawn_edges',
  'stage1_outputs'
];

const stateDatabaseSnapshotPaths = new Set([
  'state_5.sqlite',
  'state_5.sqlite-shm',
  'state_5.sqlite-wal'
]);

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1240,
    height: 820,
    minWidth: 1120,
    minHeight: 720,
    title: 'codex_会话管理',
    backgroundColor: '#f4f0e8',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'index.html'));
}

app.whenReady().then(createWindow);
app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function exists(targetPath) {
  return targetPath && fs.existsSync(targetPath);
}

function loadSettings() {
  const defaults = { autoRestoreOnLaunch: false };
  try {
    if (!exists(settingsPath)) return defaults;
    const settings = { ...defaults, ...JSON.parse(readText(settingsPath)) };
    if (!settings.autoRestoreDefaultOffMigrationV1) {
      settings.autoRestoreOnLaunch = false;
      settings.autoRestoreDefaultOffMigrationV1 = true;
      ensureDir(vaultRoot);
      fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf8');
    }
    return settings;
  } catch {
    return defaults;
  }
}

function saveSettings(nextSettings) {
  ensureDir(vaultRoot);
  fs.writeFileSync(settingsPath, JSON.stringify({ ...loadSettings(), autoRestoreDefaultOffMigrationV1: true, ...nextSettings }, null, 2), 'utf8');
  return loadSettings();
}

function readText(targetPath) {
  return exists(targetPath) ? fs.readFileSync(targetPath, 'utf8') : '';
}

function readLines(targetPath) {
  const text = readText(targetPath);
  if (!text) return [];
  return text.split(/\r?\n/).filter(Boolean);
}

function parseJsonLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function toDate(value) {
  if (!value) return new Date(0).toISOString();
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? new Date(0).toISOString() : date.toISOString();
}

function unixSecondsToIso(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return new Date(0).toISOString();
  return new Date(number * 1000).toISOString();
}

function fileSize(targetPath) {
  try {
    const stat = fs.statSync(targetPath);
    return stat.isFile() ? stat.size : 0;
  } catch {
    return 0;
  }
}

function directorySize(targetPath) {
  if (!exists(targetPath)) return 0;
  let total = 0;
  for (const entry of fs.readdirSync(targetPath, { withFileTypes: true })) {
    const fullPath = path.join(targetPath, entry.name);
    if (entry.isDirectory()) total += directorySize(fullPath);
    if (entry.isFile()) total += fileSize(fullPath);
  }
  return total;
}

function countJsonlFiles(targetPath) {
  if (!exists(targetPath)) return 0;
  let count = 0;
  for (const entry of fs.readdirSync(targetPath, { withFileTypes: true })) {
    const fullPath = path.join(targetPath, entry.name);
    if (entry.isDirectory()) count += countJsonlFiles(fullPath);
    if (entry.isFile() && entry.name.endsWith('.jsonl')) count += 1;
  }
  return count;
}

function fingerprint(targetPath) {
  if (!exists(targetPath)) return 'none';
  const data = fs.readFileSync(targetPath);
  if (!data.length) return 'none';
  return crypto.createHash('sha256').update(data).digest('hex').slice(0, 12);
}

function parseTomlString(text, key) {
  const pattern = new RegExp(`^\\s*${key}\\s*=\\s*"([^"]*)"\\s*$`, 'm');
  const match = text.match(pattern);
  return match ? match[1] : null;
}

function inspectCurrentState() {
  const config = readText(path.join(codexRoot, 'config.toml'));
  return {
    codexRoot,
    vaultRoot,
    modelProvider: parseTomlString(config, 'model_provider') || 'unknown',
    model: parseTomlString(config, 'model') || 'unknown',
    accountFingerprint: fingerprint(path.join(codexRoot, 'auth.json')),
    sessionCount: countJsonlFiles(path.join(codexRoot, 'sessions')),
    archivedSessionCount: countJsonlFiles(path.join(codexRoot, 'archived_sessions'))
  };
}

function getSqlJs() {
  if (!sqlPromise) {
    const initSqlJs = require('sql.js');
    sqlPromise = initSqlJs({
      locateFile: (file) => path.join(app.getAppPath(), 'node_modules', 'sql.js', 'dist', file)
    });
  }
  return sqlPromise;
}

async function openDatabase(databasePath) {
  const SQL = await getSqlJs();
  const buffer = fs.readFileSync(databasePath);
  return new SQL.Database(buffer);
}

function execRows(db, sql) {
  const result = db.exec(sql);
  if (!result.length) return [];
  const columns = result[0].columns;
  return result[0].values.map((values) => {
    const row = {};
    columns.forEach((column, index) => {
      row[column] = values[index];
    });
    return row;
  });
}

function quoteIdent(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function quoteLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function tableExists(db, table) {
  return execRows(db, `SELECT name FROM sqlite_master WHERE type='table' AND name=${quoteLiteral(table)};`).length > 0;
}

function tableColumns(db, table) {
  if (!tableExists(db, table)) return [];
  return execRows(db, `PRAGMA table_info(${quoteIdent(table)});`).map((row) => row.name);
}

function makeSession(row, existsOnDiskOverride = null, sizeBytesOverride = null, rolloutPathOverride = null) {
  const rolloutPath = rolloutPathOverride || row.rolloutPath || row.rollout_path || '';
  const fileExists = existsOnDiskOverride ?? exists(rolloutPath);
  return {
    id: String(row.id || ''),
    title: String(row.title || row.thread_name || row.id || '').trim(),
    rolloutPath,
    cwd: String(row.cwd || ''),
    provider: String(row.modelProvider || row.model_provider || 'unknown'),
    model: String(row.model || 'unknown'),
    source: String(row.source || 'jsonl'),
    createdAt: row.createdAtIso || unixSecondsToIso(row.createdAt || row.created_at || 0),
    updatedAt: row.updatedAtIso || unixSecondsToIso(row.updatedAt || row.updated_at || 0),
    archived: Number(row.archived || 0) === 1 || row.archived === true,
    existsOnDisk: fileExists,
    sizeBytes: sizeBytesOverride ?? (fileExists ? fileSize(rolloutPath) : 0)
  };
}

async function loadSessionsFromSqlite(root = codexRoot) {
  const databasePath = path.join(root, 'state_5.sqlite');
  if (!exists(databasePath)) return [];

  let db;
  try {
    db = await openDatabase(databasePath);
    const rows = execRows(db, `
      SELECT
        id,
        title,
        rollout_path AS rolloutPath,
        cwd,
        model_provider AS modelProvider,
        COALESCE(model, 'unknown') AS model,
        source,
        created_at AS createdAt,
        updated_at AS updatedAt,
        archived
      FROM threads
      ORDER BY updated_at DESC, created_at DESC;
    `);
    return rows.map((row) => {
      const rolloutPath = row.rolloutPath || row.rollout_path || '';
      const resolvedPath = resolveRolloutFilePath(String(row.id || ''), rolloutPath, root, codexRoot);
      const fileExists = exists(resolvedPath);
      return makeSession(row, fileExists, fileExists ? fileSize(resolvedPath) : 0, resolvedPath || rolloutPath);
    });
  } catch {
    return [];
  } finally {
    if (db) db.close();
  }
}

function safeRelativePath(fromRoot, targetPath) {
  if (!fromRoot || !targetPath) return null;
  const relative = path.relative(path.normalize(fromRoot), path.normalize(targetPath));
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) return null;
  return relative;
}

function snapshotRelativePath(absolutePath, snapshotCodexRoot) {
  if (!absolutePath) return null;
  const roots = [snapshotCodexRoot, codexRoot].filter(Boolean);
  for (const root of roots) {
    const relative = safeRelativePath(root, absolutePath);
    if (relative) return relative;
  }

  const slashPath = String(absolutePath).replace(/\\/g, '/');
  const markerIndex = slashPath.toLowerCase().indexOf('/.codex/');
  if (markerIndex >= 0) {
    return slashPath.slice(markerIndex + '/.codex/'.length).split('/').join(path.sep);
  }
  return null;
}

function findRolloutFile(root, sessionId) {
  if (!root || !sessionId) return '';
  for (const dir of ['sessions', 'archived_sessions']) {
    const match = walkFiles(
      path.join(root, dir),
      (filePath) => filePath.endsWith('.jsonl') && path.basename(filePath).includes(sessionId)
    )[0];
    if (match) return match;
  }
  return '';
}

function resolveRolloutFilePath(sessionId, rolloutPath, dataRoot, snapshotCodexRoot) {
  const relative = snapshotRelativePath(rolloutPath, snapshotCodexRoot);
  if (relative) {
    const candidate = path.join(dataRoot, relative);
    if (exists(candidate)) return candidate;
  }

  if (rolloutPath) {
    const relativeToData = safeRelativePath(dataRoot, rolloutPath);
    if (relativeToData && exists(rolloutPath)) return rolloutPath;
  }

  return findRolloutFile(dataRoot, sessionId);
}

function snapshotFilePathForSession(snapshot, session) {
  const resolved = resolveRolloutFilePath(session.id, session.rolloutPath, snapshot.dataPath, snapshot.codexRoot);
  if (resolved) return resolved;
  const relative = snapshotRelativePath(session.rolloutPath, snapshot.codexRoot);
  return relative ? path.join(snapshot.dataPath, relative) : '';
}

async function loadSessionsInSnapshot(snapshot) {
  if (!snapshot) return [];
  const databasePath = path.join(snapshot.dataPath, 'state_5.sqlite');
  if (!exists(databasePath)) return [];

  let db;
  try {
    db = await openDatabase(databasePath);
    const rows = execRows(db, `
      SELECT
        id,
        title,
        rollout_path AS rolloutPath,
        cwd,
        model_provider AS modelProvider,
        COALESCE(model, 'unknown') AS model,
        source,
        created_at AS createdAt,
        updated_at AS updatedAt,
        archived
      FROM threads
      ORDER BY updated_at DESC, created_at DESC;
    `);
    return rows.map((row) => {
      const session = makeSession(row, false, 0);
      const probe = snapshotFilePathForSession(snapshot, session);
      const fileExists = exists(probe);
      return makeSession(row, fileExists, fileExists ? fileSize(probe) : 0);
    });
  } catch {
    return [];
  } finally {
    if (db) db.close();
  }
}

function extractSessionIdFromPath(filePath) {
  const match = filePath.match(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/);
  return match ? match[0].toLowerCase() : '';
}

function firstUserMessageFromRollout(filePath) {
  const lines = readLines(filePath).slice(0, 160);
  let meta = { cwd: '', provider: 'unknown', model: 'unknown', source: 'jsonl', title: '' };
  for (const line of lines) {
    if (line.includes('"session_meta"')) {
      const obj = parseJsonLine(line);
      if (obj?.payload) {
        meta.cwd = obj.payload.cwd || meta.cwd;
        meta.provider = obj.payload.model_provider || meta.provider;
        meta.model = obj.payload.model || meta.model;
        meta.source = obj.payload.source || meta.source;
      }
    }
    if (line.includes('"user_message"')) {
      const obj = parseJsonLine(line);
      if (obj?.payload?.message) {
        meta.title = obj.payload.message;
        break;
      }
    }
  }
  return meta;
}

function walkFiles(root, predicate, output = []) {
  if (!exists(root)) return output;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) walkFiles(fullPath, predicate, output);
    if (entry.isFile() && predicate(fullPath, entry)) output.push(fullPath);
  }
  return output;
}

function loadTitleMaps() {
  const titles = new Map();
  const archived = new Map();
  for (const line of readLines(path.join(codexRoot, 'history.jsonl'))) {
    if (!line.includes('session_id')) continue;
    const obj = parseJsonLine(line);
    if (obj?.session_id) {
      if (obj.first_text) titles.set(String(obj.session_id), String(obj.first_text));
      if (obj.is_archived !== undefined) archived.set(String(obj.session_id), Boolean(obj.is_archived));
    }
  }
  for (const line of readLines(path.join(codexRoot, 'session_index.jsonl'))) {
    if (!line.includes('"id"')) continue;
    const obj = parseJsonLine(line);
    if (obj?.id && obj.thread_name) titles.set(String(obj.id), String(obj.thread_name));
  }
  return { titles, archived };
}

function loadSessionsFromFiles() {
  const { titles, archived } = loadTitleMaps();
  const files = [
    ...walkFiles(path.join(codexRoot, 'sessions'), (filePath) => filePath.endsWith('.jsonl')),
    ...walkFiles(path.join(codexRoot, 'archived_sessions'), (filePath) => filePath.endsWith('.jsonl'))
  ];

  return files.map((filePath) => {
    const id = extractSessionIdFromPath(filePath);
    const stat = fs.statSync(filePath);
    const meta = firstUserMessageFromRollout(filePath);
    const row = {
      id,
      title: titles.get(id) || meta.title || id,
      rolloutPath: filePath,
      cwd: meta.cwd,
      modelProvider: meta.provider,
      model: meta.model,
      source: meta.source,
      createdAtIso: stat.birthtime.toISOString(),
      updatedAtIso: stat.mtime.toISOString(),
      archived: archived.has(id) ? archived.get(id) : filePath.includes(`${path.sep}archived_sessions${path.sep}`)
    };
    return makeSession(row, true, stat.size);
  }).sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
}

function inferSnapshotReason(snapshot) {
  if (snapshot?.reason) return String(snapshot.reason);
  const id = String(snapshot?.id || '');
  return id.length > 16 ? id.slice(16) : 'unknown';
}

function snapshotKind(snapshot) {
  if (snapshot?.kind) return String(snapshot.kind);
  return inferSnapshotReason(snapshot) === 'manual' ? 'manual' : 'system';
}

function snapshotKindLabel(snapshot) {
  return snapshotKind(snapshot) === 'manual' ? '手动' : '系统自动';
}

function defaultSnapshotName(reason, currentState) {
  const suffix = `${currentState.modelProvider}/${currentState.model}`;
  if (reason === 'manual') return `手动快照 · ${suffix}`;
  if (reason === 'auto-protect') return `自动会话保护点 · ${suffix}`;
  if (reason === 'pre-restore') return `恢复前自动备份 · ${suffix}`;
  if (reason === 'pre-auto-restore') return `自动找回前备份 · ${suffix}`;
  if (reason === 'pre-delete-session') return `删除前自动备份 · ${suffix}`;
  if (reason === 'pre-single-session-restore') return `单会话恢复前备份 · ${suffix}`;
  if (reason === 'pre-batch-session-restore') return `批量会话恢复前备份 · ${suffix}`;
  return `Codex · ${suffix}`;
}

async function loadSessions() {
  if (!exists(codexRoot)) return [];
  const dbSessions = await loadSessionsFromSqlite(codexRoot);
  if (dbSessions.length) return dbSessions;
  return loadSessionsFromFiles();
}

function loadSnapshots() {
  if (!exists(snapshotRoot)) return [];
  return fs.readdirSync(snapshotRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => {
      const snapshotPath = path.join(snapshotRoot, entry.name);
      const metaPath = path.join(snapshotPath, 'snapshot.json');
      if (!exists(metaPath)) return null;
      try {
        const meta = JSON.parse(readText(metaPath));
        return {
          id: meta.id || entry.name,
          name: meta.name || entry.name,
          createdAt: toDate(meta.createdAt),
          path: snapshotPath,
          dataPath: path.join(snapshotPath, 'data'),
          reason: meta.reason || null,
          kind: meta.kind || null,
          kindLabel: snapshotKindLabel({ ...meta, id: meta.id || entry.name }),
          isManualSnapshot: snapshotKind({ ...meta, id: meta.id || entry.name }) === 'manual',
          modelProvider: meta.modelProvider || 'unknown',
          model: meta.model || 'unknown',
          accountFingerprint: meta.accountFingerprint || 'none',
          sessionCount: meta.sessionCount || 0,
          archivedSessionCount: meta.archivedSessionCount || 0,
          sizeBytes: meta.sizeBytes || directorySize(path.join(snapshotPath, 'data')),
          includedPaths: meta.includedPaths || [],
          codexRoot: meta.codexRoot || codexRoot
        };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
}

function getSnapshotById(snapshotId) {
  return loadSnapshots().find((snapshot) => snapshot.id === snapshotId);
}

async function recoverableSessionCount(snapshot) {
  const indexedCount = (await loadSessionsInSnapshot(snapshot)).filter((session) => session.existsOnDisk).length;
  return indexedCount > 0 ? indexedCount : Number(snapshot.sessionCount || 0) + Number(snapshot.archivedSessionCount || 0);
}

async function latestAutoRestoreCandidate(snapshots) {
  const candidates = snapshots
    .filter((snapshot) => snapshotKind(snapshot) === 'manual' || inferSnapshotReason(snapshot) === 'auto-protect')
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));

  for (const snapshot of candidates) {
    if (await recoverableSessionCount(snapshot) > 0) return snapshot;
  }
  return null;
}

async function autoRestoreSuggestion(sessions, snapshots) {
  const settings = loadSettings();
  if (!settings.autoRestoreOnLaunch) return null;
  const latestSnapshot = await latestAutoRestoreCandidate(snapshots);
  if (!latestSnapshot) return null;
  const snapshotCount = await recoverableSessionCount(latestSnapshot);
  const currentCount = sessions.length;
  if (snapshotCount <= currentCount) return null;
  return {
    snapshotId: latestSnapshot.id,
    snapshotName: latestSnapshot.name,
    snapshotCount,
    currentCount
  };
}

function timestampId() {
  const date = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

function copyPathIntoSnapshot(relativePath, dataPath) {
  const source = path.join(codexRoot, relativePath);
  if (!exists(source)) return false;
  const destination = path.join(dataPath, relativePath);
  ensureDir(path.dirname(destination));
  fs.cpSync(source, destination, { recursive: true, force: true });
  return true;
}

function removeStateDatabaseSidecars(dataPath) {
  for (const relativePath of ['state_5.sqlite-shm', 'state_5.sqlite-wal']) {
    const targetPath = path.join(dataPath, relativePath);
    if (exists(targetPath)) fs.rmSync(targetPath, { force: true });
  }
}

function snapshotSessionCounts(dataPath, sessionIds) {
  let active = 0;
  let archived = 0;
  for (const sessionId of sessionIds) {
    const rolloutPath = findRolloutFile(dataPath, sessionId);
    const relative = safeRelativePath(dataPath, rolloutPath);
    if (!relative) continue;
    if (relative.split(path.sep)[0] === 'archived_sessions') archived += 1;
    else active += 1;
  }
  return { active, archived };
}

function repairSnapshotStateDatabaseRolloutPaths(db, dataPath, snapshotCodexRoot, sessionIds) {
  for (const sessionId of sessionIds) {
    const rolloutPath = findRolloutFile(dataPath, sessionId);
    const relative = safeRelativePath(dataPath, rolloutPath);
    if (!relative) continue;
    const archived = relative.split(path.sep)[0] === 'archived_sessions';
    updateThreadRolloutPath(db, sessionId, path.join(snapshotCodexRoot, relative), archived);
  }
}

async function sanitizeSnapshotData(dataPath, snapshotCodexRoot) {
  const databasePath = path.join(dataPath, 'state_5.sqlite');
  if (!exists(databasePath)) return new Set();

  const snapshot = { dataPath, codexRoot: snapshotCodexRoot };
  const restorableSessionIds = new Set(
    (await loadSessionsInSnapshot(snapshot))
      .filter((session) => session.existsOnDisk)
      .map((session) => session.id)
  );

  let db;
  try {
    db = await openDatabase(databasePath);
    pruneStateDatabase(db, restorableSessionIds);
    repairSnapshotStateDatabaseRolloutPaths(db, dataPath, snapshotCodexRoot, restorableSessionIds);
    writeDatabase(databasePath, db);
  } finally {
    if (db) db.close();
  }

  for (const relativePath of conversationLineMergePaths) {
    filterLineFile(
      path.join(dataPath, relativePath),
      relativePath === 'session_index.jsonl' ? 'id' : null,
      restorableSessionIds
    );
  }
  removeStateDatabaseSidecars(dataPath);
  return restorableSessionIds;
}

function pruneSnapshots(snapshots, limit) {
  if (limit < 0) return;
  const sorted = [...snapshots].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  for (const snapshot of sorted.slice(limit)) {
    if (exists(snapshot.path)) fs.rmSync(snapshot.path, { recursive: true, force: true });
  }
}

function enforceAutomaticSnapshotRetention(maxSystemSnapshots = 24, maxAutoProtectSnapshots = 3) {
  pruneSnapshots(loadSnapshots().filter((snapshot) => inferSnapshotReason(snapshot) === 'auto-protect'), maxAutoProtectSnapshots);
  pruneSnapshots(loadSnapshots().filter((snapshot) => snapshotKind(snapshot) !== 'manual'), maxSystemSnapshots);
}

async function createSnapshot(name, reason, candidates = backupCandidates) {
  if (!exists(codexRoot)) throw new Error(`Codex 数据目录不存在：${codexRoot}`);
  ensureDir(snapshotRoot);
  const baseId = `${timestampId()}-${reason}`;
  let id = baseId;
  let collisionIndex = 2;
  while (exists(path.join(snapshotRoot, id))) {
    id = `${baseId}-${collisionIndex}`;
    collisionIndex += 1;
  }
  const snapshotPath = path.join(snapshotRoot, id);
  const dataPath = path.join(snapshotPath, 'data');
  ensureDir(dataPath);
  const includedPaths = candidates
    .filter((candidate) => !stateDatabaseSnapshotPaths.has(candidate))
    .filter((candidate) => copyPathIntoSnapshot(candidate, dataPath));

  if (candidates.includes('state_5.sqlite') && copyPathIntoSnapshot('state_5.sqlite', dataPath)) {
    includedPaths.push('state_5.sqlite');
  }

  let sanitizedCounts = null;
  if (includedPaths.includes('state_5.sqlite')) {
    const restorableSessionIds = await sanitizeSnapshotData(dataPath, codexRoot);
    sanitizedCounts = snapshotSessionCounts(dataPath, restorableSessionIds);
  }

  const currentState = inspectCurrentState();
  const meta = {
    id,
    name: name || defaultSnapshotName(reason, currentState),
    createdAt: new Date().toISOString(),
    codexRoot,
    reason,
    kind: snapshotKind({ reason }),
    modelProvider: currentState.modelProvider,
    model: currentState.model,
    accountFingerprint: currentState.accountFingerprint,
    sessionCount: sanitizedCounts?.active ?? currentState.sessionCount,
    archivedSessionCount: sanitizedCounts?.archived ?? currentState.archivedSessionCount,
    sizeBytes: directorySize(dataPath),
    includedPaths,
    appVersion: `win-exe-${appVersion}`
  };
  fs.writeFileSync(path.join(snapshotPath, 'snapshot.json'), JSON.stringify(meta, null, 2), 'utf8');
  return meta;
}

async function createSystemSnapshot(name, reason, candidates = backupCandidates) {
  const meta = await createSnapshot(name, reason, candidates);
  enforceAutomaticSnapshotRetention();
  return meta;
}

function copyRolloutFilesForSessions(sessionIds, dataPath) {
  const included = new Set();
  for (const dir of ['sessions', 'archived_sessions']) {
    const files = walkFiles(
      path.join(codexRoot, dir),
      (filePath) => filePath.endsWith('.jsonl') && [...sessionIds].some((sessionId) => path.basename(filePath).includes(sessionId))
    );
    for (const filePath of files) {
      const relative = safeRelativePath(codexRoot, filePath);
      if (!relative) continue;
      copyReplacing(filePath, path.join(dataPath, relative));
      included.add(dir);
    }
  }
  return included;
}

function copyShellSnapshotsForSessions(sessionIds, dataPath) {
  const shellDir = path.join(codexRoot, 'shell_snapshots');
  const files = walkFiles(
    shellDir,
    (filePath) => [...sessionIds].some((sessionId) => path.basename(filePath).includes(sessionId))
  );
  for (const filePath of files) {
    copyReplacing(filePath, path.join(dataPath, 'shell_snapshots', path.basename(filePath)));
  }
  return files.length > 0;
}

async function createSessionProtectionSnapshot(name, reason, sessions) {
  if (!exists(codexRoot)) throw new Error(`Codex 数据目录不存在：${codexRoot}`);
  const sessionIds = new Set((sessions || []).map((session) => String(session.id)).filter(Boolean));
  if (!sessionIds.size) throw new Error('没有可备份的会话。');

  ensureDir(snapshotRoot);
  const baseId = `${timestampId()}-${reason}`;
  let id = baseId;
  let collisionIndex = 2;
  while (exists(path.join(snapshotRoot, id))) {
    id = `${baseId}-${collisionIndex}`;
    collisionIndex += 1;
  }

  const snapshotPath = path.join(snapshotRoot, id);
  const dataPath = path.join(snapshotPath, 'data');
  ensureDir(dataPath);
  const includedPaths = new Set();

  for (const relativePath of conversationLineMergePaths) {
    const source = path.join(codexRoot, relativePath);
    if (!exists(source)) continue;
    const destination = path.join(dataPath, relativePath);
    copyReplacing(source, destination);
    filterLineFile(destination, relativePath === 'session_index.jsonl' ? 'id' : null, sessionIds);
    includedPaths.add(relativePath);
  }

  for (const relativePath of copyRolloutFilesForSessions(sessionIds, dataPath)) {
    includedPaths.add(relativePath);
  }
  if (copyShellSnapshotsForSessions(sessionIds, dataPath)) {
    includedPaths.add('shell_snapshots');
  }
  if (copyPathIntoSnapshot('state_5.sqlite', dataPath)) {
    includedPaths.add('state_5.sqlite');
  }

  const restorableSessionIds = await sanitizeSnapshotData(dataPath, codexRoot);
  const counts = snapshotSessionCounts(dataPath, restorableSessionIds);
  const currentState = inspectCurrentState();
  const meta = {
    id,
    name,
    createdAt: new Date().toISOString(),
    codexRoot,
    reason,
    kind: snapshotKind({ reason }),
    modelProvider: currentState.modelProvider,
    model: currentState.model,
    accountFingerprint: currentState.accountFingerprint,
    sessionCount: counts.active,
    archivedSessionCount: counts.archived,
    sizeBytes: directorySize(dataPath),
    includedPaths: [...includedPaths].sort(),
    appVersion: `win-exe-${appVersion}`
  };
  fs.writeFileSync(path.join(snapshotPath, 'snapshot.json'), JSON.stringify(meta, null, 2), 'utf8');
  enforceAutomaticSnapshotRetention();
  return meta;
}

function normalizeRestoreProtectionMode(value, fallback = 'lightweight') {
  return value === 'full' || value === 'lightweight' ? value : fallback;
}

async function createRestoreProtectionSnapshot(name, reason, protectionMode, sessions, fullCandidates, extraLightweightCandidates = []) {
  const mode = normalizeRestoreProtectionMode(protectionMode);
  if (mode === 'full' || !(sessions || []).length) {
    return createSystemSnapshot(name, reason, fullCandidates);
  }

  const meta = await createSessionProtectionSnapshot(name, reason, sessions);
  if (!extraLightweightCandidates.length) return meta;

  const snapshot = getSnapshotById(meta.id);
  if (!snapshot) return meta;
  for (const relativePath of extraLightweightCandidates) {
    if (conversationLineMergePaths.includes(relativePath) || stateDatabaseSnapshotPaths.has(relativePath)) continue;
    copyPathIntoSnapshot(relativePath, snapshot.dataPath);
  }

  const metaPath = path.join(snapshot.path, 'snapshot.json');
  const updatedMeta = JSON.parse(readText(metaPath));
  updatedMeta.includedPaths = [
    ...new Set([
      ...(updatedMeta.includedPaths || []),
      ...extraLightweightCandidates.filter((relativePath) => exists(path.join(snapshot.dataPath, relativePath)))
    ])
  ].sort();
  updatedMeta.sizeBytes = directorySize(snapshot.dataPath);
  fs.writeFileSync(metaPath, JSON.stringify(updatedMeta, null, 2), 'utf8');
  return updatedMeta;
}

function findLatestSnapshotRollout(sessionId) {
  for (const snapshot of loadSnapshots()) {
    const files = [
      ...walkFiles(path.join(snapshot.dataPath, 'sessions'), (filePath) => filePath.endsWith('.jsonl') && filePath.includes(sessionId)),
      ...walkFiles(path.join(snapshot.dataPath, 'archived_sessions'), (filePath) => filePath.endsWith('.jsonl') && filePath.includes(sessionId))
    ];
    if (files.length) return { snapshot, rolloutPath: files[0] };
  }
  return null;
}

function relativeFromDataRoot(dataPath, filePath) {
  const relative = path.relative(dataPath, filePath);
  return relative && !relative.startsWith('..') ? relative : path.basename(filePath);
}

function mergeLinesContaining(sourcePath, destinationPath, needle) {
  if (!exists(sourcePath)) return;
  ensureDir(path.dirname(destinationPath));
  const seen = new Set();
  const output = [];
  for (const line of readLines(destinationPath)) {
    if (!seen.has(line)) {
      seen.add(line);
      output.push(line);
    }
  }
  for (const line of readLines(sourcePath)) {
    if (line.includes(needle) && !seen.has(line)) {
      seen.add(line);
      output.push(line);
    }
  }
  fs.writeFileSync(destinationPath, `${output.join('\n')}${output.length ? '\n' : ''}`, 'utf8');
}

function removeLinesContaining(targetPath, needle) {
  if (!exists(targetPath)) return;
  const output = readLines(targetPath).filter((line) => !line.includes(needle));
  fs.writeFileSync(targetPath, `${output.join('\n')}${output.length ? '\n' : ''}`, 'utf8');
}

function restoreShellSnapshots(sessionId, dataPath) {
  const sourceDir = path.join(dataPath, 'shell_snapshots');
  if (!exists(sourceDir)) return;
  const files = walkFiles(sourceDir, (filePath) => path.basename(filePath).includes(sessionId));
  for (const filePath of files) {
    const destination = path.join(codexRoot, 'shell_snapshots', path.basename(filePath));
    ensureDir(path.dirname(destination));
    fs.copyFileSync(filePath, destination);
  }
}

function removeEmptyParents(startDir, stopDir) {
  let current = path.resolve(startDir);
  const stop = path.resolve(stopDir);
  while (current.startsWith(stop) && current !== stop) {
    if (!exists(current)) {
      current = path.dirname(current);
      continue;
    }
    const entries = fs.readdirSync(current);
    if (entries.length > 0) return;
    fs.rmdirSync(current);
    current = path.dirname(current);
  }
}

function copyReplacing(sourcePath, destinationPath) {
  ensureDir(path.dirname(destinationPath));
  if (exists(destinationPath)) fs.rmSync(destinationPath, { recursive: true, force: true });
  fs.cpSync(sourcePath, destinationPath, { recursive: true, force: true });
}

function mergeDirectory(sourceDir, destinationDir) {
  if (!exists(sourceDir)) return;
  if (!exists(destinationDir)) {
    copyReplacing(sourceDir, destinationDir);
    return;
  }
  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const destinationPath = path.join(destinationDir, entry.name);
    if (entry.isDirectory()) {
      mergeDirectory(sourcePath, destinationPath);
    } else if (entry.isFile()) {
      copyReplacing(sourcePath, destinationPath);
    }
  }
}

function jsonLineIdentity(line, key) {
  const obj = parseJsonLine(line);
  if (!obj || obj[key] === undefined || obj[key] === null) return null;
  return `${key}:${String(obj[key])}`;
}

function lineContainsAnySessionId(line, allowedSessionIds) {
  if (!allowedSessionIds || allowedSessionIds.size === 0) return false;
  const obj = parseJsonLine(line);
  if (obj) {
    for (const key of ['session_id', 'id', 'thread_id']) {
      if (obj[key] && allowedSessionIds.has(String(obj[key]))) return true;
    }
  }
  return [...allowedSessionIds].some((sessionId) => String(line).includes(sessionId));
}

function mergeLineFile(sourcePath, destinationPath, uniqueKey = null, allowedSessionIds = null) {
  if (!exists(sourcePath)) return;
  ensureDir(path.dirname(destinationPath));
  if (!exists(destinationPath) && !allowedSessionIds) {
    copyReplacing(sourcePath, destinationPath);
    return;
  }

  const seen = new Set();
  const output = [];
  const addLine = (line, requiresAllowedSession = false) => {
    if (!String(line).trim()) return;
    if (requiresAllowedSession && allowedSessionIds && !lineContainsAnySessionId(line, allowedSessionIds)) return;
    const identity = uniqueKey ? (jsonLineIdentity(line, uniqueKey) || line) : line;
    if (seen.has(identity)) return;
    seen.add(identity);
    output.push(line);
  };

  if (exists(destinationPath)) readLines(destinationPath).forEach((line) => addLine(line, false));
  readLines(sourcePath).forEach((line) => addLine(line, true));
  fs.writeFileSync(destinationPath, `${output.join('\n')}${output.length ? '\n' : ''}`, 'utf8');
}

function filterLineFile(targetPath, uniqueKey, allowedSessionIds) {
  if (!exists(targetPath)) return;
  const seen = new Set();
  const output = [];
  for (const line of readLines(targetPath)) {
    if (!String(line).trim()) continue;
    if (!lineContainsAnySessionId(line, allowedSessionIds)) continue;
    const identity = uniqueKey ? (jsonLineIdentity(line, uniqueKey) || line) : line;
    if (seen.has(identity)) continue;
    seen.add(identity);
    output.push(line);
  }
  fs.writeFileSync(targetPath, `${output.join('\n')}${output.length ? '\n' : ''}`, 'utf8');
}

function writeDatabase(databasePath, db) {
  ensureDir(path.dirname(databasePath));
  fs.writeFileSync(databasePath, Buffer.from(db.export()));
}

function purgeAccountBindings(db) {
  for (const table of ['device_key_bindings', 'remote_control_enrollments']) {
    if (tableExists(db, table)) db.run(`DELETE FROM ${quoteIdent(table)};`);
  }
}

function sessionIdList(allowedSessionIds) {
  return [...allowedSessionIds].map(quoteLiteral).join(', ');
}

function stateDatabaseWhereClause(table, allowedSessionIds) {
  if (!allowedSessionIds) return '';
  if (allowedSessionIds.size === 0) return ' WHERE 0';
  const ids = sessionIdList(allowedSessionIds);
  if (table === 'threads') return ` WHERE id IN (${ids})`;
  if (table === 'thread_spawn_edges') return ` WHERE parent_thread_id IN (${ids}) OR child_thread_id IN (${ids})`;
  return ` WHERE thread_id IN (${ids})`;
}

function pruneStateDatabase(db, allowedSessionIds) {
  if (allowedSessionIds.size === 0) {
    const statements = [
      { table: 'thread_dynamic_tools', sql: 'DELETE FROM thread_dynamic_tools;' },
      { table: 'thread_goals', sql: 'DELETE FROM thread_goals;' },
      { table: 'thread_spawn_edges', sql: 'DELETE FROM thread_spawn_edges;' },
      { table: 'stage1_outputs', sql: 'DELETE FROM stage1_outputs;' },
      { table: 'threads', sql: 'DELETE FROM threads;' }
    ];
    for (const statement of statements) {
      if (tableExists(db, statement.table)) db.run(statement.sql);
    }
    return;
  }

  const ids = sessionIdList(allowedSessionIds);
  const statements = [
    { table: 'thread_dynamic_tools', sql: `DELETE FROM thread_dynamic_tools WHERE thread_id NOT IN (${ids});` },
    { table: 'thread_goals', sql: `DELETE FROM thread_goals WHERE thread_id NOT IN (${ids});` },
    { table: 'thread_spawn_edges', sql: `DELETE FROM thread_spawn_edges WHERE parent_thread_id NOT IN (${ids}) AND child_thread_id NOT IN (${ids});` },
    { table: 'stage1_outputs', sql: `DELETE FROM stage1_outputs WHERE thread_id NOT IN (${ids});` },
    { table: 'threads', sql: `DELETE FROM threads WHERE id NOT IN (${ids});` }
  ];
  for (const statement of statements) {
    if (tableExists(db, statement.table)) db.run(statement.sql);
  }
}

function updateThreadRolloutPath(db, sessionId, rolloutPath, archived = null) {
  if (!tableExists(db, 'threads')) return;
  const archivedSql = archived === null ? '' : ', archived = ?';
  const statement = db.prepare(`UPDATE threads SET rollout_path = ?${archivedSql} WHERE id = ?;`);
  statement.run(archived === null ? [rolloutPath, sessionId] : [rolloutPath, archived ? 1 : 0, sessionId]);
  statement.free();
}

function repairStateDatabaseRolloutPaths(db, root, sessionIds) {
  for (const sessionId of sessionIds) {
    const rolloutPath = findRolloutFile(root, sessionId);
    if (rolloutPath) {
      const relative = safeRelativePath(root, rolloutPath);
      const archived = relative ? relative.split(path.sep)[0] === 'archived_sessions' : null;
      updateThreadRolloutPath(db, sessionId, rolloutPath, archived);
    }
  }
}

async function mergeStateDatabase(sourceDbPath, destinationDbPath, allowedSessionIds = null) {
  if (!exists(sourceDbPath)) return 'SQLite 索引未合并：快照数据库缺失。';
  if (allowedSessionIds && allowedSessionIds.size === 0) return 'SQLite 索引未合并：快照中没有可恢复的会话文件。';

  if (!exists(destinationDbPath)) {
    copyReplacing(sourceDbPath, destinationDbPath);
    let db;
    try {
      db = await openDatabase(destinationDbPath);
      purgeAccountBindings(db);
      if (allowedSessionIds) pruneStateDatabase(db, allowedSessionIds);
      writeDatabase(destinationDbPath, db);
      return 'SQLite 索引已恢复，并清理账号绑定表。';
    } finally {
      if (db) db.close();
    }
  }

  let sourceDb;
  let destinationDb;
  try {
    sourceDb = await openDatabase(sourceDbPath);
    destinationDb = await openDatabase(destinationDbPath);
    destinationDb.run('BEGIN TRANSACTION;');
    for (const table of conversationStateTables) {
      const sourceColumns = tableColumns(sourceDb, table);
      const destinationColumns = tableColumns(destinationDb, table);
      const commonColumns = destinationColumns.filter((column) => sourceColumns.includes(column));
      if (!commonColumns.length) continue;
      const whereClause = stateDatabaseWhereClause(table, allowedSessionIds);
      const rows = execRows(sourceDb, `SELECT ${commonColumns.map(quoteIdent).join(', ')} FROM ${quoteIdent(table)}${whereClause};`);
      if (!rows.length) continue;
      const statement = destinationDb.prepare(
        `INSERT OR REPLACE INTO ${quoteIdent(table)} (${commonColumns.map(quoteIdent).join(', ')}) VALUES (${commonColumns.map(() => '?').join(', ')});`
      );
      for (const row of rows) statement.run(commonColumns.map((column) => row[column]));
      statement.free();
    }
    destinationDb.run('COMMIT;');
    writeDatabase(destinationDbPath, destinationDb);
    return 'SQLite 索引已合并。';
  } catch (error) {
    try {
      if (destinationDb) destinationDb.run('ROLLBACK;');
    } catch {
      // ignore rollback failures
    }
    throw new Error(`SQLite 索引合并失败：${error.message}`);
  } finally {
    if (sourceDb) sourceDb.close();
    if (destinationDb) destinationDb.close();
  }
}

async function restoreConversationsOnly(snapshot) {
  if (!snapshot || !exists(snapshot.dataPath)) throw new Error('快照结构不完整，无法恢复。');
  ensureDir(codexRoot);

  const included = new Set(snapshot.includedPaths || []);
  const restorableSessionIds = included.has('state_5.sqlite')
    ? new Set((await loadSessionsInSnapshot(snapshot)).filter((session) => session.existsOnDisk).map((session) => session.id))
    : null;

  for (const relativePath of conversationDirectoryPaths) {
    if (!included.has(relativePath)) continue;
    mergeDirectory(path.join(snapshot.dataPath, relativePath), path.join(codexRoot, relativePath));
  }

  for (const relativePath of conversationLineMergePaths) {
    if (!included.has(relativePath)) continue;
    mergeLineFile(
      path.join(snapshot.dataPath, relativePath),
      path.join(codexRoot, relativePath),
      relativePath === 'session_index.jsonl' ? 'id' : null,
      restorableSessionIds
    );
  }

  if (included.has('state_5.sqlite')) {
    const message = await mergeStateDatabase(
      path.join(snapshot.dataPath, 'state_5.sqlite'),
      path.join(codexRoot, 'state_5.sqlite'),
      restorableSessionIds
    );
    if (restorableSessionIds) await repairStateDatabaseFileRolloutPaths(path.join(codexRoot, 'state_5.sqlite'), codexRoot, restorableSessionIds);
    return message;
  }
  return 'SQLite 索引未合并：快照不包含 state_5.sqlite。';
}

async function repairStateDatabaseFileRolloutPaths(databasePath, root, sessionIds) {
  if (!exists(databasePath)) return;
  let db;
  try {
    db = await openDatabase(databasePath);
    repairStateDatabaseRolloutPaths(db, root, sessionIds);
    writeDatabase(databasePath, db);
  } finally {
    if (db) db.close();
  }
}

async function restoreFull(snapshot) {
  if (!snapshot || !exists(snapshot.dataPath)) throw new Error('快照结构不完整，无法恢复。');
  ensureDir(codexRoot);
  const included = new Set(snapshot.includedPaths || []);
  const restorableSessionIds = included.has('state_5.sqlite')
    ? new Set((await loadSessionsInSnapshot(snapshot)).filter((session) => session.existsOnDisk).map((session) => session.id))
    : null;

  for (const relativePath of snapshot.includedPaths || []) {
    const sourcePath = path.join(snapshot.dataPath, relativePath);
    if (!exists(sourcePath)) continue;
    copyReplacing(sourcePath, path.join(codexRoot, relativePath));
  }

  if (!restorableSessionIds) return;

  const databasePath = path.join(codexRoot, 'state_5.sqlite');
  if (exists(databasePath)) {
    let db;
    try {
      db = await openDatabase(databasePath);
      pruneStateDatabase(db, restorableSessionIds);
      repairStateDatabaseRolloutPaths(db, codexRoot, restorableSessionIds);
      writeDatabase(databasePath, db);
    } finally {
      if (db) db.close();
    }
  }

  for (const relativePath of conversationLineMergePaths) {
    if (!included.has(relativePath)) continue;
    filterLineFile(
      path.join(codexRoot, relativePath),
      relativePath === 'session_index.jsonl' ? 'id' : null,
      restorableSessionIds
    );
  }
}

async function mergeSingleSessionStateDb(snapshotDbPath, destinationDbPath, sessionId) {
  if (!exists(snapshotDbPath) || !exists(destinationDbPath)) return 'SQLite 索引未合并：数据库文件缺失。';
  let sourceDb;
  let destinationDb;
  try {
    sourceDb = await openDatabase(snapshotDbPath);
    destinationDb = await openDatabase(destinationDbPath);
    const rules = [
      { table: 'threads', where: `id = ${quoteLiteral(sessionId)}` },
      { table: 'thread_goals', where: `thread_id = ${quoteLiteral(sessionId)}` },
      { table: 'thread_dynamic_tools', where: `thread_id = ${quoteLiteral(sessionId)}` },
      { table: 'stage1_outputs', where: `thread_id = ${quoteLiteral(sessionId)}` },
      { table: 'thread_spawn_edges', where: `parent_thread_id = ${quoteLiteral(sessionId)} OR child_thread_id = ${quoteLiteral(sessionId)}` }
    ];
    destinationDb.run('BEGIN TRANSACTION;');
    for (const rule of rules) {
      const sourceColumns = tableColumns(sourceDb, rule.table);
      const destinationColumns = tableColumns(destinationDb, rule.table);
      const commonColumns = destinationColumns.filter((column) => sourceColumns.includes(column));
      if (!commonColumns.length) continue;
      const rows = execRows(sourceDb, `SELECT ${commonColumns.map(quoteIdent).join(', ')} FROM ${quoteIdent(rule.table)} WHERE ${rule.where};`);
      if (!rows.length) continue;
      const sql = `INSERT OR REPLACE INTO ${quoteIdent(rule.table)} (${commonColumns.map(quoteIdent).join(', ')}) VALUES (${commonColumns.map(() => '?').join(', ')});`;
      const statement = destinationDb.prepare(sql);
      for (const row of rows) statement.run(commonColumns.map((column) => row[column]));
      statement.free();
    }
    destinationDb.run('COMMIT;');
    fs.writeFileSync(destinationDbPath, Buffer.from(destinationDb.export()));
    return 'SQLite 索引已合并。';
  } catch (error) {
    try {
      if (destinationDb) destinationDb.run('ROLLBACK;');
    } catch {
      // ignore rollback failures
    }
    return `SQLite 索引合并失败：${error.message}`;
  } finally {
    if (sourceDb) sourceDb.close();
    if (destinationDb) destinationDb.close();
  }
}

async function deleteSingleSessionStateDb(destinationDbPath, sessionId) {
  if (!exists(destinationDbPath)) return 'SQLite 索引未删除：数据库文件缺失。';
  let db;
  try {
    db = await openDatabase(destinationDbPath);
    const statements = [
      { table: 'thread_dynamic_tools', sql: `DELETE FROM thread_dynamic_tools WHERE thread_id = ${quoteLiteral(sessionId)};` },
      { table: 'thread_goals', sql: `DELETE FROM thread_goals WHERE thread_id = ${quoteLiteral(sessionId)};` },
      { table: 'thread_spawn_edges', sql: `DELETE FROM thread_spawn_edges WHERE parent_thread_id = ${quoteLiteral(sessionId)} OR child_thread_id = ${quoteLiteral(sessionId)};` },
      { table: 'stage1_outputs', sql: `DELETE FROM stage1_outputs WHERE thread_id = ${quoteLiteral(sessionId)};` },
      { table: 'threads', sql: `DELETE FROM threads WHERE id = ${quoteLiteral(sessionId)};` }
    ];
    db.run('BEGIN TRANSACTION;');
    for (const statement of statements) {
      if (tableExists(db, statement.table)) db.run(statement.sql);
    }
    db.run('COMMIT;');
    fs.writeFileSync(destinationDbPath, Buffer.from(db.export()));
    return 'SQLite 索引已删除。';
  } catch (error) {
    try {
      if (db) db.run('ROLLBACK;');
    } catch {
      // ignore rollback failures
    }
    return `SQLite 索引删除失败：${error.message}`;
  } finally {
    if (db) db.close();
  }
}

function extractConversationText(value) {
  if (!value) return '';
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(extractConversationText).filter(Boolean).join('\n');
  if (typeof value === 'object') {
    for (const key of ['text', 'message', 'content', 'input', 'output']) {
      const text = extractConversationText(value[key]);
      if (text.trim()) return text;
    }
  }
  return '';
}

function loadConversationMessages(session) {
  if (!session || !exists(session.rolloutPath)) throw new Error('会话文件不存在。');
  const lines = readLines(session.rolloutPath);
  const eventMessages = [];
  const responseMessages = [];
  lines.forEach((line, index) => {
    if (line.includes('"event_msg"') && (line.includes('"user_message"') || line.includes('"agent_message"'))) {
      const obj = parseJsonLine(line);
      const type = obj?.payload?.type;
      if (!type) return;
      const role = type === 'user_message' ? '用户' : type === 'agent_message' ? '助手' : null;
      if (!role) return;
      const text = String(obj.payload.message || extractConversationText(obj.payload.content)).trim();
      if (!text) return;
      eventMessages.push({
        id: `event-${index}`,
        role,
        phase: obj.payload.phase || '',
        timestamp: toDate(obj.timestamp),
        text
      });
      return;
    }
    if (eventMessages.length === 0 && line.includes('"response_item"') && line.includes('"message"')) {
      const obj = parseJsonLine(line);
      if (obj?.payload?.type !== 'message') return;
      const rawRole = obj.payload.role;
      if (rawRole !== 'user' && rawRole !== 'assistant') return;
      const text = extractConversationText(obj.payload.content).trim();
      if (!text) return;
      responseMessages.push({
        id: `response-${index}`,
        role: rawRole === 'user' ? '用户' : '助手',
        phase: obj.payload.phase || '',
        timestamp: toDate(obj.timestamp),
        text
      });
    }
  });
  return eventMessages.length ? eventMessages : responseMessages;
}

async function loadState() {
  ensureDir(snapshotRoot);
  const sessions = await loadSessions();
  const snapshots = loadSnapshots();
  return {
    currentState: inspectCurrentState(),
    sessions,
    snapshots,
    settings: loadSettings(),
    autoRestoreSuggestion: await autoRestoreSuggestion(sessions, snapshots)
  };
}

async function getSessionById(sessionId) {
  const sessions = await loadSessions();
  return sessions.find((session) => session.id === sessionId);
}

async function deleteSessionArtifacts(session) {
  if (session.rolloutPath && exists(session.rolloutPath)) fs.rmSync(session.rolloutPath, { force: true });
  for (const dir of ['sessions', 'archived_sessions']) {
    for (const filePath of walkFiles(path.join(codexRoot, dir), (itemPath) => path.basename(itemPath).includes(session.id) && itemPath.endsWith('.jsonl'))) {
      fs.rmSync(filePath, { force: true });
      removeEmptyParents(path.dirname(filePath), path.join(codexRoot, dir));
    }
  }
  for (const lineFile of ['history.jsonl', 'history.jsonl.bak', 'session_index.jsonl']) {
    removeLinesContaining(path.join(codexRoot, lineFile), session.id);
  }
  const shellDir = path.join(codexRoot, 'shell_snapshots');
  for (const filePath of walkFiles(shellDir, (itemPath) => path.basename(itemPath).includes(session.id))) {
    fs.rmSync(filePath, { force: true });
  }
  return deleteSingleSessionStateDb(path.join(codexRoot, 'state_5.sqlite'), session.id);
}

ipcMain.handle('load-state', async () => loadState());

ipcMain.handle('set-auto-restore', async (_event, enabled) => {
  return { ok: true, settings: saveSettings({ autoRestoreOnLaunch: Boolean(enabled) }) };
});

ipcMain.handle('create-snapshot', async (_event, name) => {
  const meta = await createSnapshot(name, 'manual', backupCandidates);
  return { ok: true, message: `快照已创建：${meta.name}` };
});

ipcMain.handle('load-snapshot-sessions', async (_event, snapshotId) => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  return loadSessionsInSnapshot(snapshot);
});

ipcMain.handle('open-snapshot', async (_event, snapshotId) => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  if (exists(snapshot.path)) await shell.openPath(snapshot.path);
  return { ok: true };
});

ipcMain.handle('choose-restore-protection-mode', async (event, options = {}) => {
  const defaultMode = normalizeRestoreProtectionMode(options.defaultMode, 'lightweight');
  const lightButton = '轻量保护点，推荐';
  const fullButton = '完整保护点';
  const buttons = defaultMode === 'full'
    ? [fullButton, lightButton, '取消恢复']
    : [lightButton, fullButton, '取消恢复'];
  const result = await dialog.showMessageBox(BrowserWindow.fromWebContents(event.sender) || mainWindow, {
    type: 'warning',
    title: options.title || '选择恢复前保护点',
    message: options.title || '选择恢复前保护点',
    detail: `${options.message || ''}\n\n恢复会改动 Codex 的会话文件、history.jsonl、session_index.jsonl 和 state_5.sqlite 线程记录。保护点用于恢复失败或选错快照时回退当前状态。\n\n轻量保护点只备份本次目标会话和相关索引，速度快，推荐日常单个/批量会话恢复。\n\n完整保护点会备份更完整的 Codex 状态，最稳妥，但如果 sessions 目录很大，创建时间会明显变长。`,
    buttons,
    defaultId: 0,
    cancelId: 2,
    noLink: true
  });

  if (result.response === 2) return null;
  if (result.response === 0) return defaultMode;
  return defaultMode === 'full' ? 'lightweight' : 'full';
});

ipcMain.handle('restore-snapshot-conversations', async (_event, snapshotId, protectionMode = 'lightweight') => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  const protectionSessions = (await loadSessionsInSnapshot(snapshot)).filter((session) => session.existsOnDisk);
  await createRestoreProtectionSnapshot(
    normalizeRestoreProtectionMode(protectionMode) === 'lightweight' ? 'Pre-Restore Lightweight Backup' : 'Pre-Restore Backup',
    normalizeRestoreProtectionMode(protectionMode) === 'lightweight' ? 'pre-restore-lightweight' : 'pre-restore',
    protectionMode,
    protectionSessions,
    backupCandidates
  );
  const sqliteMessage = await restoreConversationsOnly(snapshot);
  return {
    ok: true,
    message: `已从 ${snapshot.name} 恢复对话，当前账号、登录态和模型供应商配置已保留。${sqliteMessage}`
  };
});

ipcMain.handle('restore-snapshot-full', async (_event, snapshotId, protectionMode = 'full') => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  const mode = normalizeRestoreProtectionMode(protectionMode, 'full');
  const protectionSessions = mode === 'lightweight'
    ? (await loadSessions()).filter((session) => session.existsOnDisk)
    : (await loadSessionsInSnapshot(snapshot)).filter((session) => session.existsOnDisk);
  await createRestoreProtectionSnapshot(
    mode === 'lightweight' ? 'Pre-Restore Lightweight Backup' : 'Pre-Restore Backup',
    mode === 'lightweight' ? 'pre-restore-lightweight' : 'pre-restore',
    mode,
    protectionSessions,
    backupCandidates,
    ['config.toml', 'auth.json', '.codex-global-state.json', '.codex-global-state.json.bak']
  );
  await restoreFull(snapshot);
  return { ok: true, message: `已完整恢复快照：${snapshot.name}。请重启 Codex。` };
});

ipcMain.handle('restore-snapshot-session', async (_event, snapshotId, sessionId, protectionMode = 'lightweight') => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  const sessions = await loadSessionsInSnapshot(snapshot);
  const session = sessions.find((item) => item.id === sessionId);
  if (!session) throw new Error('这个快照里没有找到选中的会话。');
  if (!session.existsOnDisk) {
    throw new Error('这个快照只有会话索引，没有真实会话文件，无法恢复到 Codex 客户端。请选择包含会话文件的快照。');
  }
  await createRestoreProtectionSnapshot(
    'Pre-Single-Session Restore Backup',
    'pre-single-session-restore',
    protectionMode,
    [session],
    conversationBackupCandidates
  );

  const snapshotFilePath = snapshotFilePathForSession(snapshot, session);
  if (!snapshotFilePath || !exists(snapshotFilePath)) {
    throw new Error('这个快照里的会话文件路径无法映射到当前 Codex 数据目录。');
  }
  const relativePath = relativeFromDataRoot(snapshot.dataPath, snapshotFilePath);
  copyReplacing(snapshotFilePath, path.join(codexRoot, relativePath));

  for (const lineFile of conversationLineMergePaths) {
    mergeLinesContaining(path.join(snapshot.dataPath, lineFile), path.join(codexRoot, lineFile), sessionId);
  }
  restoreShellSnapshots(sessionId, snapshot.dataPath);
  const sqliteMessage = await mergeSingleSessionStateDb(
    path.join(snapshot.dataPath, 'state_5.sqlite'),
    path.join(codexRoot, 'state_5.sqlite'),
    sessionId
  );
  await repairStateDatabaseFileRolloutPaths(path.join(codexRoot, 'state_5.sqlite'), codexRoot, new Set([sessionId]));
  return { ok: true, message: `已恢复单个会话：${session.title || session.id}。${sqliteMessage}` };
});

ipcMain.handle('restore-snapshot-sessions', async (_event, snapshotId, sessionIds, protectionMode = 'lightweight') => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  const idSet = new Set(Array.isArray(sessionIds) ? sessionIds.map(String) : []);
  if (!idSet.size) throw new Error('没有选择要恢复的会话。');
  const sessions = (await loadSessionsInSnapshot(snapshot)).filter((item) => idSet.has(item.id) && item.existsOnDisk);
  if (!sessions.length) throw new Error('没有可恢复的会话文件。');

  await createRestoreProtectionSnapshot(
    'Pre-Batch-Session Restore Backup',
    'pre-batch-session-restore',
    protectionMode,
    sessions,
    conversationBackupCandidates
  );
  const restoredIds = new Set();
  for (const session of sessions) {
    const snapshotFilePath = snapshotFilePathForSession(snapshot, session);
    if (!snapshotFilePath || !exists(snapshotFilePath)) continue;
    const relativePath = relativeFromDataRoot(snapshot.dataPath, snapshotFilePath);
    copyReplacing(snapshotFilePath, path.join(codexRoot, relativePath));
    for (const lineFile of conversationLineMergePaths) {
      mergeLinesContaining(path.join(snapshot.dataPath, lineFile), path.join(codexRoot, lineFile), session.id);
    }
    restoreShellSnapshots(session.id, snapshot.dataPath);
    await mergeSingleSessionStateDb(
      path.join(snapshot.dataPath, 'state_5.sqlite'),
      path.join(codexRoot, 'state_5.sqlite'),
      session.id
    );
    restoredIds.add(session.id);
  }
  await repairStateDatabaseFileRolloutPaths(path.join(codexRoot, 'state_5.sqlite'), codexRoot, restoredIds);
  return { ok: true, message: `已从 ${snapshot.name} 批量恢复 ${restoredIds.size} 个会话。` };
});

ipcMain.handle('delete-snapshot', async (_event, snapshotId) => {
  const snapshot = getSnapshotById(snapshotId);
  if (!snapshot) throw new Error('没有找到快照。');
  fs.rmSync(snapshot.path, { recursive: true, force: true });
  return { ok: true, message: `快照已删除：${snapshot.name}` };
});

ipcMain.handle('delete-snapshots', async (_event, snapshotIds) => {
  const ids = Array.isArray(snapshotIds) ? snapshotIds : [];
  if (!ids.length) throw new Error('没有选择要删除的快照。');
  const idSet = new Set(ids);
  const snapshots = loadSnapshots().filter((snapshot) => idSet.has(snapshot.id));
  if (!snapshots.length) throw new Error('没有找到要删除的快照。');
  for (const snapshot of snapshots) {
    if (exists(snapshot.path)) fs.rmSync(snapshot.path, { recursive: true, force: true });
  }
  return { ok: true, message: `已删除 ${snapshots.length} 个快照` };
});

ipcMain.handle('restore-session', async (_event, sessionId, protectionMode = 'lightweight') => {
  const session = await getSessionById(sessionId);
  if (!session) throw new Error('没有找到当前会话。');
  const match = findLatestSnapshotRollout(sessionId);
  if (!match) throw new Error('快照库里没有包含这条会话的记录。');
  await createRestoreProtectionSnapshot(
    'Pre-Single-Session Restore Backup',
    'pre-single-session-restore',
    protectionMode,
    [session],
    conversationBackupCandidates
  );

  const relative = relativeFromDataRoot(match.snapshot.dataPath, match.rolloutPath);
  const destination = path.join(codexRoot, relative);
  ensureDir(path.dirname(destination));
  fs.copyFileSync(match.rolloutPath, destination);
  for (const lineFile of ['history.jsonl', 'history.jsonl.bak', 'session_index.jsonl']) {
    mergeLinesContaining(path.join(match.snapshot.dataPath, lineFile), path.join(codexRoot, lineFile), sessionId);
  }
  restoreShellSnapshots(sessionId, match.snapshot.dataPath);
  const sqliteMessage = await mergeSingleSessionStateDb(
    path.join(match.snapshot.dataPath, 'state_5.sqlite'),
    path.join(codexRoot, 'state_5.sqlite'),
    sessionId
  );
  await repairStateDatabaseFileRolloutPaths(path.join(codexRoot, 'state_5.sqlite'), codexRoot, new Set([sessionId]));
  return { ok: true, message: `已从 ${match.snapshot.name} 恢复：${session.title}。${sqliteMessage}` };
});

ipcMain.handle('delete-session', async (_event, sessionId) => {
  const session = await getSessionById(sessionId);
  if (!session) throw new Error('没有找到当前会话。');
  await createSessionProtectionSnapshot('Pre-Delete Session Backup', 'pre-delete-session', [session]);
  const sqliteMessage = await deleteSessionArtifacts(session);
  return { ok: true, message: `会话已删除：${session.title}。${sqliteMessage}` };
});

ipcMain.handle('delete-sessions', async (_event, sessionIds) => {
  const ids = Array.isArray(sessionIds) ? sessionIds : [];
  if (!ids.length) throw new Error('没有选择要删除的会话。');
  const idSet = new Set(ids);
  const sessions = (await loadSessions()).filter((session) => idSet.has(session.id));
  if (!sessions.length) throw new Error('没有找到要删除的会话。');
  await createSessionProtectionSnapshot('Pre-Delete Sessions Backup', 'pre-delete-session', sessions);
  const sqliteMessages = [];
  for (const session of sessions) {
    sqliteMessages.push(await deleteSessionArtifacts(session));
  }
  const sqliteSummary = [...new Set(sqliteMessages)].join(' ');
  return { ok: true, message: `已删除 ${sessions.length} 个会话。${sqliteSummary}` };
});

ipcMain.handle('load-conversation', async (_event, sessionId) => {
  const session = await getSessionById(sessionId);
  return loadConversationMessages(session);
});

ipcMain.handle('open-path', async (_event, targetPath) => {
  if (targetPath && exists(targetPath)) await shell.openPath(targetPath);
});

ipcMain.handle('reveal-path', async (_event, targetPath) => {
  if (targetPath && exists(targetPath)) shell.showItemInFolder(targetPath);
});

ipcMain.handle('open-codex-root', async () => {
  if (exists(codexRoot)) await shell.openPath(codexRoot);
});

ipcMain.handle('open-vault-root', async () => {
  ensureDir(vaultRoot);
  await shell.openPath(vaultRoot);
});

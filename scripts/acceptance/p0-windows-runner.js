#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

const repositoryRoot = path.resolve(__dirname, '..', '..');
const electronRoot = process.env.CODEX_P0_APP_ROOT
  ? path.resolve(process.env.CODEX_P0_APP_ROOT)
  : path.join(repositoryRoot, 'windows', 'codex_session_manager_electron');
const { BackupAgent } = require(path.join(electronRoot, 'src', 'backup', 'backup-agent'));
const { backupPaths } = require(path.join(electronRoot, 'src', 'backup', 'paths'));
const {
  preflightIncrementalRecovery,
  restoreIncrementalSessions,
} = require(path.join(electronRoot, 'src', 'backup', 'incremental-recovery'));

const REPORT_VERSION = 1;
const MARKER_FILENAME = 'p0-acceptance-marker.json';
const MARKER_KIND = 'codex-session-keeper-p0-acceptance';
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DEFAULT_UPLOAD_BYTES = Math.round(12.77 * 1024 * 1024);
const DEFAULT_RESTORE_BYTES = 287 * 1024 * 1024;
const DEFAULT_MINIMUM_THROUGHPUT = 5;
const MIB = 1024 * 1024;

function validateComponent(value, label) {
  if (typeof value !== 'string'
    || value.length === 0
    || value === '.'
    || value === '..'
    || value.includes('\0')
    || value.includes('/')
    || value.includes('\\')
    || /^[A-Za-z]:/.test(value)) {
    throw new Error(`Invalid ${label}: ${String(value)}`);
  }
}

function samePath(left, right) {
  const normalize = (value) => {
    const normalized = path.normalize(value);
    return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
  };
  return normalize(left) === normalize(right);
}

async function realDirectory(directory, label) {
  const stat = await fsp.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`${label} is not a real directory: ${directory}`);
  }
  return fsp.realpath(directory);
}

async function directDirectory(parent, component, label) {
  validateComponent(component, label);
  const realParent = await realDirectory(parent, `${label} parent`);
  const candidate = path.join(realParent, component);
  const realChild = await realDirectory(candidate, label);
  if (!samePath(path.dirname(realChild), realParent)) {
    throw new Error(`${label} is not a canonical direct child: ${candidate}`);
  }
  return realChild;
}

async function validateCatalogSelection({ trustedRoot, department, employee }) {
  const root = await realDirectory(trustedRoot, 'trusted NAS root');
  const departmentRoot = await directDirectory(root, department, 'department');
  return directDirectory(departmentRoot, employee, 'employee');
}

async function writeDurableExclusiveJson(filePath, value) {
  const handle = await fsp.open(filePath, 'wx');
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function createOwnedAcceptanceRoot({ employeeRoot, runId }) {
  if (!UUID_PATTERN.test(String(runId))) throw new Error(`Invalid acceptance run ID: ${String(runId)}`);
  const devicesRoot = await directDirectory(employeeRoot, 'devices', 'devices directory');
  const directoryName = `p0-acceptance-${String(runId).toLowerCase()}`;
  const candidate = path.join(devicesRoot, directoryName);
  try {
    await fsp.mkdir(candidate, { recursive: false });
  } catch (error) {
    if (error.code === 'EEXIST') throw new Error(`Acceptance directory already exists: ${candidate}`);
    throw error;
  }

  try {
    const acceptanceRoot = await directDirectory(devicesRoot, directoryName, 'acceptance directory');
    await writeDurableExclusiveJson(path.join(acceptanceRoot, MARKER_FILENAME), {
      version: REPORT_VERSION,
      kind: MARKER_KIND,
      runId: String(runId).toLowerCase(),
      createdAt: new Date().toISOString(),
    });
    return acceptanceRoot;
  } catch (error) {
    await fsp.rm(candidate, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

async function cleanupOwnedAcceptanceRoot({ acceptanceRoot, runId }) {
  if (!UUID_PATTERN.test(String(runId))) throw new Error(`Invalid acceptance run ID: ${String(runId)}`);
  const expectedName = `p0-acceptance-${String(runId).toLowerCase()}`;
  if (path.basename(acceptanceRoot) !== expectedName || path.basename(path.dirname(acceptanceRoot)) !== 'devices') {
    throw new Error(`Acceptance cleanup refused: path is not an owned acceptance directory: ${acceptanceRoot}`);
  }
  const realRoot = await realDirectory(acceptanceRoot, 'acceptance cleanup root');
  const markerPath = path.join(realRoot, MARKER_FILENAME);
  let marker;
  try {
    marker = JSON.parse(await fsp.readFile(markerPath, 'utf8'));
  } catch (error) {
    throw new Error(`Acceptance cleanup refused: marker is unreadable: ${error.message}`);
  }
  if (marker?.version !== REPORT_VERSION
    || marker?.kind !== MARKER_KIND
    || marker?.runId !== String(runId).toLowerCase()) {
    throw new Error('Acceptance cleanup refused: marker does not match this run.');
  }
  await fsp.rm(realRoot, { recursive: true, force: false });
}

async function writeAll(handle, data) {
  let offset = 0;
  while (offset < data.length) {
    const { bytesWritten } = await handle.write(data, offset, data.length - offset, null);
    if (bytesWritten <= 0) throw new Error('Unable to write synthetic JSONL fixture.');
    offset += bytesWritten;
  }
}

async function writeSyntheticJsonl({ filePath, byteCount, seed }) {
  if (!Number.isSafeInteger(byteCount) || byteCount < 128) {
    throw new Error(`Synthetic JSONL byte count is invalid: ${byteCount}`);
  }
  if (!/^[A-Za-z0-9_-]+$/.test(String(seed))) throw new Error(`Synthetic seed is invalid: ${String(seed)}`);
  const maximumLineBytes = 256 * 1024;
  const lineCount = Math.ceil(byteCount / maximumLineBytes);
  const baseLineBytes = Math.floor(byteCount / lineCount);
  const extraBytes = byteCount % lineCount;
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  const handle = await fsp.open(filePath, 'wx');
  try {
    for (let index = 0; index < lineCount; index += 1) {
      const targetBytes = baseLineBytes + (index < extraBytes ? 1 : 0);
      const prefix = `{"kind":"p0-fixture","seed":"${seed}","sequence":${index},"data":"`;
      const suffix = '"}\n';
      const contentBytes = targetBytes - Buffer.byteLength(prefix) - Buffer.byteLength(suffix);
      if (contentBytes < 0) throw new Error('Synthetic JSONL target is too small for valid records.');
      await writeAll(handle, Buffer.from(`${prefix}${'x'.repeat(contentBytes)}${suffix}`, 'utf8'));
    }
    await handle.sync();
  } finally {
    await handle.close();
  }
  const stat = await fsp.stat(filePath);
  if (stat.size !== byteCount) throw new Error(`Synthetic JSONL size mismatch: ${stat.size} != ${byteCount}`);
  return Object.freeze({ byteCount, lineCount });
}

async function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(filePath)) hash.update(chunk);
  return hash.digest('hex');
}

function median(values) {
  if (!Array.isArray(values) || values.length === 0) throw new Error('Median requires at least one value.');
  const sorted = values.map(Number).sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

class ResourceSampler {
  constructor() {
    this.samples = [];
  }

  sample(stage) {
    const memory = process.memoryUsage();
    const cpu = process.cpuUsage();
    this.samples.push({
      timestamp: new Date().toISOString(),
      stage,
      rssBytes: memory.rss,
      heapUsedBytes: memory.heapUsed,
      cpuUserMicros: cpu.user,
      cpuSystemMicros: cpu.system,
      activeHandles: typeof process._getActiveHandles === 'function' ? process._getActiveHandles().length : null,
      processCount: 1,
    });
  }

  async measure(stage, operation) {
    this.sample(`${stage}:start`);
    const timer = setInterval(() => this.sample(stage), 250);
    timer.unref?.();
    try {
      return await operation();
    } finally {
      clearInterval(timer);
      this.sample(`${stage}:finish`);
    }
  }
}

function sessionSourcePath(codexRoot, sessionId) {
  return path.join(codexRoot, 'sessions', '2026', '07', '15', `rollout-2026-07-15T00-00-00-${sessionId}.jsonl`);
}

async function loadBackedUpSession(paths, sessionId) {
  const manifest = JSON.parse(await fsp.readFile(paths.manifestPath, 'utf8'));
  const record = manifest.sessions?.[sessionId];
  if (!record) throw new Error(`Acceptance manifest has no session ${sessionId}.`);
  const backupFilePath = path.join(paths.backupRoot, ...String(record.backupPath).split(/[\\/]+/));
  return { backupFilePath, record };
}

async function runSingleUpload({ acceptanceRoot, localRoot, index, byteCount, sampler }) {
  const sessionId = crypto.randomUUID();
  const runRoot = path.join(acceptanceRoot, `upload-${index}`);
  const backupRoot = path.join(runRoot, 'incremental-backups');
  const homeDir = path.join(localRoot, `upload-${index}`);
  const codexRoot = path.join(homeDir, '.codex');
  const stateRoot = path.join(homeDir, 'nas-state');
  const sourcePath = sessionSourcePath(codexRoot, sessionId);
  await fsp.mkdir(backupRoot, { recursive: true });
  await writeSyntheticJsonl({ filePath: sourcePath, byteCount, seed: `upload-${index}` });
  const paths = backupPaths({ homeDir, codexRoot, backupRoot, stateRoot, pathImpl: path });
  const agent = new BackupAgent({ paths, deviceId: crypto.randomUUID() });
  const started = performance.now();
  try {
    await sampler.measure(`upload-${index}`, () => agent.performOneShotScan());
  } finally {
    await agent.stopAndAwaitQuiescence(10000);
  }
  const durationSeconds = Math.max((performance.now() - started) / 1000, 0.000001);
  const { backupFilePath, record } = await loadBackedUpSession(paths, sessionId);
  const [sourceHash, backupHash, backupStat] = await Promise.all([
    sha256File(sourcePath),
    sha256File(backupFilePath),
    fsp.stat(backupFilePath),
  ]);
  const committedBytes = Number(record.bytesBackedUp || 0);
  const throughputMiBPerSecond = committedBytes / MIB / durationSeconds;
  const report = Object.freeze({
    run: index,
    committedBytes,
    durationSeconds,
    throughputMiBPerSecond,
    hashMatches: sourceHash === backupHash,
    byteCountMatches: backupStat.size === byteCount && committedBytes === byteCount,
  });
  return { internal: { paths, sourcePath }, report };
}

async function runLargeRestore({ acceptanceRoot, localRoot, byteCount, sampler }) {
  const sessionId = crypto.randomUUID();
  const runRoot = path.join(acceptanceRoot, 'large-restore');
  const backupRoot = path.join(runRoot, 'incremental-backups');
  const homeDir = path.join(localRoot, 'large-restore');
  const codexRoot = path.join(homeDir, '.codex');
  const stateRoot = path.join(homeDir, 'nas-state');
  const sourcePath = sessionSourcePath(codexRoot, sessionId);
  await fsp.mkdir(backupRoot, { recursive: true });
  await writeSyntheticJsonl({ filePath: sourcePath, byteCount, seed: 'large-restore' });
  const sourceHash = await sha256File(sourcePath);
  const paths = backupPaths({ homeDir, codexRoot, backupRoot, stateRoot, pathImpl: path });
  const agent = new BackupAgent({ paths, deviceId: crypto.randomUUID() });
  try {
    await sampler.measure('large-backup', () => agent.performOneShotScan());
  } finally {
    await agent.stopAndAwaitQuiescence(10000);
  }
  await fsp.rm(codexRoot, { recursive: true, force: true });
  const codexExistedBeforePreflight = await exists(codexRoot);
  const baselineRssBytes = process.memoryUsage().rss;
  const preflight = await sampler.measure('restore-preflight', () => preflightIncrementalRecovery({
    paths,
    sessionIds: [sessionId],
  }));
  const codexCreatedDuringPreflight = await exists(codexRoot);
  const restored = await sampler.measure('restore-publish', () => restoreIncrementalSessions({ paths, preflight }));
  const recoveredPath = restored.recoveredFiles[sessionId];
  const recoveredHash = await sha256File(recoveredPath);
  const recoveredStat = await fsp.stat(recoveredPath);
  const peakRssBytes = Math.max(baselineRssBytes, ...sampler.samples.map((sample) => sample.rssBytes));
  return Object.freeze({
    byteCount,
    hashMatches: sourceHash === recoveredHash,
    byteCountMatches: recoveredStat.size === byteCount,
    freshCodexRoot: !codexExistedBeforePreflight && !codexCreatedDuringPreflight,
    baselineRssBytes,
    peakRssBytes,
    peakIncreaseBytes: peakRssBytes - baselineRssBytes,
    belowWindowsProcessLimit: peakRssBytes <= 700 * MIB,
    belowWarmIncreaseLimit: peakRssBytes - baselineRssBytes <= 128 * MIB,
  });
}

async function runReconnectSimulation(uploadInternal, sampler) {
  const { paths, sourcePath } = uploadInternal;
  const offlinePath = `${paths.backupRoot}.offline`;
  let offlineFailureObserved = false;
  await fsp.rename(paths.backupRoot, offlinePath);
  try {
    const offlineAgent = new BackupAgent({ paths, deviceId: crypto.randomUUID() });
    try {
      await offlineAgent.performOneShotScan();
    } catch {
      offlineFailureObserved = true;
    } finally {
      await offlineAgent.stopAndAwaitQuiescence(10000);
    }
  } finally {
    await fsp.rename(offlinePath, paths.backupRoot);
  }

  await fsp.appendFile(sourcePath, '{"kind":"p0-fixture","seed":"reconnect","sequence":1,"data":"x"}\n');
  const reconnectAgent = new BackupAgent({ paths, deviceId: crypto.randomUUID() });
  try {
    await sampler.measure('reconnect-catchup', () => reconnectAgent.performOneShotScan());
  } finally {
    await reconnectAgent.stopAndAwaitQuiescence(10000);
  }
  const manifest = JSON.parse(await fsp.readFile(paths.manifestPath, 'utf8'));
  const record = Object.values(manifest.sessions || {})[0];
  const backupFilePath = path.join(paths.backupRoot, ...String(record.backupPath).split(/[\\/]+/));
  const [sourceHash, backupHash] = await Promise.all([sha256File(sourcePath), sha256File(backupFilePath)]);
  return Object.freeze({
    isolatedTargetSimulation: true,
    offlineFailureObserved,
    catchupHashMatches: sourceHash === backupHash,
  });
}

function defaultManualGates() {
  return {
    loginRestart: 'pending',
    silentBackgroundLaunch: 'pending',
    trayOrDockReopen: 'pending',
    explicitQuit: 'pending',
    wakeCatchup: 'pending',
    actualNasReconnect: 'pending',
    twentyFourHourSoak: 'pending',
  };
}

function csvCell(value) {
  const text = String(value ?? '');
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

async function writeReports({ outputRoot, report, samples }) {
  await fsp.mkdir(outputRoot, { recursive: true });
  await fsp.writeFile(
    path.join(outputRoot, 'p0-acceptance-report.json'),
    `${JSON.stringify(report, null, 2)}\n`,
    'utf8',
  );
  const columns = [
    'timestamp', 'stage', 'rssBytes', 'heapUsedBytes', 'cpuUserMicros',
    'cpuSystemMicros', 'activeHandles', 'processCount',
  ];
  const rows = [columns.join(',')];
  for (const sample of samples) rows.push(columns.map((column) => csvCell(sample[column])).join(','));
  await fsp.writeFile(path.join(outputRoot, 'resource-samples.csv'), `${rows.join('\n')}\n`, 'utf8');
  const uploadResult = report.upload?.pass ? '通过' : '失败';
  const restoreResult = report.restore?.pass ? '通过' : '失败';
  const reconnectResult = report.reconnect?.pass ? '通过' : '失败';
  const summary = [
    'Codex Session Keeper P0 验收摘要',
    '',
    `自动化结果：${report.automatedPass ? '通过' : '失败'}`,
    `三次首次上传：${uploadResult}`,
    `大文件流式恢复：${restoreResult}`,
    `隔离目标断开/重连：${reconnectResult}`,
    `正式发布就绪：${report.releaseReady ? '是' : '否'}`,
    '',
    report.releaseReady
      ? '全部自动化、24 小时资源和人工生命周期门槛均已记录为通过。'
      : '仍需在真实 macOS/Windows 电脑完成开机启动、后台常驻、退出、唤醒、真实 NAS 重连和 24 小时资源门槛。',
    '报告不记录会话正文。',
  ].join('\n');
  await fsp.writeFile(path.join(outputRoot, 'summary.txt'), `${summary}\n`, 'utf8');
}

async function runAcceptance({
  trustedRoot,
  department,
  employee,
  outputRoot,
  runId = crypto.randomUUID(),
  uploadBytes = DEFAULT_UPLOAD_BYTES,
  restoreBytes = DEFAULT_RESTORE_BYTES,
  uploadRuns = 3,
  minimumThroughputMiBPerSecond = DEFAULT_MINIMUM_THROUGHPUT,
  manualGates = defaultManualGates(),
  cleanup = false,
} = {}) {
  const startedAt = new Date();
  const employeeRoot = await validateCatalogSelection({ trustedRoot, department, employee });
  const acceptanceRoot = await createOwnedAcceptanceRoot({ employeeRoot, runId });
  const localRoot = await fsp.mkdtemp(path.join(os.tmpdir(), `codex-p0-${runId}-`));
  const sampler = new ResourceSampler();
  sampler.sample('acceptance:start');
  let upload;
  let restore;
  let reconnect;
  let automatedError = null;
  try {
    const uploads = [];
    const internals = [];
    for (let index = 1; index <= uploadRuns; index += 1) {
      const result = await runSingleUpload({
        acceptanceRoot,
        localRoot,
        index,
        byteCount: uploadBytes,
        sampler,
      });
      uploads.push(result.report);
      internals.push(result.internal);
    }
    const medianThroughputMiBPerSecond = median(uploads.map((run) => run.throughputMiBPerSecond));
    upload = {
      targetBytesPerRun: uploadBytes,
      minimumThroughputMiBPerSecond,
      medianThroughputMiBPerSecond,
      runs: uploads,
      pass: uploads.every((run) => run.hashMatches && run.byteCountMatches)
        && medianThroughputMiBPerSecond >= minimumThroughputMiBPerSecond,
    };
    const restoreResult = await runLargeRestore({
      acceptanceRoot,
      localRoot,
      byteCount: restoreBytes,
      sampler,
    });
    restore = {
      ...restoreResult,
      pass: restoreResult.hashMatches
        && restoreResult.byteCountMatches
        && restoreResult.freshCodexRoot
        && restoreResult.belowWindowsProcessLimit
        && restoreResult.belowWarmIncreaseLimit,
    };
    const reconnectResult = await runReconnectSimulation(internals[0], sampler);
    reconnect = {
      ...reconnectResult,
      pass: reconnectResult.offlineFailureObserved && reconnectResult.catchupHashMatches,
    };
  } catch (error) {
    automatedError = error.message || String(error);
  } finally {
    sampler.sample('acceptance:finish');
    await fsp.rm(localRoot, { recursive: true, force: true }).catch(() => {});
  }

  const gates = { ...defaultManualGates(), ...manualGates };
  const automatedPass = !automatedError && Boolean(upload?.pass && restore?.pass && reconnect?.pass);
  const allManualGatesPass = Object.values(gates).every((value) => value === 'pass');
  const report = {
    version: REPORT_VERSION,
    kind: MARKER_KIND,
    appVersion: JSON.parse(await fsp.readFile(path.join(electronRoot, 'package.json'), 'utf8')).version,
    platform: process.platform,
    startedAt: startedAt.toISOString(),
    completedAt: new Date().toISOString(),
    target: {
      department,
      employee,
      deviceDirectoryName: path.basename(acceptanceRoot),
    },
    upload: upload || { pass: false },
    restore: restore || { pass: false },
    reconnect: reconnect || { pass: false },
    manualGates: gates,
    automatedError,
    automatedPass,
    releaseReady: automatedPass && allManualGatesPass,
    contentLogged: false,
  };
  await writeReports({ outputRoot, report, samples: sampler.samples });
  if (cleanup) await cleanupOwnedAcceptanceRoot({ acceptanceRoot, runId });
  return Object.freeze({ acceptanceRoot, report: Object.freeze(report) });
}

async function exists(filePath) {
  try {
    await fsp.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function parseArguments(argumentsList) {
  const values = {};
  for (let index = 0; index < argumentsList.length; index += 1) {
    const key = argumentsList[index];
    if (!key.startsWith('--')) throw new Error(`Unknown argument: ${key}`);
    if (key === '--cleanup') {
      values.cleanup = true;
      continue;
    }
    const value = argumentsList[index + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`Missing value for ${key}`);
    index += 1;
    values[key.slice(2)] = value;
  }
  for (const required of ['trusted-root', 'department', 'employee', 'output']) {
    if (!values[required]) throw new Error(`Missing required argument: --${required}`);
  }
  return {
    trustedRoot: values['trusted-root'],
    department: values.department,
    employee: values.employee,
    outputRoot: values.output,
    runId: values['run-id'] || crypto.randomUUID(),
    uploadBytes: values['upload-bytes'] ? Number(values['upload-bytes']) : DEFAULT_UPLOAD_BYTES,
    restoreBytes: values['restore-bytes'] ? Number(values['restore-bytes']) : DEFAULT_RESTORE_BYTES,
    minimumThroughputMiBPerSecond: values['minimum-throughput']
      ? Number(values['minimum-throughput'])
      : DEFAULT_MINIMUM_THROUGHPUT,
    cleanup: Boolean(values.cleanup),
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const result = await runAcceptance(options);
  process.stdout.write(`${path.join(options.outputRoot, 'summary.txt')}\n`);
  if (!result.report.automatedPass) process.exitCode = 1;
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${error.stack || error.message || String(error)}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  cleanupOwnedAcceptanceRoot,
  createOwnedAcceptanceRoot,
  median,
  runAcceptance,
  sha256File,
  validateCatalogSelection,
  writeSyntheticJsonl,
};

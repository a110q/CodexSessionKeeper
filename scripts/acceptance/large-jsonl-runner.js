#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const REPOSITORY_ROOT = path.resolve(__dirname, '..', '..');
const ELECTRON_ROOT = path.join(REPOSITORY_ROOT, 'windows', 'codex_session_manager_electron');
const LINE_BYTES = 35_895_162;
const LEGACY_LIMIT_BYTES = 32 * 1024 * 1024;
const HARD_ABORT_BYTES = 1024 * 1024 * 1024;
const MAC_LIMIT_BYTES = 600 * 1024 * 1024;
const WINDOWS_LIMIT_BYTES = 650 * 1024 * 1024;
const RESULT_MARKER = 'LARGE_JSONL_ACCEPTANCE_RESULT=';
const SESSION_ID = '019f5e8c-20de-71b2-bcef-ab79b0f36351';
const VERIFIED_PREFIX_BYTES = 188_399_559;
const EXPECTED_REAL_BYTES = 319_942_731;
const NEXT_RECORD_OFFSET = 224_294_722;

function compactedLineLayout(lineBytes) {
  const prefix = Buffer.from('{"timestamp":"2026-07-18T00:00:00Z","type":"compacted","payload":{"message":"');
  const suffix = Buffer.from('"}}');
  const fillBytes = lineBytes - prefix.length - suffix.length;
  if (!Number.isSafeInteger(lineBytes) || fillBytes < 1) throw new Error(`Invalid compacted line size: ${lineBytes}`);
  return Object.freeze({ lineBytes, prefix, fillBytes, suffix });
}

function descendantProcessIds(rows, rootPid) {
  const selected = new Set([Number(rootPid)]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of rows) {
      if (!selected.has(row.pid) && selected.has(row.ppid)) {
        selected.add(row.pid);
        changed = true;
      }
    }
  }
  return selected;
}

function summarizeProcessMemory(rows, rootPid) {
  const ids = descendantProcessIds(rows, rootPid);
  const guarded = rows.filter((row) => ids.has(row.pid));
  return {
    aggregateRssBytes: guarded.reduce((total, row) => total + row.rssBytes, 0),
    processCount: guarded.length,
  };
}

async function writeAll(handle, buffer) {
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesWritten } = await handle.write(buffer, offset, buffer.length - offset, null);
    if (bytesWritten < 1) throw new Error('Short write while generating large JSONL fixture.');
    offset += bytesWritten;
  }
}

async function writeSyntheticFixture(filePath) {
  const layout = compactedLineLayout(LINE_BYTES);
  const following = Buffer.from('{"timestamp":"2026-07-18T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"following-record-retained"}]}}\n');
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  const handle = await fsp.open(filePath, 'wx');
  try {
    await writeAll(handle, layout.prefix);
    const fill = Buffer.alloc(1024 * 1024, 0x78);
    let remaining = layout.fillBytes;
    while (remaining > 0) {
      const count = Math.min(remaining, fill.length);
      await writeAll(handle, count === fill.length ? fill : fill.subarray(0, count));
      remaining -= count;
    }
    await writeAll(handle, layout.suffix);
    await writeAll(handle, Buffer.from('\n'));
    await writeAll(handle, following);
    await handle.sync();
  } finally {
    await handle.close();
  }
  return Object.freeze({ following, totalBytes: LINE_BYTES + 1 + following.length });
}

async function hashAndChunks(filePath, chunkSize = 4 * 1024 * 1024) {
  const full = crypto.createHash('sha256');
  const chunkHashes = [];
  let byteCount = 0;
  let lineCount = 0;
  for await (const chunk of fs.createReadStream(filePath, { highWaterMark: chunkSize })) {
    byteCount += chunk.length;
    full.update(chunk);
    chunkHashes.push(crypto.createHash('sha256').update(chunk).digest('hex'));
    for (const byte of chunk) if (byte === 0x0A) lineCount += 1;
  }
  return Object.freeze({ byteCount, lineCount, contentHash: full.digest('hex'), chunkHashes });
}

async function filesEqual(leftPath, rightPath) {
  const left = await fsp.open(leftPath, 'r');
  const right = await fsp.open(rightPath, 'r');
  const leftBuffer = Buffer.alloc(4 * 1024 * 1024);
  const rightBuffer = Buffer.alloc(4 * 1024 * 1024);
  try {
    let position = 0;
    while (true) {
      const [lhs, rhs] = await Promise.all([
        left.read(leftBuffer, 0, leftBuffer.length, position),
        right.read(rightBuffer, 0, rightBuffer.length, position),
      ]);
      if (lhs.bytesRead !== rhs.bytesRead) return false;
      if (!leftBuffer.subarray(0, lhs.bytesRead).equals(rightBuffer.subarray(0, rhs.bytesRead))) return false;
      if (lhs.bytesRead === 0) return true;
      position += lhs.bytesRead;
    }
  } finally {
    await Promise.all([left.close(), right.close()]);
  }
}

async function tail(filePath, byteCount) {
  const handle = await fsp.open(filePath, 'r');
  try {
    const stat = await handle.stat();
    const buffer = Buffer.alloc(byteCount);
    const { bytesRead } = await handle.read(buffer, 0, byteCount, stat.size - byteCount);
    return buffer.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

async function copyRange(sourcePath, destinationPath, offset, byteCount, append) {
  const source = await fsp.open(sourcePath, 'r');
  const destination = await fsp.open(destinationPath, append ? 'a' : 'r+');
  const buffer = Buffer.alloc(4 * 1024 * 1024);
  try {
    let position = offset;
    let remaining = byteCount;
    while (remaining > 0) {
      const count = Math.min(buffer.length, remaining);
      const { bytesRead } = await source.read(buffer, 0, count, position);
      if (bytesRead < 1) throw new Error('Known source ended during isolated copy.');
      await writeAll(destination, buffer.subarray(0, bytesRead));
      position += bytesRead;
      remaining -= bytesRead;
    }
    await destination.sync();
  } finally {
    await Promise.all([source.close(), destination.close()]);
  }
}

async function byteAt(filePath, offset) {
  const handle = await fsp.open(filePath, 'r');
  try {
    const buffer = Buffer.alloc(1);
    const { bytesRead } = await handle.read(buffer, 0, 1, offset);
    if (bytesRead !== 1) throw new Error(`Missing known source byte at ${offset}.`);
    return buffer[0];
  } finally {
    await handle.close();
  }
}

async function readLineAt(filePath, offset, maximumBytes = 1024 * 1024) {
  const handle = await fsp.open(filePath, 'r');
  const chunks = [];
  let total = 0;
  try {
    while (total <= maximumBytes) {
      const buffer = Buffer.alloc(Math.min(64 * 1024, maximumBytes - total + 1));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, offset + total);
      if (bytesRead < 1) throw new Error(`Line at ${offset} is incomplete.`);
      const chunk = buffer.subarray(0, bytesRead);
      const newline = chunk.indexOf(0x0A);
      if (newline >= 0) {
        chunks.push(chunk.subarray(0, newline));
        return Buffer.concat(chunks);
      }
      chunks.push(chunk);
      total += chunk.length;
    }
    throw new Error(`Line at ${offset} exceeds ${maximumBytes} bytes.`);
  } finally {
    await handle.close();
  }
}

async function runElectronSynthetic() {
  const { BackupAgent } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'backup-agent'));
  const { CursorStore } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'cursor-store'));
  const { backupPaths } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'paths'));
  const { loadVerification } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'verification-store'));
  const { preflightIncrementalRecovery, restoreIncrementalSessions } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'incremental-recovery'));

  const root = process.env.CODEX_LARGE_JSONL_ROOT
    ? path.resolve(process.env.CODEX_LARGE_JSONL_ROOT)
    : await fsp.mkdtemp(path.join(os.tmpdir(), 'large-jsonl-electron-'));
  const codexRoot = path.join(root, '.codex');
  const sourcePath = path.join(codexRoot, 'sessions', '2026', '07', '18', `rollout-2026-07-18T00-00-00-${SESSION_ID}.jsonl`);
  const backupRoot = path.join(root, 'backup');
  const stateRoot = path.join(root, 'state');
  const recoveryRoot = path.join(root, 'recovered-codex');
  const paths = backupPaths({ homeDir: root, codexRoot, backupRoot, stateRoot, pathImpl: path });
  const keep = process.env.CODEX_LARGE_JSONL_KEEP_ROOT === '1';
  try {
    await fsp.mkdir(backupRoot, { recursive: true });
    const fixture = await writeSyntheticFixture(sourcePath);
    await new BackupAgent({ paths, maxLineBytes: LEGACY_LIMIT_BYTES }).performOneShotScan();

    const cursorStore = new CursorStore({ paths });
    await cursorStore.open();
    let cursor = cursorStore.all().get(sourcePath);
    await cursorStore.close();
    assert.equal(cursor.lastByteOffset, 0);
    assert.equal(cursor.blockedLineLimitBytes, LEGACY_LIMIT_BYTES);
    assert.match(cursor.lastError, /at offset 0/);

    await new BackupAgent({ paths }).performOneShotScan();
    const manifest = JSON.parse(await fsp.readFile(paths.manifestPath, 'utf8'));
    const record = manifest.sessions[SESSION_ID];
    assert.ok(record, 'repaired manifest record missing');
    const backupPath = path.join(backupRoot, ...String(record.backupPath).split(/[\\/]+/));
    const [sourceVerified, backupVerified, verification] = await Promise.all([
      hashAndChunks(sourcePath),
      hashAndChunks(backupPath),
      loadVerification(paths.verificationPath),
    ]);
    const sidecar = verification.sessions[SESSION_ID];
    assert.deepEqual(backupVerified, sourceVerified);
    assert.equal(await filesEqual(sourcePath, backupPath), true);
    assert.deepEqual(await tail(backupPath, fixture.following.length), fixture.following);
    assert.equal(sourceVerified.byteCount, fixture.totalBytes);
    assert.equal(sourceVerified.lineCount, 2);
    assert.equal(record.bytesBackedUp, sourceVerified.byteCount);
    assert.equal(record.lineCount, 2);
    assert.equal(sidecar.backupPath, record.backupPath);
    assert.equal(sidecar.byteCount, sourceVerified.byteCount);
    assert.equal(sidecar.lineCount, 2);
    assert.deepEqual(sidecar.chunkHashes, sourceVerified.chunkHashes);

    await cursorStore.open();
    cursor = cursorStore.all().get(sourcePath);
    await cursorStore.close();
    assert.equal(cursor.lastByteOffset, sourceVerified.byteCount);
    assert.equal(cursor.blockedLineLimitBytes, null);
    assert.equal(cursor.lastError, null);

    await fsp.mkdir(recoveryRoot, { recursive: true });
    const recoveryPaths = { ...paths, codexRoot: recoveryRoot };
    const preflight = await preflightIncrementalRecovery({ paths: recoveryPaths, sessionIds: [SESSION_ID] });
    const restored = await restoreIncrementalSessions({ paths: recoveryPaths, preflight });
    const recoveredPath = restored.recoveredFiles[SESSION_ID];
    const recoveredVerified = await hashAndChunks(recoveredPath);
    assert.deepEqual(recoveredVerified, sourceVerified);
    assert.equal(await filesEqual(sourcePath, recoveredPath), true);
    assert.deepEqual(await tail(recoveredPath, fixture.following.length), fixture.following);

    return {
      platform: 'electron',
      mode: 'synthetic',
      root,
      lineBytes: LINE_BYTES,
      byteCount: sourceVerified.byteCount,
      lineCount: sourceVerified.lineCount,
      sha256: sourceVerified.contentHash,
      chunkCount: sourceVerified.chunkHashes.length,
      blockedLimitBytes: LEGACY_LIMIT_BYTES,
      repairedCursorOffset: cursor.lastByteOffset,
    };
  } finally {
    if (!keep) await fsp.rm(root, { recursive: true, force: true });
  }
}

async function runElectronReal() {
  const sourcePath = process.env.CODEX_REAL_LARGE_JSONL_SOURCE;
  if (!sourcePath) throw new Error('CODEX_REAL_LARGE_JSONL_SOURCE is required for real-source acceptance.');
  const { BackupAgent } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'backup-agent'));
  const { CursorStore } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'cursor-store'));
  const { backupPaths } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'paths'));
  const { loadVerification } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'verification-store'));
  const { preflightIncrementalRecovery, restoreIncrementalSessions } = require(path.join(ELECTRON_ROOT, 'src', 'backup', 'incremental-recovery'));

  const before = await fsp.stat(sourcePath);
  assert.equal(before.size, EXPECTED_REAL_BYTES);
  assert.equal(await byteAt(sourcePath, VERIFIED_PREFIX_BYTES - 1), 0x0A);
  assert.equal(await byteAt(sourcePath, NEXT_RECORD_OFFSET - 1), 0x0A);
  assert.equal(NEXT_RECORD_OFFSET - VERIFIED_PREFIX_BYTES - 1, LINE_BYTES);
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'large-jsonl-real-electron-'));
  const codexRoot = path.join(root, '.codex');
  const isolatedSource = path.join(codexRoot, 'sessions', '2026', '07', '14', path.basename(sourcePath));
  const backupRoot = path.join(root, 'backup');
  const stateRoot = path.join(root, 'state');
  const recoveryRoot = path.join(root, 'recovered-codex');
  const paths = backupPaths({ homeDir: root, codexRoot, backupRoot, stateRoot, pathImpl: path });
  const keep = process.env.CODEX_LARGE_JSONL_KEEP_ROOT === '1';
  try {
    await fsp.mkdir(path.dirname(isolatedSource), { recursive: true });
    await fsp.mkdir(backupRoot, { recursive: true });
    await fsp.writeFile(isolatedSource, Buffer.alloc(0), { flag: 'wx' });
    await copyRange(sourcePath, isolatedSource, 0, VERIFIED_PREFIX_BYTES, false);
    await new BackupAgent({ paths }).performOneShotScan();
    const cursorStore = new CursorStore({ paths });
    await cursorStore.open();
    let cursor = cursorStore.all().get(isolatedSource);
    await cursorStore.close();
    assert.equal(cursor.lastByteOffset, VERIFIED_PREFIX_BYTES);
    let verification = await loadVerification(paths.verificationPath);
    assert.equal(verification.sessions[SESSION_ID].byteCount, VERIFIED_PREFIX_BYTES);

    await copyRange(
      sourcePath,
      isolatedSource,
      VERIFIED_PREFIX_BYTES,
      EXPECTED_REAL_BYTES - VERIFIED_PREFIX_BYTES,
      true,
    );
    await new BackupAgent({ paths, maxLineBytes: LEGACY_LIMIT_BYTES }).performOneShotScan();
    await cursorStore.open();
    cursor = cursorStore.all().get(isolatedSource);
    await cursorStore.close();
    assert.equal(cursor.lastByteOffset, VERIFIED_PREFIX_BYTES);
    assert.equal(cursor.blockedLineLimitBytes, LEGACY_LIMIT_BYTES);
    assert.match(cursor.lastError, new RegExp(`at offset ${VERIFIED_PREFIX_BYTES}`));

    await new BackupAgent({ paths }).performOneShotScan();
    await cursorStore.open();
    cursor = cursorStore.all().get(isolatedSource);
    await cursorStore.close();
    assert.equal(cursor.lastByteOffset, EXPECTED_REAL_BYTES);
    assert.equal(cursor.blockedLineLimitBytes, null);
    assert.equal(cursor.lastError, null);

    const manifest = JSON.parse(await fsp.readFile(paths.manifestPath, 'utf8'));
    const record = manifest.sessions[SESSION_ID];
    assert.ok(record, 'real-source repaired manifest missing');
    const backupPath = path.join(backupRoot, ...String(record.backupPath).split(/[\\/]+/));
    const [sourceVerified, backupVerified] = await Promise.all([
      hashAndChunks(sourcePath),
      hashAndChunks(backupPath),
    ]);
    assert.deepEqual(backupVerified, sourceVerified);
    assert.equal(await filesEqual(sourcePath, isolatedSource), true);
    assert.equal(await filesEqual(sourcePath, backupPath), true);
    verification = await loadVerification(paths.verificationPath);
    const sidecar = verification.sessions[SESSION_ID];
    assert.equal(record.bytesBackedUp, sourceVerified.byteCount);
    assert.equal(record.lineCount, sourceVerified.lineCount);
    assert.equal(sidecar.byteCount, sourceVerified.byteCount);
    assert.equal(sidecar.lineCount, sourceVerified.lineCount);
    assert.deepEqual(sidecar.chunkHashes, sourceVerified.chunkHashes);
    const sourceFollowing = await readLineAt(sourcePath, NEXT_RECORD_OFFSET);
    const backupFollowing = await readLineAt(backupPath, NEXT_RECORD_OFFSET);
    assert.deepEqual(backupFollowing, sourceFollowing);
    JSON.parse(sourceFollowing.toString('utf8'));

    await fsp.mkdir(recoveryRoot, { recursive: true });
    const recoveryPaths = { ...paths, codexRoot: recoveryRoot };
    const preflight = await preflightIncrementalRecovery({ paths: recoveryPaths, sessionIds: [SESSION_ID] });
    const restored = await restoreIncrementalSessions({ paths: recoveryPaths, preflight });
    const recoveredPath = restored.recoveredFiles[SESSION_ID];
    const recoveredVerified = await hashAndChunks(recoveredPath);
    assert.deepEqual(recoveredVerified, sourceVerified);
    assert.equal(await filesEqual(sourcePath, recoveredPath), true);
    assert.deepEqual(await readLineAt(recoveredPath, NEXT_RECORD_OFFSET), sourceFollowing);

    const after = await fsp.stat(sourcePath);
    assert.equal(after.size, before.size);
    assert.equal(after.ino, before.ino);
    assert.equal(after.mtimeMs, before.mtimeMs);
    return {
      platform: 'electron',
      mode: 'real-source',
      root,
      sourcePath,
      sourceBytes: sourceVerified.byteCount,
      verifiedPrefixBytes: VERIFIED_PREFIX_BYTES,
      largeLineBytes: LINE_BYTES,
      nextRecordOffset: NEXT_RECORD_OFFSET,
      lineCount: sourceVerified.lineCount,
      sha256: sourceVerified.contentHash,
      chunkCount: sourceVerified.chunkHashes.length,
      blockedLimitBytes: LEGACY_LIMIT_BYTES,
      repairedCursorOffset: cursor.lastByteOffset,
      sourceMetadataUnchanged: true,
    };
  } finally {
    if (!keep) await fsp.rm(root, { recursive: true, force: true });
  }
}

function unixProcessRows() {
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,rss='], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`ps failed: ${result.stderr}`);
  return result.stdout.trim().split(/\n+/).map((line) => {
    const [pid, ppid, rssKiB] = line.trim().split(/\s+/).map(Number);
    return { pid, ppid, rssBytes: rssKiB * 1024 };
  }).filter((row) => Number.isInteger(row.pid));
}

function windowsProcessRows() {
  const command = 'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,WorkingSetSize | ConvertTo-Json -Compress';
  const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`PowerShell process sampling failed: ${result.stderr}`);
  const parsed = JSON.parse(result.stdout || '[]');
  return (Array.isArray(parsed) ? parsed : [parsed]).map((row) => ({
    pid: Number(row.ProcessId),
    ppid: Number(row.ParentProcessId),
    rssBytes: Number(row.WorkingSetSize),
  }));
}

async function macFootprint(pids) {
  if (!pids.length) return null;
  const directory = await fsp.mkdtemp(path.join(os.tmpdir(), 'large-jsonl-footprint-'));
  const outputPath = path.join(directory, 'sample.json');
  try {
    const args = pids.flatMap((pid) => ['-p', String(pid)]).concat(['-j', outputPath]);
    const result = spawnSync('/usr/bin/footprint', args, { encoding: 'utf8', timeout: 10_000 });
    if (result.status !== 0) return null;
    const report = JSON.parse(await fsp.readFile(outputPath, 'utf8'));
    return {
      physFootprintBytes: Number(report['total footprint'] || 0),
      swappedBytes: Number(report.summary?.total?.swapped || 0),
    };
  } finally {
    await fsp.rm(directory, { recursive: true, force: true });
  }
}

function killTree(child) {
  if (process.platform === 'win32') {
    spawnSync('taskkill.exe', ['/pid', String(child.pid), '/t', '/f']);
  } else {
    try { process.kill(-child.pid, 'SIGKILL'); } catch {}
  }
}

function swapGrowthBytes(baselineSwappedBytes, peakSwappedBytes) {
  return Math.max(0, peakSwappedBytes - baselineSwappedBytes);
}

async function runGuarded(command, args, options = {}) {
  const stageDirectory = await fsp.mkdtemp(path.join(os.tmpdir(), 'large-jsonl-stage-'));
  const stagePath = path.join(stageDirectory, 'stage.log');
  const baselineAckPath = path.join(stageDirectory, 'baseline-captured');
  const child = spawn(command, args, {
    cwd: options.cwd || REPOSITORY_ROOT,
    env: {
      ...process.env,
      ...options.env,
      CODEX_LARGE_JSONL_STAGE_FILE: stagePath,
      CODEX_LARGE_JSONL_BASELINE_ACK_FILE: baselineAckPath,
    },
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  let currentStage = 'startup';
  function observeStages(chunk) {
    for (const match of String(chunk).matchAll(/LARGE_JSONL_ACCEPTANCE_STAGE=([^\r\n]+)/g)) {
      currentStage = match[1];
    }
  }
  child.stdout.on('data', (chunk) => { stdout += chunk; observeStages(chunk); process.stdout.write(chunk); });
  child.stderr.on('data', (chunk) => { stderr += chunk; observeStages(chunk); process.stderr.write(chunk); });
  let peakRssBytes = 0;
  let peakProcessCount = 0;
  let peakPhysFootprintBytes = 0;
  let peakSwappedBytes = 0;
  let baselineSwappedBytes = null;
  let footprintSamples = 0;
  const stageMemory = {};
  let sampling = false;
  let aborted = null;
  const sample = async () => {
    if (sampling || child.exitCode != null) return;
    sampling = true;
    try {
      try {
        observeStages(await fsp.readFile(stagePath, 'utf8'));
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      const sampledStage = currentStage;
      const rows = process.platform === 'win32' ? windowsProcessRows() : unixProcessRows();
      const summary = summarizeProcessMemory(rows, child.pid);
      peakRssBytes = Math.max(peakRssBytes, summary.aggregateRssBytes);
      peakProcessCount = Math.max(peakProcessCount, summary.processCount);
      stageMemory[sampledStage] ||= {
        peakRssBytes: 0,
        peakPhysFootprintBytes: 0,
        peakSwappedBytes: 0,
        samples: 0,
      };
      stageMemory[sampledStage].peakRssBytes = Math.max(
        stageMemory[sampledStage].peakRssBytes,
        summary.aggregateRssBytes,
      );
      if (summary.aggregateRssBytes >= HARD_ABORT_BYTES) aborted = `aggregate RSS reached ${summary.aggregateRssBytes}`;
      if (process.platform === 'darwin') {
        const footprint = await macFootprint([...descendantProcessIds(rows, child.pid)]);
        if (footprint) {
          footprintSamples += 1;
          peakPhysFootprintBytes = Math.max(peakPhysFootprintBytes, footprint.physFootprintBytes);
          if (sampledStage === 'startup-ready' && baselineSwappedBytes == null) {
            baselineSwappedBytes = footprint.swappedBytes;
            peakSwappedBytes = footprint.swappedBytes;
            await fsp.writeFile(baselineAckPath, String(baselineSwappedBytes), { flag: 'wx' });
          }
          if (baselineSwappedBytes != null) {
            peakSwappedBytes = Math.max(peakSwappedBytes, footprint.swappedBytes);
          }
          stageMemory[sampledStage].samples += 1;
          stageMemory[sampledStage].peakPhysFootprintBytes = Math.max(
            stageMemory[sampledStage].peakPhysFootprintBytes,
            footprint.physFootprintBytes,
          );
          stageMemory[sampledStage].peakSwappedBytes = Math.max(
            stageMemory[sampledStage].peakSwappedBytes,
            footprint.swappedBytes,
          );
          if (footprint.physFootprintBytes >= HARD_ABORT_BYTES) aborted = `phys_footprint reached ${footprint.physFootprintBytes}`;
        }
      } else if (sampledStage === 'startup-ready' && baselineSwappedBytes == null) {
        baselineSwappedBytes = 0;
        await fsp.writeFile(baselineAckPath, '0', { flag: 'wx' });
      }
      if (aborted) killTree(child);
    } finally {
      sampling = false;
    }
  };
  await sample();
  const timer = setInterval(() => { void sample(); }, 500);
  const exit = await new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
  clearInterval(timer);
  while (sampling) await new Promise((resolve) => setTimeout(resolve, 20));
  await fsp.rm(stageDirectory, { recursive: true, force: true });
  if (aborted) throw new Error(`1 GiB resource guard aborted child: ${aborted}`);
  if (exit.code !== 0) throw new Error(`guarded command failed (${exit.code ?? exit.signal}): ${stderr.slice(-2000)}`);
  const swapGrowth = baselineSwappedBytes == null
    ? null
    : swapGrowthBytes(baselineSwappedBytes, peakSwappedBytes);
  const memory = {
    peakRssBytes,
    peakProcessCount,
    peakPhysFootprintBytes,
    baselineSwappedBytes,
    peakSwappedBytes,
    swapGrowthBytes: swapGrowth,
    footprintSamples,
    stages: stageMemory,
  };
  if (process.platform === 'darwin') {
    assert.ok(footprintSamples > 0, 'no macOS phys_footprint samples were captured');
    assert.notEqual(baselineSwappedBytes, null, 'no startup-ready swap baseline was captured');
    assert.ok(
      peakPhysFootprintBytes < MAC_LIMIT_BYTES,
      `phys_footprint exceeded 600 MiB: ${JSON.stringify(memory)}`,
    );
    assert.equal(swapGrowth, 0, `guarded process tree swap grew after startup-ready: ${JSON.stringify(memory)}`);
  } else if (process.platform === 'win32') {
    assert.ok(peakRssBytes < WINDOWS_LIMIT_BYTES, `working set ${peakRssBytes} exceeded 650 MiB`);
  }
  const markerLine = stdout.split(/\r?\n/).find((line) => line.startsWith(RESULT_MARKER));
  assert.ok(markerLine, 'guarded worker did not emit an acceptance result');
  return {
    worker: JSON.parse(markerLine.slice(RESULT_MARKER.length)),
    memory,
  };
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--worker-electron')) {
    const report = args.includes('--real-source')
      ? await runElectronReal()
      : await runElectronSynthetic();
    process.stdout.write(`${RESULT_MARKER}${JSON.stringify(report)}\n`);
    return;
  }
  const platformIndex = args.indexOf('--platform');
  const platform = platformIndex >= 0 ? args[platformIndex + 1] : 'electron';
  const modeIndex = args.indexOf('--mode');
  const mode = modeIndex >= 0 ? args[modeIndex + 1] : 'synthetic';
  let report;
  if (platform === 'electron') {
    report = await runGuarded(process.execPath, [
      __filename,
      '--worker-electron',
      ...(mode === 'real-source' ? ['--real-source'] : []),
    ]);
  } else if (platform === 'swift') {
    const isReal = mode === 'real-source';
    const isLifecycle = mode === 'bounded-lifecycle';
    const filter = isReal
      ? 'knownSourceVerifiedPrefixResumesWithoutMutation'
      : isLifecycle
        ? 'boundedNinetySixMiBLifecycleStaysFileSizeIndependent'
        : 'legitimateLargeCompactedLineRepairsAndRecoversByteForByte';
    report = await runGuarded('swift', [
      'test', '-c', 'release', '--skip-build', '--disable-xctest', '--enable-swift-testing',
      '--filter', filter,
    ], {
      env: isReal ? {
        CODEX_RUN_REAL_LARGE_JSONL_ACCEPTANCE: '1',
        CODEX_REAL_LARGE_JSONL_SOURCE: process.env.CODEX_REAL_LARGE_JSONL_SOURCE,
      } : isLifecycle
        ? {
          CODEX_RUN_LARGE_JSONL_LIFECYCLE: '1',
          CODEX_LIFECYCLE_TOTAL_MIB: process.env.CODEX_LIFECYCLE_TOTAL_MIB,
        }
        : { CODEX_RUN_LARGE_JSONL_ACCEPTANCE: '1' },
    });
  } else {
    throw new Error(`Unsupported platform: ${platform}`);
  }
  process.stdout.write(`${JSON.stringify({ ...report, observedPlatform: process.platform }, null, 2)}\n`);
}

module.exports = { compactedLineLayout, descendantProcessIds, summarizeProcessMemory, swapGrowthBytes };

if (require.main === module) {
  main().catch((error) => {
    console.error(error.stack || error.message || String(error));
    process.exitCode = 1;
  });
}

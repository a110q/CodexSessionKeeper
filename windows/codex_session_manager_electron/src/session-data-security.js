'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { TextDecoder } = require('node:util');

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_JSONL_LINE_BYTES = 32 * 1024 * 1024;
const IDENTITY_KEY_BY_KIND = Object.freeze({
  history: 'session_id',
  historyBackup: 'session_id',
  sessionIndex: 'id',
});

function securityError(code, message, details = {}) {
  const error = new Error(message);
  error.code = code;
  Object.assign(error, details);
  return error;
}

function normalizeSessionId(value) {
  if (typeof value !== 'string' || value.trim().length === 0 || value.includes('\0')) return null;
  return UUID_PATTERN.test(value) ? value.toLowerCase() : value;
}

function invalidJsonl(filePath, lineNumber, reason) {
  return securityError(
    'INVALID_SESSION_JSONL',
    `${filePath} 第 ${lineNumber} 行无效：${reason}`,
    { filePath, lineNumber },
  );
}

function fileFingerprint(filePath, stat, digest) {
  return Object.freeze({
    filePath,
    dev: String(stat.dev),
    ino: String(stat.ino),
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    digest,
  });
}

function scanJsonlFile(filePath, { collectRecords = false, onFirstRecord = null } = {}) {
  const pathStat = fs.lstatSync(filePath);
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    throw invalidJsonl(filePath, 1, '不是普通文件');
  }

  const handle = fs.openSync(filePath, 'r');
  const startStat = fs.fstatSync(handle);
  if (!startStat.isFile()
      || String(startStat.dev) !== String(pathStat.dev)
      || String(startStat.ino) !== String(pathStat.ino)) {
    fs.closeSync(handle);
    throw invalidJsonl(filePath, 1, '文件在打开时发生变化');
  }
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const hash = crypto.createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let pending = Buffer.alloc(0);
  let lineNumber = 0;
  let sawRecord = false;
  let endedWithNewline = startStat.size === 0;
  let totalBytes = 0;
  const records = [];
  let endStat;

  function acceptLine(lineBytes, isTerminalLine) {
    lineNumber += 1;
    if (lineBytes.length > MAX_JSONL_LINE_BYTES) {
      throw invalidJsonl(filePath, lineNumber, '单行超过 32 MiB');
    }
    if (lineBytes.length > 0 && lineBytes[lineBytes.length - 1] === 0x0d) {
      lineBytes = lineBytes.subarray(0, lineBytes.length - 1);
    }
    if (lineBytes.length === 0) {
      if (!isTerminalLine) throw invalidJsonl(filePath, lineNumber, '文件中包含空白行');
      return;
    }

    let raw;
    let object;
    try {
      raw = decoder.decode(lineBytes);
      object = JSON.parse(raw);
    } catch {
      throw invalidJsonl(filePath, lineNumber, '不是有效 UTF-8 JSON');
    }
    if (!object || Array.isArray(object) || typeof object !== 'object') {
      throw invalidJsonl(filePath, lineNumber, '顶层必须是 JSON 对象');
    }

    sawRecord = true;
    const record = { raw, object, lineNumber };
    if (onFirstRecord && lineNumber === 1) onFirstRecord(record);
    if (collectRecords) records.push(record);
  }

  try {
    for (;;) {
      const bytesRead = fs.readSync(handle, buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      const chunk = buffer.subarray(0, bytesRead);
      totalBytes += bytesRead;
      hash.update(chunk);
      const data = pending.length ? Buffer.concat([pending, chunk]) : chunk;
      let start = 0;
      for (let index = 0; index < data.length; index += 1) {
        if (data[index] !== 0x0a) continue;
        acceptLine(data.subarray(start, index), false);
        start = index + 1;
      }
      pending = Buffer.from(data.subarray(start));
      if (pending.length > MAX_JSONL_LINE_BYTES) {
        throw invalidJsonl(filePath, lineNumber + 1, '单行超过 32 MiB');
      }
      endedWithNewline = data.length > 0 && data[data.length - 1] === 0x0a;
    }
    if (pending.length) acceptLine(pending, true);
    endStat = fs.fstatSync(handle);
    if (String(endStat.dev) !== String(startStat.dev)
        || String(endStat.ino) !== String(startStat.ino)
        || endStat.size !== startStat.size
        || endStat.mtimeMs !== startStat.mtimeMs
        || totalBytes !== endStat.size) {
      throw invalidJsonl(filePath, 1, '文件在读取期间发生变化');
    }
  } finally {
    fs.closeSync(handle);
  }

  return {
    records,
    sawRecord,
    endedWithNewline,
    fingerprint: fileFingerprint(filePath, endStat, hash.digest('hex')),
  };
}

function recordSessionId(record, kind, filePath) {
  const expectedKey = IDENTITY_KEY_BY_KIND[kind];
  if (!expectedKey) throw new TypeError(`Unsupported session JSONL kind: ${kind}`);
  const expected = normalizeSessionId(record.object[expectedKey]);
  if (!expected) throw invalidJsonl(filePath, record.lineNumber, `缺少有效的顶层 ${expectedKey}`);

  for (const alternateKey of ['id', 'session_id']) {
    if (alternateKey === expectedKey || record.object[alternateKey] === undefined) continue;
    const alternate = normalizeSessionId(record.object[alternateKey]);
    if (alternate && alternate !== expected) {
      throw invalidJsonl(filePath, record.lineNumber, '包含冲突的顶层会话身份');
    }
  }
  return expected;
}

function parseSessionJsonlFile({ filePath, kind, allowMissing = false }) {
  if (!pathEntryExists(filePath)) {
    if (allowMissing) {
      return Object.freeze({ records: Object.freeze([]), fingerprint: null });
    }
    throw invalidJsonl(filePath, 1, '文件不存在');
  }
  const parsed = scanJsonlFile(filePath, { collectRecords: true });
  const records = parsed.records.map((record) => Object.freeze({
    raw: record.raw,
    object: record.object,
    lineNumber: record.lineNumber,
    sessionId: recordSessionId(record, kind, filePath),
  }));
  return Object.freeze({ records: Object.freeze(records), fingerprint: parsed.fingerprint });
}

function fingerprintMatches(current, expected) {
  return current.dev === expected.dev
    && current.ino === expected.ino
    && current.size === expected.size
    && current.mtimeMs === expected.mtimeMs
    && current.digest === expected.digest;
}

function sameFingerprintAt(filePath, expected) {
  if (!expected) return false;
  try {
    return fingerprintMatches(scanJsonlFile(filePath).fingerprint, expected);
  } catch {
    return false;
  }
}

function sameFingerprint(expected) {
  return sameFingerprintAt(expected && expected.filePath, expected);
}

function pathEntryExists(filePath) {
  try {
    fs.lstatSync(filePath);
    return true;
  } catch (error) {
    if (error && error.code === 'ENOENT') return false;
    throw error;
  }
}

function assertPathsRemainMissing(filePaths, phase) {
  for (const filePath of filePaths) {
    if (pathEntryExists(filePath)) {
      throw securityError(
        'INVALID_SESSION_JSONL',
        `会话文件在${phase}被新建：${filePath}`,
        { filePath },
      );
    }
  }
}

function assertFileContentMatchesFingerprint(filePath, expected) {
  const current = scanJsonlFile(filePath).fingerprint;
  if (current.size !== expected.size || current.digest !== expected.digest) {
    throw securityError(
      'INVALID_SESSION_JSONL',
      `复制后的会话文件与预检内容不一致：${filePath}`,
      { filePath },
    );
  }
}

function outputForOperation(operation, source, destination) {
  const selected = new Set([...operation.sessionIds].map(normalizeSessionId).filter(Boolean));
  let records;
  if (operation.mode === 'merge') {
    const incoming = source.records.filter((record) => selected.has(record.sessionId));
    records = [...destination.records];
    const seen = new Set(records.map((record) => (
      operation.kind === 'sessionIndex' ? record.sessionId : record.raw
    )));
    for (const record of incoming) {
      const key = operation.kind === 'sessionIndex' ? record.sessionId : record.raw;
      if (!seen.has(key)) {
        seen.add(key);
        records.push(record);
      }
    }
  } else if (operation.mode === 'filter') {
    records = source.records.filter((record) => selected.has(record.sessionId));
  } else if (operation.mode === 'delete') {
    records = source.records.filter((record) => !selected.has(record.sessionId));
  } else {
    throw new TypeError(`Unsupported session JSONL operation: ${operation.mode}`);
  }
  const data = records.length ? `${records.map((record) => record.raw).join('\n')}\n` : '';
  return Object.freeze({ destinationPath: operation.destinationPath, data });
}

function buildSessionJsonlPlan({ operations }) {
  const dependencies = [];
  const expectedMissingPaths = new Set();
  const outputs = [];
  for (const operation of operations) {
    const source = parseSessionJsonlFile({
      filePath: operation.sourcePath,
      kind: operation.kind,
      allowMissing: operation.allowMissingSource === true,
    });
    const destination = operation.destinationPath === operation.sourcePath
      ? source
      : parseSessionJsonlFile({
        filePath: operation.destinationPath,
        kind: operation.kind,
        allowMissing: true,
      });
    if (source.fingerprint) dependencies.push(source.fingerprint);
    else expectedMissingPaths.add(operation.sourcePath);
    if (destination.fingerprint && destination !== source) dependencies.push(destination.fingerprint);
    else if (!destination.fingerprint) expectedMissingPaths.add(operation.destinationPath);
    outputs.push(outputForOperation(operation, source, destination));
  }
  return Object.freeze({
    dependencies: Object.freeze(dependencies),
    expectedMissingPaths: Object.freeze([...expectedMissingPaths]),
    outputs: Object.freeze(outputs),
  });
}

function temporaryPath(destinationPath) {
  return path.join(
    path.dirname(destinationPath),
    `.${path.basename(destinationPath)}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`,
  );
}

function applySessionJsonlPlan(plan) {
  for (const dependency of plan.dependencies) {
    if (!sameFingerprint(dependency)) {
      throw securityError('INVALID_SESSION_JSONL', `会话索引在预检后发生变化：${dependency.filePath}`);
    }
  }
  assertPathsRemainMissing(plan.expectedMissingPaths || [], '预检后');

  const staged = [];
  const published = [];
  try {
    for (const output of plan.outputs) {
      fs.mkdirSync(path.dirname(output.destinationPath), { recursive: true });
      const temporary = temporaryPath(output.destinationPath);
      const handle = fs.openSync(temporary, 'wx', 0o600);
      try {
        fs.writeFileSync(handle, output.data, 'utf8');
        fs.fsyncSync(handle);
      } finally {
        fs.closeSync(handle);
      }
      staged.push({ ...output, temporary });
    }

    for (const dependency of plan.dependencies) {
      if (!sameFingerprint(dependency)) {
        throw securityError('INVALID_SESSION_JSONL', `会话索引在提交前发生变化：${dependency.filePath}`);
      }
    }
    assertPathsRemainMissing(plan.expectedMissingPaths || [], '提交前');
    const expectedMissing = new Set(plan.expectedMissingPaths || []);
    for (const output of staged) {
      if (expectedMissing.has(output.destinationPath)) {
        fs.linkSync(output.temporary, output.destinationPath);
        published.push({ destinationPath: output.destinationPath, backup: null });
      } else if (fs.existsSync(output.destinationPath)) {
        const backup = `${output.temporary}.previous`;
        fs.linkSync(output.destinationPath, backup);
        try {
          fs.renameSync(output.temporary, output.destinationPath);
        } catch (error) {
          fs.rmSync(backup, { force: true });
          throw error;
        }
        published.push({ destinationPath: output.destinationPath, backup });
      } else {
        fs.linkSync(output.temporary, output.destinationPath);
        published.push({ destinationPath: output.destinationPath, backup: null });
      }
    }
  } catch (error) {
    for (const output of [...published].reverse()) {
      if (output.backup && fs.existsSync(output.backup)) {
        fs.renameSync(output.backup, output.destinationPath);
      } else {
        fs.rmSync(output.destinationPath, { force: true });
      }
    }
    for (const output of staged) fs.rmSync(output.temporary, { force: true });
    throw error;
  } finally {
    for (const output of staged) fs.rmSync(output.temporary, { force: true });
    for (const output of published) {
      if (output.backup) fs.rmSync(output.backup, { force: true });
    }
  }
}

function isWithin(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function identityFromRolloutRecord(record, filePath) {
  if (record.object.type !== 'session_meta'
      || !record.object.payload
      || typeof record.object.payload !== 'object') {
    throw securityError('UNTRUSTED_SESSION_FILE', `${filePath} 首条记录不是 session_meta`);
  }
  const identity = normalizeSessionId(record.object.payload.id);
  if (!identity) throw securityError('UNTRUSTED_SESSION_FILE', `${filePath} 缺少可信会话 ID`);
  return identity;
}

function trustedDirectoryRoot(rootPath, { allowMissing = false } = {}) {
  let stat;
  try {
    stat = fs.lstatSync(rootPath);
  } catch (error) {
    if (allowMissing && error && error.code === 'ENOENT') return null;
    throw error;
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw securityError('UNTRUSTED_SESSION_FILE', `不可信的会话根目录：${rootPath}`);
  }
  return fs.realpathSync.native(rootPath);
}

function firstRolloutIdentity(filePath) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw securityError('UNTRUSTED_SESSION_FILE', `${filePath} 不是普通文件`);
  }
  const handle = fs.openSync(filePath, 'r');
  const chunks = [];
  let total = 0;
  try {
    const buffer = Buffer.allocUnsafe(64 * 1024);
    for (;;) {
      const bytesRead = fs.readSync(handle, buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      const chunk = Buffer.from(buffer.subarray(0, bytesRead));
      const newline = chunk.indexOf(0x0a);
      chunks.push(newline >= 0 ? chunk.subarray(0, newline) : chunk);
      total += chunks[chunks.length - 1].length;
      if (total > MAX_JSONL_LINE_BYTES) {
        throw securityError('UNTRUSTED_SESSION_FILE', `${filePath} 首行超过 32 MiB`);
      }
      if (newline >= 0) break;
    }
  } finally {
    fs.closeSync(handle);
  }
  let line = Buffer.concat(chunks);
  if (line.length && line[line.length - 1] === 0x0d) line = line.subarray(0, line.length - 1);
  if (!line.length) throw securityError('UNTRUSTED_SESSION_FILE', `${filePath} 没有 session_meta`);
  try {
    return identityFromRolloutRecord({ object: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line)) }, filePath);
  } catch (error) {
    if (error.code === 'UNTRUSTED_SESSION_FILE') throw error;
    throw securityError('UNTRUSTED_SESSION_FILE', `${filePath} 首条记录不是有效 JSON`);
  }
}

function indexTrustedSessionFiles({ codexRoot }) {
  const index = new Map();
  const canonicalRoot = trustedDirectoryRoot(codexRoot);
  for (const directoryName of ['sessions', 'archived_sessions']) {
    const directory = path.join(codexRoot, directoryName);
    if (!fs.existsSync(directory)) continue;
    const directoryStat = fs.lstatSync(directory);
    if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) continue;

    const pending = [directory];
    while (pending.length) {
      const current = pending.pop();
      for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
        const candidate = path.join(current, entry.name);
        const candidateStat = fs.lstatSync(candidate);
        if (candidateStat.isSymbolicLink()) continue;
        if (candidateStat.isDirectory()) {
          pending.push(candidate);
          continue;
        }
        if (!candidateStat.isFile() || path.extname(entry.name).toLowerCase() !== '.jsonl') continue;
        try {
          const canonical = fs.realpathSync.native(candidate);
          if (!isWithin(canonical, canonicalRoot)) continue;
          const identity = firstRolloutIdentity(canonical);
          const matches = index.get(identity) || [];
          matches.push(canonical);
          index.set(identity, matches);
        } catch {
          // Untrusted and malformed files are excluded from the trusted index.
        }
      }
    }
  }
  for (const matches of index.values()) matches.sort();
  return index;
}

function trustedRolloutFingerprint(filePath, expectedSessionId, canonicalRoot) {
  const canonical = fs.realpathSync.native(filePath);
  const insideSessionDirectory = ['sessions', 'archived_sessions']
    .some((directory) => isWithin(canonical, path.join(canonicalRoot, directory)));
  if (!isWithin(canonical, canonicalRoot)
      || !insideSessionDirectory
      || path.extname(canonical).toLowerCase() !== '.jsonl') {
    throw securityError('UNTRUSTED_SESSION_FILE', `会话文件越出 Codex 目录：${filePath}`);
  }
  let firstIdentity = null;
  const parsed = scanJsonlFile(canonical, {
    onFirstRecord(record) {
      firstIdentity = identityFromRolloutRecord(record, canonical);
    },
  });
  if (firstIdentity !== normalizeSessionId(expectedSessionId)) {
    throw securityError('UNTRUSTED_SESSION_FILE', `会话文件身份不匹配：${canonical}`);
  }
  return parsed.fingerprint;
}

function resolveTrustedSessionFiles({ sessionIds, codexRoot }) {
  const selected = new Set([...sessionIds].map(normalizeSessionId).filter(Boolean));
  const canonicalRoot = fs.realpathSync.native(codexRoot);
  const index = indexTrustedSessionFiles({ codexRoot });
  const entries = [];
  const missingSessionIds = [];
  for (const sessionId of selected) {
    const matches = index.get(sessionId) || [];
    if (!matches.length) {
      missingSessionIds.push(sessionId);
      continue;
    }
    for (const filePath of matches) {
      entries.push(Object.freeze({
        sessionId,
        filePath,
        fingerprint: trustedRolloutFingerprint(filePath, sessionId, canonicalRoot),
      }));
    }
  }
  return Object.freeze({
    entries: Object.freeze(entries),
    missingSessionIds: Object.freeze(missingSessionIds),
  });
}

function jsonlKindForName(name) {
  if (name === 'session_index.jsonl') return 'sessionIndex';
  if (name === 'history.jsonl.bak') return 'historyBackup';
  return 'history';
}

function assertFingerprints(fingerprints, phase) {
  for (const fingerprint of fingerprints) {
    if (!sameFingerprint(fingerprint)) {
      throw securityError('INVALID_SESSION_JSONL', `会话文件在${phase}发生变化：${fingerprint.filePath}`);
    }
  }
}

function buildSessionDeletionPlan({ sessionIds, codexRoot }) {
  const normalizedIds = new Set([...sessionIds].map(normalizeSessionId).filter(Boolean));
  const trusted = resolveTrustedSessionFiles({ sessionIds: normalizedIds, codexRoot });
  const operations = [];
  for (const name of ['history.jsonl', 'history.jsonl.bak', 'session_index.jsonl']) {
    const filePath = path.join(codexRoot, name);
    if (!fs.existsSync(filePath)) continue;
    operations.push({
      mode: 'delete',
      kind: jsonlKindForName(name),
      sourcePath: filePath,
      destinationPath: filePath,
      sessionIds: normalizedIds,
    });
  }
  return Object.freeze({
    codexRoot,
    sessionIds: Object.freeze([...normalizedIds]),
    trustedFiles: trusted.entries,
    missingSessionIds: trusted.missingSessionIds,
    jsonlPlan: buildSessionJsonlPlan({ operations }),
  });
}

function buildSessionProtectionPlan({ sessionIds, codexRoot, destinationRoot }) {
  const normalizedIds = new Set([...sessionIds].map(normalizeSessionId).filter(Boolean));
  const trusted = resolveTrustedSessionFiles({ sessionIds: normalizedIds, codexRoot });
  const canonicalRoot = fs.realpathSync.native(codexRoot);
  const trustedFiles = trusted.entries.map((entry) => {
    const relativePath = path.relative(canonicalRoot, entry.filePath);
    if (!isWithin(entry.filePath, canonicalRoot) || path.isAbsolute(relativePath)) {
      throw securityError('UNTRUSTED_SESSION_FILE', `会话文件越出 Codex 目录：${entry.filePath}`);
    }
    return Object.freeze({
      ...entry,
      relativePath,
      destinationPath: path.join(destinationRoot, relativePath),
    });
  });
  const operations = [];
  for (const name of ['history.jsonl', 'history.jsonl.bak', 'session_index.jsonl']) {
    const sourcePath = path.join(codexRoot, name);
    if (!pathEntryExists(sourcePath)) continue;
    operations.push({
      mode: 'filter',
      kind: jsonlKindForName(name),
      sourcePath,
      destinationPath: path.join(destinationRoot, name),
      sessionIds: normalizedIds,
    });
  }
  assertPathsRemainMissing(
    [
      ...trustedFiles.map((entry) => entry.destinationPath),
      ...operations.map((operation) => operation.destinationPath),
    ],
    '保护快照预检时',
  );
  return Object.freeze({
    codexRoot,
    destinationRoot,
    sessionIds: Object.freeze([...normalizedIds]),
    trustedFiles: Object.freeze(trustedFiles),
    missingSessionIds: trusted.missingSessionIds,
    jsonlPlan: buildSessionJsonlPlan({ operations }),
  });
}

function assertSessionProtectionPlanFresh(plan, phase = '提交前', { requireMissingDestinations = true } = {}) {
  assertFingerprints(plan.trustedFiles.map((entry) => entry.fingerprint), phase);
  assertFingerprints(plan.jsonlPlan.dependencies, phase);
  if (requireMissingDestinations) {
    assertPathsRemainMissing(
      [
        ...plan.trustedFiles.map((entry) => entry.destinationPath),
        ...(plan.jsonlPlan.expectedMissingPaths || []),
      ],
      phase,
    );
  }
}

function materializeSessionProtectionPlan(plan) {
  assertSessionProtectionPlanFresh(plan, '保护快照写入前');
  const copied = [];
  let jsonlPublished = false;
  try {
    applySessionJsonlPlan(plan.jsonlPlan);
    jsonlPublished = true;
    for (const entry of plan.trustedFiles) {
      if (!sameFingerprint(entry.fingerprint)) {
        throw securityError(
          'INVALID_SESSION_JSONL',
          `会话文件在保护快照复制前发生变化：${entry.filePath}`,
          { filePath: entry.filePath },
        );
      }
      fs.mkdirSync(path.dirname(entry.destinationPath), { recursive: true });
      const temporary = temporaryPath(entry.destinationPath);
      try {
        fs.copyFileSync(entry.filePath, temporary, fs.constants.COPYFILE_EXCL);
        const handle = fs.openSync(temporary, 'r+');
        try {
          fs.fsyncSync(handle);
        } finally {
          fs.closeSync(handle);
        }
        assertFileContentMatchesFingerprint(temporary, entry.fingerprint);
        if (!sameFingerprint(entry.fingerprint)) {
          throw securityError(
            'INVALID_SESSION_JSONL',
            `会话文件在保护快照复制期间发生变化：${entry.filePath}`,
            { filePath: entry.filePath },
          );
        }
        fs.linkSync(temporary, entry.destinationPath);
        copied.push(entry.destinationPath);
      } finally {
        fs.rmSync(temporary, { force: true });
      }
    }
    assertSessionProtectionPlanFresh(
      plan,
      '保护快照提交前',
      { requireMissingDestinations: false },
    );
  } catch (error) {
    for (const destinationPath of copied.reverse()) fs.rmSync(destinationPath, { force: true });
    if (jsonlPublished) {
      for (const output of plan.jsonlPlan.outputs) {
        fs.rmSync(output.destinationPath, { force: true });
      }
    }
    throw error;
  }
}

function buildSessionRestorePlan({ sessionIds, sourceRoot, destinationRoot, replace = false }) {
  const normalizedIds = new Set([...sessionIds].map(normalizeSessionId).filter(Boolean));
  const trusted = resolveTrustedSessionFiles({ sessionIds: normalizedIds, codexRoot: sourceRoot });
  trustedDirectoryRoot(destinationRoot, { allowMissing: true });
  if (trusted.missingSessionIds.length) {
    throw securityError(
      'UNTRUSTED_SESSION_FILE',
      `快照缺少可信会话文件：${trusted.missingSessionIds.join(', ')}`,
    );
  }
  const canonicalSourceRoot = fs.realpathSync.native(sourceRoot);
  const trustedFiles = trusted.entries.map((entry) => {
    const relativePath = path.relative(canonicalSourceRoot, entry.filePath);
    if (!isWithin(entry.filePath, canonicalSourceRoot) || path.isAbsolute(relativePath)) {
      throw securityError('UNTRUSTED_SESSION_FILE', `会话文件越出快照目录：${entry.filePath}`);
    }
    const destinationPath = path.join(destinationRoot, relativePath);
    let destinationFingerprint = null;
    const destinationExpectedMissing = !pathEntryExists(destinationPath);
    if (!destinationExpectedMissing) {
      const destinationCanonicalRoot = fs.realpathSync.native(destinationRoot);
      destinationFingerprint = trustedRolloutFingerprint(
        destinationPath,
        entry.sessionId,
        destinationCanonicalRoot,
      );
    }
    return Object.freeze({
      ...entry,
      relativePath,
      destinationPath,
      destinationFingerprint,
      destinationExpectedMissing,
    });
  });
  const operations = [];
  for (const name of ['history.jsonl', 'history.jsonl.bak', 'session_index.jsonl']) {
    const sourcePath = path.join(sourceRoot, name);
    if (!fs.existsSync(sourcePath)) continue;
    operations.push({
      mode: replace ? 'filter' : 'merge',
      kind: jsonlKindForName(name),
      sourcePath,
      destinationPath: path.join(destinationRoot, name),
      sessionIds: normalizedIds,
    });
  }
  return Object.freeze({
    sourceRoot,
    destinationRoot,
    sessionIds: Object.freeze([...normalizedIds]),
    trustedFiles: Object.freeze(trustedFiles),
    jsonlPlan: buildSessionJsonlPlan({ operations }),
  });
}

function assertSessionRestorePlanFresh(plan, phase = '提交前') {
  assertFingerprints(plan.trustedFiles.map((entry) => entry.fingerprint), phase);
  assertFingerprints(
    plan.trustedFiles.map((entry) => entry.destinationFingerprint).filter(Boolean),
    phase,
  );
  assertFingerprints(plan.jsonlPlan.dependencies, phase);
  assertPathsRemainMissing(
    plan.trustedFiles
      .filter((entry) => entry.destinationExpectedMissing)
      .map((entry) => entry.destinationPath),
    phase,
  );
  assertPathsRemainMissing(plan.jsonlPlan.expectedMissingPaths || [], phase);
}

function assertSessionDeletionPlanFresh(plan, phase = '提交前') {
  assertFingerprints(plan.trustedFiles.map((entry) => entry.fingerprint), phase);
  assertFingerprints(plan.jsonlPlan.dependencies, phase);
}

function applySessionDeletionPlan(plan) {
  assertSessionDeletionPlanFresh(plan);
  const quarantined = [];
  try {
    for (const entry of plan.trustedFiles) {
      const quarantinePath = path.join(
        path.dirname(entry.filePath),
        `.${path.basename(entry.filePath)}.delete-quarantine-${process.pid}-${crypto.randomBytes(8).toString('hex')}`,
      );
      fs.renameSync(entry.filePath, quarantinePath);
      const item = { entry, quarantinePath };
      quarantined.push(item);
      if (!sameFingerprintAt(quarantinePath, entry.fingerprint)) {
        throw securityError(
          'INVALID_SESSION_JSONL',
          `会话文件在删除提交前发生变化：${entry.filePath}`,
          { filePath: entry.filePath },
        );
      }
    }
    applySessionJsonlPlan(plan.jsonlPlan);
  } catch (error) {
    const recoveryPaths = [];
    for (const item of [...quarantined].reverse()) {
      if (!pathEntryExists(item.quarantinePath)) continue;
      if (!pathEntryExists(item.entry.filePath)) {
        try {
          fs.renameSync(item.quarantinePath, item.entry.filePath);
          continue;
        } catch {
          // Preserve the quarantined copy below and surface its path to callers.
        }
      }
      recoveryPaths.push(item.quarantinePath);
    }
    if (recoveryPaths.length) error.recoveryPaths = recoveryPaths;
    throw error;
  }

  const warnings = [];
  if (plan.missingSessionIds.length) {
    warnings.push(`会话文件不存在或未删除，仅清理索引：${plan.missingSessionIds.join(', ')}`);
  }
  const recreated = quarantined
    .filter((item) => pathEntryExists(item.entry.filePath))
    .map((item) => item.entry.filePath);
  if (recreated.length) warnings.push(`会话文件在删除期间被重新创建，未删除：${recreated.join(', ')}`);
  for (const item of quarantined) {
    try {
      fs.rmSync(item.quarantinePath);
    } catch {
      warnings.push(`隔离文件清理失败，请手动删除：${item.quarantinePath}`);
    }
  }
  return warnings.join(' ');
}

module.exports = {
  applySessionJsonlPlan,
  applySessionDeletionPlan,
  assertFileContentMatchesFingerprint,
  assertSessionDeletionPlanFresh,
  assertSessionProtectionPlanFresh,
  assertSessionRestorePlanFresh,
  buildSessionDeletionPlan,
  buildSessionJsonlPlan,
  buildSessionProtectionPlan,
  buildSessionRestorePlan,
  indexTrustedSessionFiles,
  normalizeSessionId,
  parseSessionJsonlFile,
  materializeSessionProtectionPlan,
  resolveTrustedSessionFiles,
};

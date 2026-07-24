# Electron Large JSONL Memory Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep legal large JSONL backup and recovery work out of the long-lived Electron main-process V8 heap while preserving complete validation, atomic publication, and existing data formats.

**Architecture:** The main process first scans record boundaries with a fixed 1 MiB buffer, then copies only the confirmed complete byte range in a second bounded pass. Full-file or changed-range verification at or above 8 MiB runs in a one-use Worker; the Worker returns hashes and exits before the parent operation resolves, so its expanded V8 heap is deterministically reclaimed.

**Tech Stack:** Node.js CommonJS, `node:worker_threads`, Electron 43.1.0, `node:test`, Swift Testing, macOS `/usr/bin/footprint` acceptance sampling.

## Global Constraints

- Keep `MAX_JSONL_LINE_BYTES` at exactly `67_108_864` bytes.
- Keep read and write buffers at or below `1_048_576` bytes in the Electron main process.
- Use isolated verification when a complete file or changed verification range is at least `8 * 1_024 * 1_024` bytes.
- Do not add dependencies or enable/expose forced V8 garbage collection.
- Do not change renderer/preload IPC, UI, NAS layout, manifest, cursor, verification, snapshot, or recovery-result formats.
- Verification remains fail-closed; no Worker failure may fall back to parsing a large file in the main process.
- Preserve the existing one-retry policy and rollback to the last verified NAS state.
- macOS acceptance requires peak `total footprint < 600 MiB`, settled footprint growth after 60 seconds `<= 16 MiB`, diagnostic Swap reporting, and automatic termination at `1 GiB`.
- Windows acceptance requires peak working set `< 650 MiB`, settled growth after 60 seconds `<= 150 MiB`, and automatic termination at `1 GiB`.
- Read the real 319,942,731-byte source only; all writes must use newly created temporary roots.

## File Map

- Modify `scripts/acceptance/large-jsonl-runner.js`: three-process acceptance orchestration and corrected macOS footprint accounting.
- Modify `scripts/acceptance/large-jsonl-runner.test.js`: acceptance policy boundary tests.
- Modify `Tests/CodexSessionVaultCoreTests/LargeJSONLEndToEndAcceptanceTests.swift`: independent Swift prepare/repair/recover workers.
- Modify `windows/codex_session_manager_electron/src/backup/session-backup-streamer.js`: fixed-memory boundary scan and second-pass copy.
- Modify `windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js`: byte semantics and allocation-bound regression tests.
- Create `windows/codex_session_manager_electron/src/backup/isolated-backup-verifier.js`: parent-side Worker lifecycle and protocol validation.
- Create `windows/codex_session_manager_electron/src/backup/backup-verification-worker.js`: read-only Worker entry point.
- Modify `windows/codex_session_manager_electron/src/backup/backup-file-verifier.js`: threshold routing and in-process implementation reuse.
- Create `windows/codex_session_manager_electron/test/backup/isolated-backup-verifier.test.js`: real Worker and lifecycle tests.
- Modify `windows/codex_session_manager_electron/test/backup/backup-verification.test.js`: threshold, result, and error-contract tests.
- Modify `windows/codex_session_manager_electron/src/backup/backup-agent.js`: scan cancellation and signal propagation.
- Modify `windows/codex_session_manager_electron/test/backup/agent.test.js`: stop/abort and rollback tests.
- Modify `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`: large verified recovery regression.

---

### Task 1: Lock the Acceptance Contract

**Files:**
- Modify: `scripts/acceptance/large-jsonl-runner.js`
- Modify: `scripts/acceptance/large-jsonl-runner.test.js`
- Modify: `Tests/CodexSessionVaultCoreTests/LargeJSONLEndToEndAcceptanceTests.swift`

**Interfaces:**
- Consumes: the existing `LARGE_JSONL_ACCEPTANCE_RESULT=` and `LARGE_JSONL_ACCEPTANCE_STAGE=` marker protocol.
- Produces: `realSourcePhasePlan(platform)`, `footprintGrowthBytes(baseline, settled)`, and independent `prepare`, `repair`, and `recover` workers.

- [ ] **Step 1: Add failing acceptance-policy tests**

Replace the macOS policy test with an assertion that Swap is not added twice:

```javascript
test('settled footprint growth does not double-count swap already included by macOS footprint', () => {
  assert.equal(footprintGrowthBytes(35_488_800, 28_247_144), 0);
  assert.equal(footprintGrowthBytes(40, 30), 0);
});

test('macOS budget uses settled total footprint growth while retaining swap diagnostics', () => {
  const memory = {
    peakPhysFootprintBytes: 599 * 1024 * 1024,
    baselinePhysFootprintBytes: 35_488_800,
    settledPhysFootprintBytes: 28_247_144,
    peakSwappedBytes: 120 * 1024 * 1024,
    baselineSwappedBytes: 0,
    settledSwappedBytes: 25_116_672,
  };
  assert.deepEqual(memoryBudgetViolations('darwin', memory), []);
  assert.match(memoryBudgetViolations('darwin', {
    ...memory,
    settledPhysFootprintBytes: memory.baselinePhysFootprintBytes + (16 * 1024 * 1024) + 1,
  })[0], /settled footprint growth exceeded 16 MiB/);
});
```

- [ ] **Step 2: Run the policy tests and verify RED**

Run:

```bash
node --test scripts/acceptance/large-jsonl-runner.test.js
```

Expected: the old implementation reports `settled swap growth exceeded 16 MiB` or returns a positive value after adding Swap to `total footprint`.

- [ ] **Step 3: Implement the exact footprint rule**

Use the `footprint` total directly and retain separate Swap fields in the report:

```javascript
const MAC_SETTLED_FOOTPRINT_GROWTH_LIMIT_BYTES = 16 * 1024 * 1024;

function footprintGrowthBytes(baselineFootprintBytes, settledFootprintBytes) {
  return Math.max(0, settledFootprintBytes - baselineFootprintBytes);
}

function memoryBudgetViolations(platform, memory) {
  const violations = [];
  if (platform === 'darwin') {
    if (memory.peakPhysFootprintBytes >= MAC_LIMIT_BYTES) {
      violations.push(`peak phys_footprint exceeded 600 MiB: ${memory.peakPhysFootprintBytes}`);
    }
    const growth = footprintGrowthBytes(
      memory.baselinePhysFootprintBytes,
      memory.settledPhysFootprintBytes,
    );
    if (growth > MAC_SETTLED_FOOTPRINT_GROWTH_LIMIT_BYTES) {
      violations.push(`settled footprint growth exceeded 16 MiB: ${growth}`);
    }
  } else if (platform === 'win32') {
    if (memory.peakRssBytes >= WINDOWS_LIMIT_BYTES) {
      violations.push(`peak working set exceeded 650 MiB: ${memory.peakRssBytes}`);
    }
    const growth = Math.max(0, memory.settledRssBytes - memory.baselineRssBytes);
    if (growth > SETTLED_MEMORY_GROWTH_LIMIT_BYTES) {
      violations.push(`settled working set growth exceeded 150 MiB: ${growth}`);
    }
  }
  return violations;
}
```

Keep `peakSwappedBytes`, `peakSwapGrowthBytes`, `settledSwappedBytes`, and `settledSwapGrowthBytes` in every macOS report.

- [ ] **Step 4: Split real-source acceptance into independent workers**

Use this phase plan:

```javascript
function realSourcePhasePlan(platform) {
  const swiftWorkerRecovery = platform === 'swift';
  return [
    Object.freeze({ phase: 'prepare', enforceLimits: false, settleSeconds: 0, transientWorker: false }),
    Object.freeze({ phase: 'repair', enforceLimits: true, settleSeconds: 60, transientWorker: false }),
    Object.freeze({
      phase: 'recover',
      enforceLimits: true,
      settleSeconds: swiftWorkerRecovery ? 0 : 60,
      transientWorker: swiftWorkerRecovery,
    }),
  ];
}
```

Swift must select the phase from `CODEX_REAL_LARGE_JSONL_PHASE` and use the same `CODEX_REAL_LARGE_JSONL_ROOT` for all three processes. `prepare` creates only the isolated legacy-block fixture, `repair` performs backup and waits 60 seconds, and `recover` restores from the prepared isolated backup.

- [ ] **Step 5: Verify focused acceptance code**

Run:

```bash
node --test scripts/acceptance/large-jsonl-runner.test.js
node --check scripts/acceptance/large-jsonl-runner.js
swift test -c release --filter LargeJSONLEndToEndAcceptanceTests
git diff --check
```

Expected: five JavaScript policy tests pass, the Swift phase-validation tests pass, and no whitespace errors are reported.

- [ ] **Step 6: Commit the acceptance contract**

```bash
git add scripts/acceptance/large-jsonl-runner.js \
  scripts/acceptance/large-jsonl-runner.test.js \
  Tests/CodexSessionVaultCoreTests/LargeJSONLEndToEndAcceptanceTests.swift
git commit -m "test: isolate large JSONL memory acceptance"
```

---

### Task 2: Replace Whole-Record Backup Buffers with Two Bounded Passes

**Files:**
- Modify: `windows/codex_session_manager_electron/src/backup/session-backup-streamer.js`
- Modify: `windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js`

**Interfaces:**
- Consumes: existing `createBufferedBackupWriter`, `durableReplaceWithWriter`, title limits, and 64 MiB JSONL policy.
- Produces: internal `scanCompleteRecordBoundaries(options)` and `copyCompleteByteRange(options)`; public exports and result structures remain unchanged.

- [ ] **Step 1: Add allocation-bound and byte-identity tests**

Add a fixture that does not create a large JavaScript string:

```javascript
function jsonStringRecord(lineBytes) {
  const record = Buffer.alloc(lineBytes + 1, 0x78);
  record[0] = 0x22;
  record[lineBytes - 1] = 0x22;
  record[lineBytes] = 0x0A;
  return record;
}
```

Add rebuild and append tests using a 9 MiB record. Wrap only the operation with `withTrackedUnsafeAllocations` and assert:

```javascript
assert.deepEqual(await fs.readFile(targetPath), source);
assert.equal(result.lineCount, 1);
assert.ok(allocationSizes.length > 0);
assert.ok(allocationSizes.every((size) => size <= ONE_MIB));
```

For rebuild, also assert that source reads are bounded and that total source reads are at least twice the source length. For append, seed a small verified prefix and assert the first positioned write begins at the prefix length. Extend the existing `verifyCompletePrefix` test so a 9 MiB line performs zero `Buffer.concat` calls.

- [ ] **Step 2: Run streamer tests and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/session-backup-streamer.test.js
```

Expected: the new allocation test reports an allocation larger than 1 MiB from the spanning-line accumulator.

- [ ] **Step 3: Implement a numeric boundary scanner**

Replace the whole-record accumulator in backup streaming with a scanner that retains at most the existing title and partial-line budgets:

```javascript
async function scanCompleteRecordBoundaries({
  sourceHandle,
  sourcePath,
  startOffset = 0,
  maximumByteCount = null,
  chunkSize = DEFAULT_CHUNK_SIZE,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
  interruptionRequested = () => false,
  onChunk = null,
}) {
  const readSize = normalizedChunkSize(chunkSize);
  const lineLimit = normalizedLineLimit(maxLineBytes);
  const scratch = Buffer.allocUnsafe(readSize);
  const partial = Buffer.allocUnsafe(Math.min(MAX_PENDING_PARTIAL_BYTES, Math.max(1, lineLimit)));
  const titleScanner = createTitleScanner();
  let position = startOffset;
  let remaining = maximumByteCount;
  let committedByteCount = 0;
  let lineCount = 0;
  let currentLineBytes = 0;
  let partialLength = 0;
  let partialOverflow = false;
  let blockedError = null;

  while (remaining === null || remaining > 0) {
    if (interruptionRequested()) throw interruptedError();
    const requested = remaining === null ? readSize : Math.min(readSize, remaining);
    if (requested === 0) break;
    const { bytesRead } = await sourceHandle.read(scratch, 0, requested, position);
    if (bytesRead === 0) break;
    await onChunk?.(position, bytesRead);
    for (let index = 0; index < bytesRead; index += 1) {
      const byte = scratch[index];
      if (byte === NEWLINE_BYTE) {
        titleScanner.finishRecord(partial.subarray(0, partialLength), currentLineBytes, partialOverflow);
        committedByteCount += currentLineBytes + 1;
        lineCount += 1;
        currentLineBytes = 0;
        partialLength = 0;
        partialOverflow = false;
        continue;
      }
      currentLineBytes += 1;
      if (currentLineBytes > lineLimit) {
        blockedError = blockedErrorMessage(sourcePath, lineLimit, startOffset + committedByteCount);
        break;
      }
      if (partialLength < partial.length) partial[partialLength++] = byte;
      else partialOverflow = true;
    }
    position += bytesRead;
    if (remaining !== null) remaining -= bytesRead;
    if (blockedError) break;
  }

  return Object.freeze({
    committedByteCount,
    lineCount,
    pendingPartialLine: blockedError || currentLineBytes === 0
      ? ''
      : partialOverflow ? '\0' : partial.subarray(0, partialLength).toString('utf8'),
    blockedError,
    firstTitle: titleScanner.title,
  });
}
```

`createTitleScanner().finishRecord(...)` must increment the record budget for every complete record, skip records larger than 64 KiB without decoding them, enforce the 256 KiB cumulative parse budget, and call `titleFromJsonLine` only for captured complete records.

- [ ] **Step 4: Implement the bounded second pass**

Add a copier that reads and writes only the byte count returned by the scanner:

```javascript
async function copyCompleteByteRange({
  sourceHandle,
  startOffset,
  byteCount,
  chunkSize = DEFAULT_CHUNK_SIZE,
  writeChunk,
  interruptionRequested = () => false,
}) {
  const readSize = normalizedChunkSize(chunkSize);
  const scratch = Buffer.allocUnsafe(readSize);
  const digest = crypto.createHash('sha256');
  let copied = 0;
  while (copied < byteCount) {
    if (interruptionRequested()) throw interruptedError();
    const requested = Math.min(readSize, byteCount - copied);
    const { bytesRead } = await sourceHandle.read(scratch, 0, requested, startOffset + copied);
    if (bytesRead !== requested) throw new Error(`Source changed during streamed backup: expected ${requested}, got ${bytesRead}.`);
    const chunk = scratch.subarray(0, bytesRead);
    await writeChunk(chunk);
    digest.update(chunk);
    copied += bytesRead;
  }
  return Object.freeze({ copiedByteCount: copied, contentHash: digest.digest('hex') });
}
```

`rebuildSessionCompleteLines` must scan first, reopen/seek the source for the copy pass, copy exactly `committedByteCount`, flush and sync before temporary verification, and return the existing fields. `appendCompleteLines` must scan the suffix first, then copy exactly that complete suffix to the positioned 1 MiB writer. `verifyCompletePrefix` must feed compared target chunks into the same numeric scanner instead of storing `pendingChunks` or calling `Buffer.concat`.

- [ ] **Step 5: Run streamer regression tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/session-backup-streamer.test.js
node --check src/backup/session-backup-streamer.js
```

Expected: all streamer tests pass; the 9 MiB record is byte-identical and no tracked main-process allocation exceeds 1 MiB.

- [ ] **Step 6: Commit the two-pass streamer**

```bash
git add windows/codex_session_manager_electron/src/backup/session-backup-streamer.js \
  windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js
git commit -m "fix: bound Electron backup streaming memory"
```

---

### Task 3: Isolate Large JSON Validation in a One-Use Worker

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/isolated-backup-verifier.js`
- Create: `windows/codex_session_manager_electron/src/backup/backup-verification-worker.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-file-verifier.js`
- Create: `windows/codex_session_manager_electron/test/backup/isolated-backup-verifier.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/backup-verification.test.js`

**Interfaces:**
- Consumes: current full and changed-chunk verifier option objects.
- Produces: `ISOLATED_VERIFICATION_THRESHOLD_BYTES`, `runIsolatedBackupVerification({ operation, payload, signal })`, and unchanged public verification result objects.

- [ ] **Step 1: Add failing Worker protocol tests**

Use a real temporary JSONL file and call `runIsolatedBackupVerification` directly:

```javascript
test('isolated full verification returns hashes and exits before resolving', async (t) => {
  const root = await fixture(t);
  const filePath = path.join(root, 'session.jsonl');
  const contents = Buffer.from('{"ok":true}\n');
  await fs.writeFile(filePath, contents);
  const events = [];
  const result = await runIsolatedBackupVerification({
    operation: 'verifyFull',
    payload: { filePath, chunkSize: 8, maxLineBytes: 64 },
    onLifecycle: (event) => events.push(event),
  });
  assert.equal(result.contentHash, sha256(contents));
  assert.deepEqual(events, ['started', 'message', 'exited']);
});
```

Add tests for malformed JSON, an unknown operation, an already-aborted signal, and an abort after `started`. The abort test must assert an `AbortError`, an `exited` lifecycle event, and no result message after termination.

In `backup-verification.test.js`, add threshold routing tests for exactly `8 MiB - 1` and exactly `8 MiB` using an injected `isolationRunner`; assert the smaller range invokes the in-process implementation and the exact-threshold range invokes the isolation runner once.

- [ ] **Step 2: Run verification tests and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/isolated-backup-verifier.test.js test/backup/backup-verification.test.js
```

Expected: module-not-found or missing-export failures for `isolated-backup-verifier.js`.

- [ ] **Step 3: Implement the parent-side Worker lifecycle**

Create `isolated-backup-verifier.js` with a fixed protocol and wait for both message and exit:

```javascript
'use strict';

const path = require('node:path');
const { Worker } = require('node:worker_threads');

const ISOLATED_VERIFICATION_THRESHOLD_BYTES = 8 * 1024 * 1024;
const WORKER_PATH = path.join(__dirname, 'backup-verification-worker.js');
const OPERATIONS = new Set(['verifyFull', 'verifyChangedChunks']);

function abortError() {
  const error = new Error('Backup verification was cancelled.');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

async function runIsolatedBackupVerification({
  operation,
  payload,
  signal = null,
  workerFactory = (workerData) => new Worker(WORKER_PATH, { workerData }),
  onLifecycle = null,
}) {
  if (!OPERATIONS.has(operation)) throw new Error(`Unsupported backup verification operation: ${operation}`);
  if (signal?.aborted) throw abortError();
  const worker = workerFactory({ version: 1, operation, payload });
  let response = null;
  let workerError = null;
  const abort = () => { void worker.terminate(); };
  const exit = new Promise((resolve) => {
    worker.once('message', (message) => {
      response = message;
      onLifecycle?.('message');
    });
    worker.once('error', (error) => { workerError = error; });
    worker.once('exit', resolve);
  });
  signal?.addEventListener('abort', abort, { once: true });
  onLifecycle?.('started');
  try {
    const exitCode = await exit;
    onLifecycle?.('exited');
    if (signal?.aborted) throw abortError();
    if (workerError) throw workerError;
    if (exitCode !== 0 || !response || response.version !== 1 || typeof response.ok !== 'boolean') {
      throw new Error(`Backup verification Worker failed with exit code ${exitCode}.`);
    }
    if (!response.ok) {
      const error = new Error(String(response.error?.message || 'Backup verification failed.'));
      error.name = String(response.error?.name || 'Error');
      error.code = response.error?.code;
      throw error;
    }
    return response.result;
  } finally {
    signal?.removeEventListener('abort', abort);
  }
}

module.exports = {
  ISOLATED_VERIFICATION_THRESHOLD_BYTES,
  runIsolatedBackupVerification,
};
```

The implementation must guard against `message`/`exit` ordering: if exit arrives before a valid message, reject; if a message arrives first, resolve only after exit.

- [ ] **Step 4: Implement the read-only Worker entry**

Create `backup-verification-worker.js`:

```javascript
'use strict';

const { parentPort, workerData } = require('node:worker_threads');
const {
  verifyChangedBackupChunksInProcess,
  verifyFullBackupFileInProcess,
} = require('./backup-file-verifier');

async function main() {
  const { version, operation, payload } = workerData || {};
  if (version !== 1) throw new Error('Unsupported backup verification Worker protocol.');
  const result = operation === 'verifyFull'
    ? await verifyFullBackupFileInProcess(payload)
    : operation === 'verifyChangedChunks'
      ? await verifyChangedBackupChunksInProcess(payload)
      : (() => { throw new Error(`Unsupported backup verification operation: ${operation}`); })();
  parentPort.postMessage({ version: 1, ok: true, result });
  parentPort.close();
}

main().catch((error) => {
  parentPort.postMessage({
    version: 1,
    ok: false,
    error: { name: error.name, message: error.message, code: error.code },
  });
  parentPort.close();
});
```

- [ ] **Step 5: Route only large work to the Worker**

Rename the current bodies to `verifyFullBackupFileInProcess` and `verifyChangedBackupChunksInProcess` without changing their validation order. Add wrappers that strip `signal` and functions from the structured-clone payload:

```javascript
async function verifyFullBackupFile(options) {
  const { signal = null, isolationRunner = runIsolatedBackupVerification, ...payload } = options;
  const stats = await fsp.lstat(payload.filePath);
  if (stats.size >= ISOLATED_VERIFICATION_THRESHOLD_BYTES) {
    try {
      return await isolationRunner({ operation: 'verifyFull', payload, signal });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new BackupFileVerificationError(error.message || String(error));
    }
  }
  return verifyFullBackupFileInProcess(payload);
}

async function verifyChangedBackupChunks(options) {
  const { signal = null, isolationRunner = runIsolatedBackupVerification, ...payload } = options;
  const chunkSize = payload.chunkSize ?? DEFAULT_VERIFICATION_CHUNK_SIZE;
  const previousBytes = Number(payload.previous?.byteCount);
  const committedBytes = Number(payload.committedByteCount);
  const startOffset = Number.isSafeInteger(previousBytes) && Number.isSafeInteger(chunkSize) && chunkSize > 0
    ? Math.floor(previousBytes / chunkSize) * chunkSize
    : committedBytes;
  const changedBytes = Math.max(0, committedBytes - startOffset);
  if (changedBytes >= ISOLATED_VERIFICATION_THRESHOLD_BYTES) {
    try {
      return await isolationRunner({ operation: 'verifyChangedChunks', payload, signal });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new BackupFileVerificationError(error.message || String(error));
    }
  }
  return verifyChangedBackupChunksInProcess(payload);
}
```

Export both in-process functions only for the Worker entry. Do not export `isolationRunner` through renderer or preload code.

- [ ] **Step 6: Verify Worker and verifier tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/isolated-backup-verifier.test.js test/backup/backup-verification.test.js
node --check src/backup/isolated-backup-verifier.js
node --check src/backup/backup-verification-worker.js
node --check src/backup/backup-file-verifier.js
```

Expected: all tests pass; invalid JSON remains `instanceof BackupFileVerificationError`, and cancellation remains `AbortError`.

- [ ] **Step 7: Commit Worker isolation**

```bash
git add windows/codex_session_manager_electron/src/backup/isolated-backup-verifier.js \
  windows/codex_session_manager_electron/src/backup/backup-verification-worker.js \
  windows/codex_session_manager_electron/src/backup/backup-file-verifier.js \
  windows/codex_session_manager_electron/test/backup/isolated-backup-verifier.test.js \
  windows/codex_session_manager_electron/test/backup/backup-verification.test.js
git commit -m "fix: isolate large Electron JSONL verification"
```

---

### Task 4: Propagate Scan Cancellation and Preserve Rollback

**Files:**
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Modify: `windows/codex_session_manager_electron/src/backup/session-backup-streamer.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js`

**Interfaces:**
- Consumes: optional verifier `signal` and streamer `interruptionRequested` callback.
- Produces: one `AbortController` per active scan; `stop()` terminates an active verification Worker and bounded stream.

- [ ] **Step 1: Add failing stop/abort tests**

Add an agent test that injects a file committer whose verification callback enters a controlled Promise. Start a scan, wait until verification begins, call `stop()`, release the controlled Promise, and assert:

```javascript
await assert.rejects(scan, (error) => error?.name === 'AbortError');
assert.equal(await agent.stopAndAwaitQuiescence(1000), true);
assert.equal(await fs.readFile(paths.manifestPath, 'utf8'), manifestBefore);
assert.equal(await fs.readFile(paths.verificationPath, 'utf8'), verificationBefore);
```

Add streamer tests with `interruptionRequested` returning true during boundary scan and during the second copy pass. Rebuild must leave the old target unchanged; append must remain at the original offset.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/agent.test.js test/backup/session-backup-streamer.test.js
```

Expected: active verification continues after `stop()` or the streamer ignores the interruption callback.

- [ ] **Step 3: Add one AbortController per scan**

Add `this.activeScanAbortController = null` in the constructor. Wrap the scan lifecycle:

```javascript
async startOneShotScan() {
  if (this.stopped) return null;
  if (this.scanPromise) {
    this.scanQueued = true;
    return this.scanPromise;
  }
  const controller = new AbortController();
  this.activeScanAbortController = controller;
  this.scanPromise = this.drainScanQueue(controller.signal);
  try {
    return await this.scanPromise;
  } finally {
    if (this.activeScanAbortController === controller) this.activeScanAbortController = null;
    this.scanPromise = null;
  }
}

stop() {
  if (this.stopped) return;
  this.stopped = true;
  this.activeScanAbortController?.abort();
  this.scanQueued = false;
  this.requestAuditInterruption();
  this.stopAuditTimer();
  this.stopPolling();
}
```

Pass `signal` through `drainScanQueue`, `performOneShotScanLocked`, and `processSessionFile`. Pass it to `verifyFullBackupFile` and `verifyChangedBackupChunks`; pass `() => signal.aborted` to rebuild and append streaming.

- [ ] **Step 4: Keep aborts out of error status and preserve rollback**

Add one helper:

```javascript
function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  const error = new Error('Backup scan was cancelled.');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  throw error;
}
```

Call it before every NAS write, after Worker verification, and before manifest/cursor publication. In `drainScanQueue`, rethrow `AbortError` without calling `writeLocalErrorStatus`. Existing append catch logic must truncate the target before rethrowing an abort.

- [ ] **Step 5: Verify cancellation and rollback**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/agent.test.js test/backup/session-backup-streamer.test.js test/backup/isolated-backup-verifier.test.js
node --check src/backup/backup-agent.js
node --check src/backup/session-backup-streamer.js
```

Expected: all tests pass; `stopAndAwaitQuiescence(1000)` returns true and persisted metadata is unchanged after cancellation.

- [ ] **Step 6: Commit cancellation wiring**

```bash
git add windows/codex_session_manager_electron/src/backup/backup-agent.js \
  windows/codex_session_manager_electron/src/backup/session-backup-streamer.js \
  windows/codex_session_manager_electron/test/backup/agent.test.js \
  windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js
git commit -m "fix: cancel active Electron backup verification"
```

---

### Task 5: Prove Large Recovery Uses the Isolated Verifier

**Files:**
- Modify: `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/large-jsonl-policy.test.js`

**Interfaces:**
- Consumes: unchanged `preflightIncrementalRecovery`, `restoreIncrementalSessions`, and public `verifyFullBackupFile`.
- Produces: recovery regression coverage for an above-threshold valid record and fail-closed invalid JSON.

- [ ] **Step 1: Add a valid 9 MiB recovery fixture**

Create the record as a Buffer, write it into an isolated backup root, and generate manifest plus verification using `verifyFullBackupFile`. Run preflight and restore, then assert:

```javascript
assert.deepEqual(await fs.readFile(recoveredPath), largeRecord);
assert.equal(restored.restoredSessionIDs.length, 1);
assert.equal(restored.restoredSessionIDs[0], sessionId);
```

Add a companion test that changes one byte after verification and asserts preflight rejection, no `.codex` creation, and no recovered file.

- [ ] **Step 2: Run recovery tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/incremental-recovery.test.js test/backup/large-jsonl-policy.test.js
```

Expected: both the valid large restore and corrupted fail-closed path pass.

- [ ] **Step 3: Run the complete Electron suite and static checks**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
node --check src/backup/backup-agent.js
node --check src/backup/session-backup-streamer.js
node --check src/backup/backup-file-verifier.js
node --check src/backup/isolated-backup-verifier.js
node --check src/backup/backup-verification-worker.js
```

Expected: the complete test suite passes with no unhandled rejection or leaked Worker warning.

- [ ] **Step 4: Commit recovery coverage**

```bash
git add windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js \
  windows/codex_session_manager_electron/test/backup/large-jsonl-policy.test.js
git commit -m "test: cover isolated large JSONL recovery"
```

---

### Task 6: Run Real-Source Gates, Full Builds, and Package Inspection

**Files:**
- Verify: all modified files from Tasks 1 through 5.
- Build output: `dist/` and `windows/codex_session_manager_electron/dist/` according to existing scripts.

**Interfaces:**
- Consumes: three-phase acceptance runner and existing macOS/Windows build scripts.
- Produces: evidence that both code paths preserve the known real source and that packages contain the Worker entry.

- [ ] **Step 1: Run Swift full verification**

```bash
swift test
swift build -c release
```

Expected: all Swift tests and the release build pass.

- [ ] **Step 2: Run Swift real-source three-phase acceptance**

```bash
CODEX_REAL_LARGE_JSONL_SOURCE='/Users/mqzj/.codex/sessions/2026/07/14/rollout-2026-07-14T10-54-29-019f5e8c-20de-71b2-bcef-ab79b0f36351.jsonl' \
node scripts/acceptance/large-jsonl-runner.js --platform swift --mode real-source
```

Expected: prepare, repair, and recover pass; repair peak is below 600 MiB; settled growth is at most 16 MiB; source inode, size, and mtime are unchanged.

- [ ] **Step 3: Run Electron real-source three-phase acceptance**

```bash
CODEX_REAL_LARGE_JSONL_SOURCE='/Users/mqzj/.codex/sessions/2026/07/14/rollout-2026-07-14T10-54-29-019f5e8c-20de-71b2-bcef-ab79b0f36351.jsonl' \
node scripts/acceptance/large-jsonl-runner.js --platform electron --mode real-source
```

Expected: prepare, repair, and recover pass; repair and recover each settle for 60 seconds; peak is below 600 MiB; settled growth is at most 16 MiB; the 319,942,731 bytes, 11,482 lines, 77 chunks, and known SHA-256 all match.

- [ ] **Step 4: Run repository-wide checks**

```bash
cd windows/codex_session_manager_electron && npm test
cd ../../
node --test scripts/acceptance/large-jsonl-runner.test.js
node --check scripts/acceptance/large-jsonl-runner.js
git diff --check
git status --short
```

Expected: all tests pass; only intentional tracked changes are present; `.codegraph/` remains untracked or ignored.

- [ ] **Step 5: Build macOS and Windows test packages**

```bash
./scripts/build_app.sh
./scripts/build_macos_dmg.sh
(cd windows/codex_session_manager_electron && npm run package:win)
(cd windows/codex_session_manager_electron && npm run dist:win && npm run postdist:win)
```

Expected: every command exits zero.

- [ ] **Step 6: Inspect package contents and compute hashes**

Verify that the Windows package contains both files:

```bash
find dist/win10-exe -path '*resources/app/src/backup/backup-verification-worker.js' -print
find dist/win10-exe -path '*resources/app/vendor/sqlite3.exe' -print
```

Compute SHA-256 for the generated DMG and Windows NSIS installer using `shasum -a 256`. Record absolute artifact paths, sizes, commit ID, and hashes in the handoff. Do not label the Windows package production-ready until Windows 10 real-machine working-set acceptance passes.

- [ ] **Step 7: Final review and commit any intentional verification-only adjustments**

```bash
git diff --check
git status --short --branch
git log -6 --oneline
```

If Task 6 required no source change, create no empty commit. If an acceptance-only correction was necessary, stage only its test/runner files and commit it with:

```bash
git commit -m "test: finalize large JSONL memory gates"
```

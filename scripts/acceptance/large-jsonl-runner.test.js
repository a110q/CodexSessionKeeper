'use strict';

const assert = require('node:assert/strict');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  countNewlines,
  initializeElectronWorkerForMeasurement,
  memoryBudgetViolations,
  realSourcePhasePlan,
  validateCopiesInIsolatedWorker,
  swapGrowthBytes,
  footprintGrowthBytes,
} = require('./large-jsonl-runner');

test('Electron startup baseline is captured after persistent production dependencies load', async () => {
  const events = [];
  const dependencies = await initializeElectronWorkerForMeasurement({
    loadDependencies: () => {
      events.push('dependencies');
      return { loaded: true };
    },
    captureBaseline: async () => { events.push('baseline'); },
  });

  assert.deepEqual(events, ['dependencies', 'baseline']);
  assert.deepEqual(dependencies, { loaded: true });
});

test('acceptance fingerprinting counts newlines without Buffer iteration', () => {
  assert.equal(countNewlines(Buffer.from('one\ntwo\nthree')), 2);
  assert.equal(countNewlines(Buffer.alloc(4 * 1024 * 1024, 0x78)), 0);
});

test('postcondition fingerprinting exits its disposable worker and rejects changed copies', async (t) => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'large-jsonl-fingerprint-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const sourcePath = path.join(root, 'source.jsonl');
  const matchingPath = path.join(root, 'matching.jsonl');
  const changedPath = path.join(root, 'changed.jsonl');
  const content = Buffer.from('{"value":1}\n{"value":2}\n');
  await Promise.all([
    fsp.writeFile(sourcePath, content),
    fsp.writeFile(matchingPath, content),
    fsp.writeFile(changedPath, Buffer.from('{"value":1}\n{"value":3}\n')),
  ]);

  const fingerprint = await validateCopiesInIsolatedWorker({
    sourcePath,
    fingerprintPaths: [matchingPath],
    byteEqualPaths: [matchingPath],
  });
  assert.equal(fingerprint.byteCount, content.length);
  assert.equal(fingerprint.lineCount, 2);

  await assert.rejects(
    validateCopiesInIsolatedWorker({
      sourcePath,
      fingerprintPaths: [changedPath],
      byteEqualPaths: [changedPath],
    }),
    /fingerprint mismatch|byte mismatch/,
  );
});

test('swap growth is clamped to nonnegative bytes above the startup-ready baseline', () => {
  assert.equal(swapGrowthBytes(6_111_232, 7_274_496), 1_163_264);
  assert.equal(swapGrowthBytes(6_111_232, 6_111_232), 0);
  assert.equal(swapGrowthBytes(6_111_232, 5_000_000), 0);
});

test('settled footprint growth does not double-count swap already included by macOS footprint', () => {
  assert.equal(footprintGrowthBytes(35_488_800, 28_247_144), 0);
  assert.equal(footprintGrowthBytes(40, 30), 0);
});

test('Swift real-source recovery models its one-shot worker while Electron remains persistent', () => {
  assert.deepEqual(realSourcePhasePlan('swift'), [
    { phase: 'prepare', enforceLimits: false, settleSeconds: 0, transientWorker: false },
    { phase: 'repair', enforceLimits: true, settleSeconds: 60, transientWorker: false },
    { phase: 'recover', enforceLimits: true, settleSeconds: 0, transientWorker: true },
  ]);
  assert.deepEqual(realSourcePhasePlan('electron'), [
    { phase: 'prepare', enforceLimits: false, settleSeconds: 0, transientWorker: false },
    { phase: 'repair', enforceLimits: true, settleSeconds: 60, transientWorker: false },
    { phase: 'recover', enforceLimits: true, settleSeconds: 60, transientWorker: false },
  ]);
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
  assert.match(
    memoryBudgetViolations('darwin', {
      ...memory,
      settledPhysFootprintBytes: memory.baselinePhysFootprintBytes + (16 * 1024 * 1024) + 1,
    })[0],
    /settled footprint growth exceeded 16 MiB/,
  );
});

test('Windows budget requires peak below 650 MiB and settled growth at most 150 MiB', () => {
  const memory = {
    peakRssBytes: 649 * 1024 * 1024,
    baselineRssBytes: 100 * 1024 * 1024,
    settledRssBytes: 250 * 1024 * 1024,
  };

  assert.deepEqual(memoryBudgetViolations('win32', memory), []);
  assert.equal(memoryBudgetViolations('win32', {
    ...memory,
    peakRssBytes: 650 * 1024 * 1024,
  }).length, 1);
  assert.equal(memoryBudgetViolations('win32', {
    ...memory,
    settledRssBytes: (250 * 1024 * 1024) + 1,
  }).length, 1);
});

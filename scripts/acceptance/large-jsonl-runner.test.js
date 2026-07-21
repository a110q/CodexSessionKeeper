'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  memoryBudgetViolations,
  realSourcePhasePlan,
  swapGrowthBytes,
  footprintGrowthBytes,
} = require('./large-jsonl-runner');

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

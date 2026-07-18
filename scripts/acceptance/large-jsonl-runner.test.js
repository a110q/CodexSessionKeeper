'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { swapGrowthBytes } = require('./large-jsonl-runner');

test('swap growth is clamped to nonnegative bytes above the startup-ready baseline', () => {
  assert.equal(swapGrowthBytes(6_111_232, 7_274_496), 1_163_264);
  assert.equal(swapGrowthBytes(6_111_232, 6_111_232), 0);
  assert.equal(swapGrowthBytes(6_111_232, 5_000_000), 0);
});

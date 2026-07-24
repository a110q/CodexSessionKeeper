'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  compactedLineLayout,
  descendantProcessIds,
  summarizeProcessMemory,
} = require('../../../../scripts/acceptance/large-jsonl-runner');

test('compacted fixture layout targets the exact Codex line length without materializing it', () => {
  const layout = compactedLineLayout(35_895_162);

  assert.equal(layout.lineBytes, 35_895_162);
  assert.equal(layout.prefix.length + layout.fillBytes + layout.suffix.length, layout.lineBytes);
  const small = compactedLineLayout(512);
  assert.equal(JSON.parse(Buffer.concat([
    small.prefix,
    Buffer.alloc(small.fillBytes, 0x78),
    small.suffix,
  ]).toString('utf8')).type, 'compacted');
});

test('process-tree accounting includes only the guarded root and descendants', () => {
  const rows = [
    { pid: 10, ppid: 1, rssBytes: 10 },
    { pid: 11, ppid: 10, rssBytes: 20 },
    { pid: 12, ppid: 11, rssBytes: 30 },
    { pid: 13, ppid: 1, rssBytes: 999 },
  ];

  assert.deepEqual([...descendantProcessIds(rows, 10)].sort((a, b) => a - b), [10, 11, 12]);
  assert.deepEqual(summarizeProcessMemory(rows, 10), {
    aggregateRssBytes: 60,
    processCount: 3,
  });
});

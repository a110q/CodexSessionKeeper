'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const sourceRoot = path.join(__dirname, '..', '..', 'src');
const policyPath = path.join(sourceRoot, 'jsonl-policy.js');
const consumers = [
  'backup/backup-agent.js',
  'backup/session-tailer.js',
  'backup/session-backup-streamer.js',
  'backup/backup-file-verifier.js',
  'backup/integrity-auditor.js',
  'backup/incremental-recovery.js',
  'backup/recovered-thread-index.js',
  'session-data-security.js',
];

function productionJavaScriptFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return productionJavaScriptFiles(entryPath);
    return entry.isFile() && entry.name.endsWith('.js') ? [entryPath] : [];
  });
}

test('all production JSONL consumers share the dependency-free 64 MiB policy', () => {
  assert.equal(fs.existsSync(policyPath), true, 'shared JSONL policy module must exist');
  const policy = fs.readFileSync(policyPath, 'utf8');
  assert.match(policy, /MAX_JSONL_LINE_BYTES\s*=\s*64\s*\*\s*1024\s*\*\s*1024/);
  assert.doesNotMatch(policy, /require\(['"][^'"]+['"]\)/);

  for (const relativePath of consumers) {
    const source = fs.readFileSync(path.join(sourceRoot, relativePath), 'utf8');
    assert.match(source, /MAX_JSONL_LINE_BYTES/, `${relativePath} must use the shared policy`);
    assert.match(source, /require\(['"][^'"]*jsonl-policy['"]\)/, `${relativePath} must import the shared policy`);
  }

  const production = productionJavaScriptFiles(sourceRoot)
    .filter((filePath) => filePath !== path.join(sourceRoot, 'backup', 'cursor-store.js'))
    .map((filePath) => fs.readFileSync(filePath, 'utf8'))
    .join('\n');
  assert.doesNotMatch(production, /32\s*\*\s*1024\s*\*\s*1024|33554432|32 MiB/);
});

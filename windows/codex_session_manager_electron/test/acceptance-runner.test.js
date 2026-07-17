'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  cleanupOwnedAcceptanceRoot,
  createOwnedAcceptanceRoot,
  median,
  runAcceptance,
  validateCatalogSelection,
  writeSyntheticJsonl,
} = require('../../../scripts/acceptance/p0-windows-runner');

async function temporaryCatalog(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-p0-catalog-'));
  const employeeRoot = path.join(root, '运营部', '测试员工');
  await fs.mkdir(path.join(employeeRoot, 'devices'), { recursive: true });
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return { employeeRoot, root };
}

test('acceptance root is an isolated owned device directory and cleanup verifies its marker', async (t) => {
  const { employeeRoot, root } = await temporaryCatalog(t);
  const selected = await validateCatalogSelection({
    trustedRoot: root,
    department: '运营部',
    employee: '测试员工',
  });
  assert.equal(selected, await fs.realpath(employeeRoot));

  const runId = '11111111-2222-4333-8444-555555555555';
  const acceptanceRoot = await createOwnedAcceptanceRoot({ employeeRoot, runId });
  assert.equal(acceptanceRoot, await fs.realpath(path.join(employeeRoot, 'devices', `p0-acceptance-${runId}`)));
  assert.equal(JSON.parse(await fs.readFile(path.join(acceptanceRoot, 'p0-acceptance-marker.json'), 'utf8')).runId, runId);
  await cleanupOwnedAcceptanceRoot({ acceptanceRoot, runId });
  await assert.rejects(fs.access(acceptanceRoot));
});

test('acceptance root refuses pre-existing directories and cleanup refuses a foreign marker', async (t) => {
  const { employeeRoot } = await temporaryCatalog(t);
  const runId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
  const acceptanceRoot = path.join(employeeRoot, 'devices', `p0-acceptance-${runId}`);
  await fs.mkdir(acceptanceRoot);
  await assert.rejects(
    createOwnedAcceptanceRoot({ employeeRoot, runId }),
    /already exists/i,
  );
  await fs.writeFile(path.join(acceptanceRoot, 'p0-acceptance-marker.json'), JSON.stringify({ runId: 'foreign' }));
  await assert.rejects(
    cleanupOwnedAcceptanceRoot({ acceptanceRoot, runId }),
    /marker/i,
  );
});

test('synthetic JSONL has the requested byte length and contains no real conversation content', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-p0-jsonl-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'fixture.jsonl');
  const byteCount = 2 * 1024 * 1024 + 17;
  await writeSyntheticJsonl({ filePath, byteCount, seed: 'acceptance-fixture' });
  const payload = await fs.readFile(filePath, 'utf8');
  assert.equal(Buffer.byteLength(payload), byteCount);
  assert.ok(payload.endsWith('\n'));
  for (const line of payload.trimEnd().split('\n')) assert.doesNotThrow(() => JSON.parse(line));
  assert.doesNotMatch(payload, /conversation|employee|用户|助手/i);
});

test('quick acceptance uses production backup and recovery modules in an isolated target', async (t) => {
  const { employeeRoot, root } = await temporaryCatalog(t);
  const reportRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-p0-report-'));
  t.after(() => fs.rm(reportRoot, { recursive: true, force: true }));
  const result = await runAcceptance({
    trustedRoot: root,
    department: '运营部',
    employee: '测试员工',
    outputRoot: reportRoot,
    runId: '12345678-1234-4123-8123-123456789abc',
    uploadBytes: 128 * 1024,
    restoreBytes: 5 * 1024 * 1024,
    uploadRuns: 3,
    minimumThroughputMiBPerSecond: 0,
  });
  assert.equal(result.report.automatedPass, true);
  assert.equal(result.report.releaseReady, false);
  assert.equal(result.report.upload.runs.length, 3);
  assert.equal(result.report.restore.hashMatches, true);
  assert.equal(median([9, 1, 5]), 5);
  for (const filename of ['p0-acceptance-report.json', 'resource-samples.csv', 'summary.txt']) {
    await fs.access(path.join(reportRoot, filename));
  }
  assert.equal(
    result.acceptanceRoot,
    await fs.realpath(path.join(employeeRoot, 'devices', 'p0-acceptance-12345678-1234-4123-8123-123456789abc')),
  );
});

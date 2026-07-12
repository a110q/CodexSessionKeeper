'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  COMPANY_NAS,
  createNasService
} = require('../../src/backup/nas-service');

test('detect rejects wrong endpoint identity and missing trusted root', async (t) => {
  const fixture = await makeFixture(t);
  const wrong = fixture.service({ server: '192.168.10.98' });
  await assert.rejects(wrong.detect(), /trusted company NAS|公司 NAS/i);

  await fsp.rm(fixture.trustedRoot, { recursive: true });
  await assert.rejects(fixture.service().detect(), /missing|不存在/i);
});

test('catalog returns canonical direct children and rejects unsafe components and links', async (t) => {
  const fixture = await makeFixture(t);
  await fixture.employee('开发部', '李雷');
  await fixture.employee('运营部', '陈超');
  await fsp.writeFile(path.join(fixture.trustedRoot, '说明.txt'), 'ignore');
  const outside = path.join(fixture.root, 'outside');
  await fsp.mkdir(outside);
  await fsp.symlink(outside, path.join(fixture.trustedRoot, '链接部门'));
  const service = fixture.service();

  assert.deepEqual(await service.departments(), ['开发部', '运营部']);
  assert.deepEqual(await service.employees('运营部'), ['陈超']);
  for (const value of ['', '.', '..', '../运营部', '运营部/陈超', '运营部\\陈超', 'C:\\temp', '\\\\server\\share', 'bad\0name']) {
    await assert.rejects(service.employees(value), /invalid NAS path component/i);
  }
});

test('activation probes cleanly, reuses stable identity, and suffixes marker collisions', async (t) => {
  const fixture = await makeFixture(t);
  const employeeRoot = await fixture.employee('运营部', '陈超');
  const devicesRoot = path.join(employeeRoot, 'devices');
  await fsp.mkdir(devicesRoot);
  const collisionRoot = path.join(devicesRoot, 'Runtime-Mac-11111111');
  await fsp.mkdir(collisionRoot);
  await fsp.writeFile(path.join(collisionRoot, 'device.json'), JSON.stringify({ deviceId: 'foreign' }));
  const service = fixture.service();

  const first = await service.activate({ department: '运营部', employee: '陈超' });
  const second = await service.activate({
    department: '运营部',
    employee: '陈超',
    previous: first.configuration
  });

  assert.equal(first.configuration.deviceId, '11111111-1111-1111-1111-111111111111');
  assert.equal(path.basename(first.deviceRoot), 'Runtime-Mac-11111111-2');
  assert.equal(second.deviceRoot, first.deviceRoot);
  assert.equal(path.basename(first.backupRoot), 'incremental-backups');
  assert.equal((await fsp.readdir(employeeRoot)).some((name) => name.includes('probe')), false);
  assert.equal((await fsp.readdir(first.deviceRoot)).some((name) => name.includes('probe')), false);
});

async function makeFixture(t) {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'nas-service-test-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const shareRoot = path.join(root, '文件中转站');
  const trustedRoot = path.join(shareRoot, COMPANY_NAS.backupRootName);
  await fsp.mkdir(trustedRoot, { recursive: true });
  return {
    root,
    shareRoot,
    trustedRoot,
    async employee(department, employee) {
      const employeeRoot = path.join(trustedRoot, department, employee);
      await fsp.mkdir(employeeRoot, { recursive: true });
      return employeeRoot;
    },
    service(identity = {}) {
      return createNasService({
        fs,
        pathImpl: path,
        endpoint: COMPANY_NAS,
        shareRootResolver: async () => ({
          rootPath: shareRoot,
          server: identity.server || COMPANY_NAS.server,
          share: identity.share || COMPANY_NAS.share
        }),
        randomUUID: () => '11111111-1111-1111-1111-111111111111',
        deviceName: () => 'Runtime Mac',
        now: () => new Date('2026-07-13T00:00:00Z')
      });
    }
  };
}

'use strict';

const crypto = require('node:crypto');
const fsDefault = require('node:fs');
const os = require('node:os');
const pathDefault = require('node:path');

const COMPANY_NAS = Object.freeze({
  server: '192.168.10.99',
  share: '文件中转站',
  backupRootName: 'codex会话备份',
  uncRoot: '\\\\192.168.10.99\\文件中转站'
});

function createNasService({
  fs = fsDefault,
  pathImpl = pathDefault,
  endpoint = COMPANY_NAS,
  shareRootResolver = async () => ({ rootPath: endpoint.uncRoot, server: endpoint.server, share: endpoint.share }),
  randomUUID = crypto.randomUUID,
  deviceName = os.hostname,
  now = () => new Date()
} = {}) {
  const fsp = fs.promises;

  async function detect() {
    const resolved = await shareRootResolver(endpoint);
    const identity = typeof resolved === 'string'
      ? { rootPath: resolved, server: endpoint.server, share: endpoint.share }
      : resolved;
    if (!identity || identity.server !== endpoint.server || identity.share !== endpoint.share) {
      throw new Error('Path is not the trusted company NAS endpoint.');
    }
    const shareRoot = await validateDirectory(identity.rootPath);
    let trustedRoot;
    try {
      trustedRoot = await directDirectory(shareRoot, endpoint.backupRootName);
    } catch (error) {
      throw new Error(`公司 NAS 备份根目录不存在：${error.message}`);
    }
    return Object.freeze({ endpoint, shareRoot, trustedRoot });
  }

  async function departments() {
    const mount = await detect();
    return directDirectoryNames(mount.trustedRoot);
  }

  async function employees(department) {
    const mount = await detect();
    const departmentRoot = await directDirectory(mount.trustedRoot, department);
    return directDirectoryNames(departmentRoot);
  }

  async function activate({ department, employee, previous = null }) {
    const mount = await detect();
    const departmentRoot = await directDirectory(mount.trustedRoot, department);
    const employeeRoot = await directDirectory(departmentRoot, employee);
    await verifyDirectoryWritable(employeeRoot);
    const selectedDeviceId = String(previous?.deviceId || randomUUID()).toLowerCase();
    const selectedDeviceName = previous?.deviceName || deviceName();
    const devicesRoot = await managedDirectory(employeeRoot, 'devices');
    const baseName = previous?.deviceDirectoryName || deviceDirectoryName(selectedDeviceName, selectedDeviceId);
    const deviceRoot = await selectDeviceRoot({
      devicesRoot,
      baseName,
      deviceId: selectedDeviceId,
      selectedDeviceName,
      department,
      employee
    });
    const configuration = Object.freeze({
      version: 1,
      endpoint: { ...endpoint },
      department,
      employee,
      deviceId: selectedDeviceId,
      deviceName: selectedDeviceName,
      deviceDirectoryName: pathImpl.basename(deviceRoot)
    });
    const markerPath = pathImpl.join(deviceRoot, 'device.json');
    if (!fs.existsSync(markerPath)) {
      await writeJsonAtomic(markerPath, {
        ...configuration,
        createdAt: now().toISOString()
      });
    }
    const backupRoot = await managedDirectory(deviceRoot, 'incremental-backups');
    await verifyDirectoryWritable(deviceRoot);
    return Object.freeze({ configuration, employeeRoot, deviceRoot, backupRoot });
  }

  async function resolve(configuration) {
    if (!configuration) throw new Error('NAS configuration is missing.');
    const mount = await detect();
    if (configuration.endpoint
      && (configuration.endpoint.server !== endpoint.server || configuration.endpoint.share !== endpoint.share)) {
      throw new Error('NAS configuration endpoint does not match the company endpoint.');
    }
    const departmentRoot = await directDirectory(mount.trustedRoot, configuration.department);
    const employeeRoot = await directDirectory(departmentRoot, configuration.employee);
    const devicesRoot = await directDirectory(employeeRoot, 'devices');
    const deviceRoot = await directDirectory(devicesRoot, configuration.deviceDirectoryName);
    const marker = await readJson(pathImpl.join(deviceRoot, 'device.json'));
    if (!markerMatches(marker, configuration, configuration.deviceDirectoryName)) {
      throw new Error(`NAS device marker mismatch: ${deviceRoot}`);
    }
    const backupRoot = await directDirectory(deviceRoot, 'incremental-backups');
    return Object.freeze({ configuration: Object.freeze({ ...configuration }), employeeRoot, deviceRoot, backupRoot });
  }

  async function verifyWritable(target) {
    if (!target?.deviceRoot || !target?.backupRoot) {
      throw new Error('NAS target is missing trusted device paths.');
    }
    const deviceRoot = await validateDirectory(target.deviceRoot);
    const backupRoot = await directDirectory(deviceRoot, 'incremental-backups');
    if (!samePath(backupRoot, target.backupRoot)) {
      throw new Error(`NAS backup root changed during write validation: ${target.backupRoot}`);
    }
    await verifyDirectoryWritable(deviceRoot);
  }

  async function recoveryDevices(configuration) {
    if (!configuration) throw new Error('NAS configuration is missing.');
    const mount = await detect();
    if (configuration.endpoint
      && (configuration.endpoint.server !== endpoint.server || configuration.endpoint.share !== endpoint.share)) {
      throw new Error('NAS configuration endpoint does not match the company endpoint.');
    }
    const departmentRoot = await directDirectory(mount.trustedRoot, configuration.department);
    const employeeRoot = await directDirectory(departmentRoot, configuration.employee);
    const devicesRoot = await directDirectory(employeeRoot, 'devices');
    const names = await directDirectoryNames(devicesRoot);
    const devices = [];
    for (const directoryName of names) {
      try {
        const deviceRoot = await directDirectory(devicesRoot, directoryName);
        const marker = await readJson(pathImpl.join(deviceRoot, 'device.json'));
        const deviceConfiguration = {
          version: Number(marker.version || 1),
          endpoint: { ...endpoint },
          department: configuration.department,
          employee: configuration.employee,
          deviceId: String(marker.deviceId || '').toLowerCase(),
          deviceName: String(marker.deviceName || directoryName),
          deviceDirectoryName: directoryName,
        };
        validateDeviceId(deviceConfiguration.deviceId);
        if (!markerMatches(marker, deviceConfiguration, directoryName)) continue;
        const backupRoot = await directDirectory(deviceRoot, 'incremental-backups');
        devices.push(Object.freeze({
          configuration: Object.freeze(deviceConfiguration),
          deviceId: deviceConfiguration.deviceId,
          deviceName: deviceConfiguration.deviceName,
          deviceRoot,
          backupRoot,
        }));
      } catch {
        // Ignore malformed or incomplete device directories in the recovery catalog.
      }
    }
    return Object.freeze(devices.sort((a, b) => a.deviceName.localeCompare(b.deviceName, 'zh-CN')));
  }

  async function resolveDevice(configuration, deviceId) {
    validateDeviceId(deviceId);
    const normalizedId = String(deviceId).toLowerCase();
    const target = (await recoveryDevices(configuration)).find((device) => device.deviceId === normalizedId);
    if (!target) throw new Error(`Unknown NAS backup device: ${deviceId}`);
    return target;
  }

  async function selectDeviceRoot({ devicesRoot, baseName, deviceId, selectedDeviceName, department, employee }) {
    let suffix = 1;
    while (true) {
      const name = suffix === 1 ? baseName : `${baseName}-${suffix}`;
      const candidate = pathImpl.join(devicesRoot, name);
      if (!fs.existsSync(candidate)) return managedDirectory(devicesRoot, name);
      try {
        const existing = await directDirectory(devicesRoot, name);
        const marker = await readJson(pathImpl.join(existing, 'device.json'));
        if (markerMatches(marker, {
          endpoint,
          department,
          employee,
          deviceId,
          deviceName: selectedDeviceName,
          deviceDirectoryName: name
        }, name)) return existing;
      } catch {}
      suffix += 1;
    }
  }

  async function managedDirectory(parent, name) {
    validateComponent(name);
    const candidate = pathImpl.join(parent, name);
    if (!fs.existsSync(candidate)) await fsp.mkdir(candidate, { recursive: false });
    return directDirectory(parent, name);
  }

  async function directDirectory(parent, name) {
    validateComponent(name);
    const parentReal = await validateDirectory(parent);
    const candidate = pathImpl.join(parent, name);
    const childReal = await validateDirectory(candidate);
    if (!samePath(pathImpl.dirname(childReal), parentReal)) {
      throw new Error(`NAS directory is not a canonical direct child: ${candidate}`);
    }
    return childReal;
  }

  async function directDirectoryNames(parent) {
    const entries = await fsp.readdir(parent, { withFileTypes: true });
    const names = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      try {
        await directDirectory(parent, entry.name);
        names.push(entry.name);
      } catch {}
    }
    return names.sort((a, b) => a.localeCompare(b, 'zh-CN'));
  }

  async function validateDirectory(directory) {
    const stat = await fsp.lstat(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`NAS directory is missing or linked: ${directory}`);
    return fsp.realpath(directory);
  }

  function validateComponent(value) {
    if (typeof value !== 'string'
      || value.length === 0
      || value.includes('\0')
      || value === '.'
      || value === '..'
      || value.includes('/')
      || value.includes('\\')
      || /^[A-Za-z]:/.test(value)
      || /^\\\\/.test(value)
      || /^\\\\[?.]\\/.test(value)) {
      throw new Error(`invalid NAS path component: ${String(value)}`);
    }
  }

  function validateDeviceId(value) {
    if (typeof value !== 'string'
      || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)) {
      throw new Error(`Unknown NAS backup device: ${String(value)}`);
    }
  }

  async function verifyDirectoryWritable(directory) {
    const probeRoot = pathImpl.join(directory, `.codex-session-keeper-probe-${randomUUID()}`);
    const source = pathImpl.join(probeRoot, 'write-test');
    const renamed = pathImpl.join(probeRoot, 'rename-test');
    const expected = Buffer.from('codex-session-keeper-nas-probe');
    try {
      await fsp.mkdir(probeRoot, { recursive: false });
      const handle = await fsp.open(source, 'wx');
      try {
        await handle.writeFile(expected);
        await handle.sync();
      } finally {
        await handle.close();
      }
      assertBuffersEqual(await fsp.readFile(source), expected);
      await fsp.rename(source, renamed);
      await fsp.unlink(renamed);
      await fsp.rmdir(probeRoot);
    } finally {
      await fsp.rm(probeRoot, { recursive: true, force: true }).catch(() => {});
    }
  }

  async function writeJsonAtomic(destination, value) {
    const temporary = pathImpl.join(
      pathImpl.dirname(destination),
      `.${pathImpl.basename(destination)}.tmp-${randomUUID()}`
    );
    let handle;
    try {
      handle = await fsp.open(temporary, 'wx');
      await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
      await handle.sync();
      await handle.close();
      handle = null;
      await fsp.rename(temporary, destination);
    } finally {
      if (handle) await handle.close().catch(() => {});
      await fsp.rm(temporary, { force: true }).catch(() => {});
    }
  }

  async function readJson(filePath) {
    return JSON.parse(await fsp.readFile(filePath, 'utf8'));
  }

  function markerMatches(marker, configuration, directoryName) {
    return marker
      && marker.department === configuration.department
      && marker.employee === configuration.employee
      && String(marker.deviceId).toLowerCase() === String(configuration.deviceId).toLowerCase()
      && marker.deviceDirectoryName === directoryName
      && (!marker.endpoint
        || (marker.endpoint.server === endpoint.server && marker.endpoint.share === endpoint.share));
  }

  function samePath(lhs, rhs) {
    const normalize = (value) => {
      const normalized = pathImpl.normalize(value);
      return pathImpl.sep === '\\' ? normalized.toLowerCase() : normalized;
    };
    return normalize(lhs) === normalize(rhs);
  }

  return Object.freeze({
    endpoint,
    detect,
    departments,
    employees,
    activate,
    resolve,
    verifyWritable,
    recoveryDevices,
    resolveDevice,
  });
}

function deviceDirectoryName(name, deviceId) {
  const safe = String(name).replace(/[^\p{L}\p{N}_-]+/gu, '-').replace(/^[-_]+|[-_]+$/g, '') || 'device';
  return `${safe}-${String(deviceId).replace(/-/g, '').slice(0, 8)}`;
}

function assertBuffersEqual(actual, expected) {
  if (!actual.equals(expected)) throw new Error('NAS write probe readback mismatch.');
}

module.exports = { COMPANY_NAS, createNasService };

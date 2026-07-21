const fs = require('node:fs/promises');
const path = require('node:path');

const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

class UpdateStateStore {
  constructor({ vaultRoot, logger = () => {} }) {
    if (typeof vaultRoot !== 'string' || !path.isAbsolute(vaultRoot)) {
      throw new TypeError('UpdateStateStore requires an absolute vaultRoot.');
    }
    this.filePath = path.join(vaultRoot, 'update-state.json');
    this.temporaryPath = `${this.filePath}.tmp-${process.pid}`;
    this.logger = logger;
    this.writeQueue = Promise.resolve();
  }

  async read() {
    let text;
    try {
      text = await fs.readFile(this.filePath, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') {
        this.logger('Windows update state is missing; using an empty state.');
        return { schemaVersion: 1 };
      }
      this.logger(`Windows update state could not be read: ${error.message}`);
      return { schemaVersion: 1 };
    }

    try {
      const value = JSON.parse(text);
      if (!value || typeof value !== 'object' || Array.isArray(value)
          || value.schemaVersion !== 1) {
        throw new Error('invalid schemaVersion');
      }
      const allowed = new Set(['schemaVersion', 'lastCheckAt', 'pendingVersion']);
      if (Object.keys(value).some((key) => !allowed.has(key))) {
        throw new Error('unknown field');
      }
      if (value.lastCheckAt !== undefined
          && (typeof value.lastCheckAt !== 'string'
            || new Date(value.lastCheckAt).toISOString() !== value.lastCheckAt)) {
        throw new Error('invalid lastCheckAt');
      }
      if (value.pendingVersion !== undefined
          && (typeof value.pendingVersion !== 'string' || !VERSION.test(value.pendingVersion))) {
        throw new Error('invalid pendingVersion');
      }
      return value;
    } catch (error) {
      this.logger(`Windows update state is invalid: ${error.message}`);
      return { schemaVersion: 1 };
    }
  }

  write(patch) {
    const operation = () => this.performWrite(patch);
    this.writeQueue = this.writeQueue.then(operation, operation);
    return this.writeQueue;
  }

  async performWrite(patch) {
    const current = await this.read();
    const next = { ...current, schemaVersion: 1 };
    for (const key of ['lastCheckAt', 'pendingVersion']) {
      if (!Object.prototype.hasOwnProperty.call(patch, key)) continue;
      if (patch[key] === null || patch[key] === undefined) delete next[key];
      else next[key] = patch[key];
    }

    if (next.lastCheckAt !== undefined
        && new Date(next.lastCheckAt).toISOString() !== next.lastCheckAt) {
      throw new TypeError('lastCheckAt must be a canonical ISO timestamp.');
    }
    if (next.pendingVersion !== undefined
        && (typeof next.pendingVersion !== 'string' || !VERSION.test(next.pendingVersion))) {
      throw new TypeError('pendingVersion must be X.Y.Z.');
    }

    await fs.mkdir(path.dirname(this.filePath), { recursive: true });
    const handle = await fs.open(this.temporaryPath, 'w', 0o600);
    try {
      await handle.writeFile(`${JSON.stringify(next, null, 2)}\n`, 'utf8');
      await handle.sync();
    } finally {
      await handle.close();
    }
    try {
      await fs.rename(this.temporaryPath, this.filePath);
    } catch (error) {
      await fs.rm(this.temporaryPath, { force: true }).catch(() => {});
      throw error;
    }
    return next;
  }

  async consumeCompletion(currentVersion) {
    const state = await this.read();
    if (state.pendingVersion !== currentVersion) return null;
    await this.write({ pendingVersion: null });
    return { phase: 'completed', version: currentVersion };
  }

  async markPending(version) {
    await this.write({ pendingVersion: version });
  }
}

module.exports = { UpdateStateStore };

'use strict';

const fsDefault = require('node:fs');
const pathDefault = require('node:path');

function createSettingsStore({ filePath, fs = fsDefault, pathImpl = pathDefault }) {
  if (!filePath) throw new Error('settings filePath is required');
  const defaults = Object.freeze({ autoRestoreOnLaunch: false, nasBackup: null });

  function load() {
    if (!fs.existsSync(filePath)) return { ...defaults };
    try {
      return { ...defaults, ...JSON.parse(fs.readFileSync(filePath, 'utf8')) };
    } catch {
      return { ...defaults };
    }
  }

  function savePatch(patch) {
    const next = { ...load(), ...patch };
    const parent = pathImpl.dirname(filePath);
    fs.mkdirSync(parent, { recursive: true });
    const temporary = pathImpl.join(parent, `.${pathImpl.basename(filePath)}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
    let descriptor;
    try {
      descriptor = fs.openSync(temporary, 'wx', 0o600);
      fs.writeFileSync(descriptor, `${JSON.stringify(next, null, 2)}\n`, 'utf8');
      fs.fsyncSync(descriptor);
      fs.closeSync(descriptor);
      descriptor = undefined;
      fs.renameSync(temporary, filePath);
      return next;
    } catch (error) {
      if (descriptor !== undefined) {
        try { fs.closeSync(descriptor); } catch {}
      }
      try { fs.unlinkSync(temporary); } catch {}
      throw error;
    }
  }

  return Object.freeze({ filePath, load, savePatch });
}

module.exports = { createSettingsStore };

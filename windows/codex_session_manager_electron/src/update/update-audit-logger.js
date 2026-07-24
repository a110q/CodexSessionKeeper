const fsp = require('node:fs/promises');
const path = require('node:path');

const TOKEN_PATTERN = /^[A-Za-z0-9._+-]{1,64}$/;

function createUpdateAuditLogger({
  filePath,
  now = () => new Date(),
  platform,
}) {
  if (typeof filePath !== 'string' || !path.isAbsolute(filePath)) {
    throw new TypeError('Update audit path must be absolute.');
  }
  if (typeof now !== 'function' || !TOKEN_PATTERN.test(platform || '')) {
    throw new TypeError('Update audit logger configuration is invalid.');
  }

  return async ({ event, version }) => {
    if (!TOKEN_PATTERN.test(event || '') || !TOKEN_PATTERN.test(version || '')) {
      throw new TypeError('Update audit entry is invalid.');
    }
    const timestamp = now();
    if (!(timestamp instanceof Date) || Number.isNaN(timestamp.getTime())) {
      throw new TypeError('Update audit timestamp is invalid.');
    }
    const entry = {
      schemaVersion: 1,
      timestamp: timestamp.toISOString(),
      platform,
      event,
      version,
    };
    await fsp.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
    await fsp.appendFile(filePath, `${JSON.stringify(entry)}\n`, {
      encoding: 'utf8',
      mode: 0o600,
      flag: 'a',
    });
  };
}

module.exports = {
  createUpdateAuditLogger,
};

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const packageJson = require('../package.json');

async function sha256(filePath) {
  const digest = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(filePath)) digest.update(chunk);
  return digest.digest('hex');
}

async function main() {
  const filename = `codex_session_keeper_windows_${packageJson.version}_internal-test-unsigned.exe`;
  const installerPath = path.resolve(__dirname, '..', '..', '..', 'dist', 'win10-installer', filename);
  const checksumPath = `${installerPath}.sha256`;
  const digest = await sha256(installerPath);
  await fsp.writeFile(checksumPath, `${digest}  ${filename}\n`, 'utf8');
  process.stdout.write(`${checksumPath}\n`);
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${error.stack || error.message || String(error)}\n`);
    process.exitCode = 1;
  });
}

module.exports = { sha256 };

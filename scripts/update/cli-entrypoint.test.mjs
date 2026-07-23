import assert from 'node:assert/strict';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const cliEnvironments = [
  ['default resolution', { ...process.env, NODE_OPTIONS: '' }],
  ['preserved main symlink', {
    ...process.env,
    NODE_OPTIONS: '--preserve-symlinks-main',
  }],
];

function withSymlinkedScripts(run) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'codex-update-cli-'));
  try {
    const linkedDirectory = path.join(root, 'linked-update-scripts');
    symlinkSync(
      scriptDirectory,
      linkedDirectory,
      process.platform === 'win32' ? 'junction' : 'dir',
    );
    run({ linkedDirectory, root });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('download page CLI runs when invoked through a symlinked directory', () => {
  withSymlinkedScripts(({ linkedDirectory, root }) => {
    const stableRoot = path.join(root, 'stable');
    mkdirSync(stableRoot);
    writeFileSync(path.join(stableRoot, 'release.json'), JSON.stringify({
      version: '1.1.0',
      publishedAt: '2026-07-23T03:02:40.941Z',
      notes: ['新增自动更新'],
      platforms: {
        'windows-x64': {
          url: 'windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe',
        },
      },
    }));

    for (const [label, env] of cliEnvironments) {
      const output = path.join(root, `${label.replaceAll(' ', '-')}.html`);
      const result = spawnSync(process.execPath, [
        path.join(linkedDirectory, 'build-download-page.mjs'),
        '--stable-root',
        stableRoot,
        '--output',
        output,
      ], { encoding: 'utf8', env });

      assert.equal(result.status, 0, `${label}: ${result.stderr}`);
      assert.match(readFileSync(output, 'utf8'), /当前版本：1\.1\.0/);
    }
  });
});

test('release verifier CLI reports errors when invoked through a symlinked directory', () => {
  withSymlinkedScripts(({ linkedDirectory, root }) => {
    for (const [label, env] of cliEnvironments) {
      const result = spawnSync(process.execPath, [
        path.join(linkedDirectory, 'verify-release-directory.mjs'),
        '--root',
        path.join(root, 'missing-release'),
      ], { encoding: 'utf8', env });

      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr, /ENOENT|no such file or directory/i);
    }
  });
});

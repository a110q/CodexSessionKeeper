import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const source = () => readFileSync(path.join(root, 'scripts', 'build_app.sh'), 'utf8');
let releaseExecutable;

function buildReleaseExecutable() {
  if (releaseExecutable) {
    return releaseExecutable;
  }
  const build = spawnSync('swift', ['build', '-c', 'release'], {
    cwd: root,
    encoding: 'utf8'
  });
  assert.equal(build.status, 0, build.stderr || build.stdout);
  releaseExecutable = path.join(root, '.build', 'release', 'CodexSessionVault');
  return releaseExecutable;
}

test('macOS build emits versioned arm64 ZIP and DMG files', () => {
  const script = source();
  assert.match(script, /CodexSessionKeeper-\$APP_VERSION-macos-arm64\.zip/);
  assert.match(script, /CodexSessionKeeper-\$APP_VERSION-macos-arm64\.dmg/);
  assert.match(script, /hdiutil create/);
  assert.match(script, /lipo -archs/);
  assert.match(script, /codesign --verify --deep --strict/);
  assert.match(script, /hdiutil verify/);
});

test('packaging stages an Applications link without mutating Applications', () => {
  const script = source();
  assert.match(script, /ln -s \/Applications/);
  assert.doesNotMatch(script, /cp[^\n]+\/Applications\//);
});

test('macOS build can explicitly disable only the nested SwiftPM sandbox', () => {
  const script = source();
  assert.match(script, /DISABLE_SWIFTPM_SANDBOX/);
  assert.match(script, /--disable-sandbox/);
});

test('macOS package declares its company local-network purpose', () => {
  const script = source();
  assert.match(script, /<key>NSLocalNetworkUsageDescription<\/key>/);
  assert.match(script, /用于连接公司局域网更新服务器/);
  assert.match(script, /<key>NSAllowsLocalNetworking<\/key>\s*<true\/>/);
});

test('release executable can resolve frameworks embedded beside the app executable', () => {
  const loadCommands = spawnSync('/usr/bin/otool', ['-l', buildReleaseExecutable()], {
    encoding: 'utf8'
  });
  assert.equal(loadCommands.status, 0, loadCommands.stderr || loadCommands.stdout);
  assert.match(
    loadCommands.stdout,
    /path @executable_path\/\.\.\/Frameworks \(offset \d+\)/,
    'release executable is missing the app-bundle Frameworks LC_RPATH'
  );
});

test('runtime layout verifier accepts the packaged Sparkle framework and executable rpath', () => {
  const temporaryRoot = mkdtempSync(path.join(tmpdir(), 'codex-runtime-layout-test.'));
  const app = path.join(temporaryRoot, 'Fixture.app');
  const executableDirectory = path.join(app, 'Contents', 'MacOS');
  const frameworksDirectory = path.join(app, 'Contents', 'Frameworks');
  mkdirSync(executableDirectory, { recursive: true });
  mkdirSync(frameworksDirectory, { recursive: true });
  copyFileSync(
    buildReleaseExecutable(),
    path.join(executableDirectory, 'CodexSessionVault')
  );
  symlinkSync(
    path.join(
      root,
      '.build',
      'artifacts',
      'sparkle',
      'Sparkle',
      'Sparkle.xcframework',
      'macos-arm64_x86_64',
      'Sparkle.framework'
    ),
    path.join(frameworksDirectory, 'Sparkle.framework')
  );

  try {
    const verification = spawnSync(
      path.join(root, 'scripts', 'verify_macos_runtime_layout.sh'),
      [app],
      { encoding: 'utf8' }
    );
    assert.equal(verification.status, 0, verification.stderr || verification.stdout);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

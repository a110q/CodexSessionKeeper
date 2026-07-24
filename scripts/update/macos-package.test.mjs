import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const source = () => readFileSync(path.join(root, 'scripts', 'build_app.sh'), 'utf8');

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

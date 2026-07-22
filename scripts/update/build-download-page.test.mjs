import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { renderDownloadPage } from './build-download-page.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const publishScriptPath = path.join(testDirectory, 'publish-release.sh');

function manifest(overrides = {}) {
  return {
    schemaVersion: 1,
    channel: 'stable',
    version: '1.1.0',
    build: 10100,
    publishedAt: '2026-07-22T08:00:00Z',
    required: false,
    notes: ['新增自动更新', '修复 <script>alert(1)</script>'],
    platforms: {
      'windows-x64': {
        url: 'windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe',
        size: 104653090,
        sha256: 'a'.repeat(64),
      },
    },
    ...overrides,
  };
}

test('renders the current signed Windows release without executable page script', () => {
  const html = renderDownloadPage(manifest());
  assert.match(html, /当前版本：1\.1\.0/);
  assert.match(html, /发布日期：2026-07-22/);
  assert.match(html, /href="stable\/windows\/CodexSessionKeeper-1\.1\.0-windows-x64-Setup\.exe"/);
  assert.match(html, /修复 &lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.doesNotMatch(html, /<script/i);
});

test('rejects an unsafe or missing Windows artifact', () => {
  assert.throws(
    () => renderDownloadPage(manifest({ platforms: {} })),
    /windows-x64/,
  );
  const unsafe = manifest();
  unsafe.platforms['windows-x64'].url = 'https://attacker.invalid/setup.exe';
  assert.throws(() => renderDownloadPage(unsafe), /artifact URL/);
});

test('publisher exposes release.json before replacing the employee page', () => {
  const source = readFileSync(publishScriptPath, 'utf8');
  const manifestIndex = source.indexOf(
    'publish_metadata "$INCOMING_ROOT/release.json" "$DESTINATION_ROOT/release.json"',
  );
  const pageBuildIndex = source.indexOf('build-download-page.mjs');
  const pagePublishIndex = source.indexOf('publish_metadata "$DOWNLOAD_PAGE" "$SITE_ROOT/index.html"');
  assert.ok(manifestIndex >= 0);
  assert.ok(pageBuildIndex > manifestIndex);
  assert.ok(pagePublishIndex > pageBuildIndex);
});

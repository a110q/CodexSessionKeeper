'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {
  collectGuideImagePaths,
  guideFontPathForPlatform,
  renderGuideHTML,
  validateGuideImageFile,
} = require('../scripts/employee-guide-markdown');

const renderOptions = {
  version: '1.0.14',
  fontURL: 'file:///tmp/guide-cjk.ttf',
};

test('renderer escapes HTML and resolves only guide asset images', () => {
  const html = renderGuideHTML(
    '# 标题\n\n<script>alert(1)</script>\n\n![截图](assets/employee-guide/macos-install.png)',
    renderOptions
  );
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /assets\/employee-guide\/macos-install\.png/);
  assert.match(html, /适用版本 1\.0\.14/);
});

test('renderer rejects external and parent-relative image URLs', () => {
  assert.throws(
    () => renderGuideHTML('![x](https://example.com/x.png)', renderOptions),
    /Unapproved guide image path/
  );
  assert.throws(
    () => renderGuideHTML('![x](..\/secret.png)', renderOptions),
    /Unapproved guide image path/
  );
});

test('renderer supports only closed text fences and a restricted markdown grammar', () => {
  const html = renderGuideHTML(
    '## 小节\n\n1. 第一步\n2. 第二步\n\n```text\n<unsafe>\n```',
    renderOptions
  );
  assert.match(html, /<ol><li>第一步<\/li><li>第二步<\/li><\/ol>/);
  assert.match(html, /&lt;unsafe&gt;/);
  assert.throws(
    () => renderGuideHTML('```text\n未关闭', renderOptions),
    /Unclosed guide code fence/
  );
});

test('collector returns every approved local guide image exactly once', () => {
  const paths = collectGuideImagePaths([
    '![Mac](assets/employee-guide/macos-install.png)',
    '',
    '![Mac repeat](assets/employee-guide/macos-install.png)',
    '![Windows](assets/employee-guide/windows-install.png)',
  ].join('\n'));

  assert.deepEqual(paths, [
    'assets/employee-guide/macos-install.png',
    'assets/employee-guide/windows-install.png',
  ]);
});

test('PDF HTML embeds the explicitly validated Chinese-capable build font', () => {
  const html = renderGuideHTML('# 中文标题', renderOptions);

  assert.match(html, /@font-face \{[^}]*font-family:\s*"GuideCJK"/s);
  assert.match(html, /file:\/\/\/tmp\/guide-cjk\.ttf/);
  assert.match(html, /body \{[^}]*font-family:\s*"GuideCJK"/s);
  assert.doesNotMatch(html, /System\/Library\/Fonts/);
  assert.throws(
    () => renderGuideHTML('# 中文标题', { version: '1.0.14' }),
    /Guide font URL is required/
  );
  assert.throws(
    () => renderGuideHTML('# 中文标题', { version: '1.0.14', fontURL: 'https://example.com/font.ttf' }),
    /Guide font URL must use file:/
  );
});

test('guide PDF build fails closed on unsupported hosts', () => {
  assert.equal(
    guideFontPathForPlatform('darwin'),
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'
  );
  assert.throws(
    () => guideFontPathForPlatform('win32'),
    /supported only on the macOS release host/
  );
  assert.throws(
    () => guideFontPathForPlatform('linux'),
    /supported only on the macOS release host/
  );
});

test('guide image validation rejects an approved-name symbolic link', async () => {
  const docsRoot = path.resolve('/repo/docs');
  const assetsRoot = path.join(docsRoot, 'assets', 'employee-guide');
  const candidate = path.join(assetsRoot, 'macos-install.png');
  const fakeFS = {
    async lstat(target) {
      if (target === assetsRoot) {
        return {
          isDirectory: () => true,
          isSymbolicLink: () => false,
        };
      }
      if (target === candidate) {
        return {
          isFile: () => true,
          isSymbolicLink: () => true,
          size: 128,
        };
      }
      throw new Error(`Unexpected path: ${target}`);
    },
    async realpath(target) {
      return target;
    },
  };

  await assert.rejects(
    validateGuideImageFile({
      docsRoot,
      relativePath: 'assets/employee-guide/macos-install.png',
      fsAPI: fakeFS,
    }),
    /symbolic link/
  );
});

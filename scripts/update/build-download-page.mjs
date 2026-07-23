#!/usr/bin/env node
import { realpathSync } from 'node:fs';
import { lstat, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

function escapeHTML(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

export function renderDownloadPage(manifest) {
  if (!manifest || typeof manifest !== 'object') throw new Error('manifest is required');
  const artifact = manifest.platforms?.['windows-x64'];
  if (!artifact || typeof artifact.url !== 'string') {
    throw new Error('windows-x64 artifact is required');
  }
  if (!/^windows\/CodexSessionKeeper-[0-9]+\.[0-9]+\.[0-9]+-windows-x64-Setup\.exe$/.test(artifact.url)) {
    throw new Error('Windows artifact URL is unsafe');
  }
  const version = escapeHTML(manifest.version);
  const publishedDate = escapeHTML(String(manifest.publishedAt).slice(0, 10));
  const notes = (Array.isArray(manifest.notes) ? manifest.notes : [])
    .map((note) => `        <li>${escapeHTML(note)}</li>`)
    .join('\n');
  const href = escapeHTML(`stable/${artifact.url}`);
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>codex_会话管理下载</title>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f4f0e8; color: #20231f; }
    main { max-width: 680px; margin: 8vh auto; padding: 40px; background: #fff; border: 1px solid #ddd7cb; border-radius: 18px; box-shadow: 0 16px 50px rgba(45, 39, 28, .08); }
    h1 { margin-top: 0; }
    .meta { color: #62675f; line-height: 1.8; }
    li { margin: 8px 0; }
    a { display: inline-block; margin-top: 20px; padding: 12px 18px; border-radius: 10px; background: #1f7a5a; color: #fff; text-decoration: none; font-weight: 650; }
    .hint { margin-top: 24px; color: #62675f; font-size: 14px; }
  </style>
</head>
<body>
  <main>
    <h1>codex_会话管理</h1>
    <p class="meta">当前版本：${version}<br>发布日期：${publishedDate}</p>
    <h2>本次更新</h2>
    <ul>
${notes}
    </ul>
    <a href="${href}" download>下载 Windows 安装包</a>
    <p class="hint">仅供公司局域网使用。首次安装后，软件会自动检查后续版本，并由你确认是否下载和重启更新。</p>
  </main>
</body>
</html>
`;
}

export async function writeDownloadPage(stableRoot, output) {
  if (!path.isAbsolute(stableRoot) || !path.isAbsolute(output)) {
    throw new Error('stable root and output must be absolute paths');
  }
  const metadata = await lstat(stableRoot);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error('stable root must be a regular directory');
  }
  const manifest = JSON.parse(await readFile(path.join(stableRoot, 'release.json'), 'utf8'));
  await writeFile(output, renderDownloadPage(manifest), { flag: 'wx', mode: 0o644 });
}

async function runCLI() {
  const args = process.argv.slice(2);
  if (args.length !== 4 || args[0] !== '--stable-root' || args[2] !== '--output') {
    throw new Error('usage: build-download-page.mjs --stable-root ABS --output ABS');
  }
  await writeDownloadPage(args[1], args[3]);
}

function isMainModule(moduleURL, argumentPath) {
  if (!argumentPath) return false;
  try {
    return pathToFileURL(realpathSync(fileURLToPath(moduleURL))).href
      === pathToFileURL(realpathSync(argumentPath)).href;
  } catch {
    return false;
  }
}

if (isMainModule(import.meta.url, process.argv[1])) {
  runCLI().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

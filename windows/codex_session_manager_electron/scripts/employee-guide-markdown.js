'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

function escapeHTML(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function renderInline(value) {
  return escapeHTML(value)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
}

function approvedImagePath(value) {
  const normalized = String(value || '').replaceAll('\\', '/');
  if (!/^assets\/employee-guide\/[A-Za-z0-9._-]+\.png$/.test(normalized)) {
    throw new Error(`Unapproved guide image path: ${value}`);
  }
  return normalized;
}

function approvedGuideFontURL(value) {
  if (typeof value !== 'string' || !value || value.includes('\0')) {
    throw new Error('Guide font URL is required');
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error('Guide font URL must be a valid file: URL');
  }
  if (parsed.protocol !== 'file:' || parsed.host || parsed.username || parsed.password) {
    throw new Error('Guide font URL must use file: without a remote host');
  }
  return parsed.href;
}

function guideFontPathForPlatform(platform = process.platform) {
  if (platform === 'darwin') {
    return '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
  }
  throw new Error('Employee guide PDF generation is supported only on the macOS release host');
}

async function validateGuideImageFile({ docsRoot, relativePath, fsAPI = fs }) {
  const approved = approvedImagePath(relativePath);
  const assetsRoot = path.resolve(docsRoot, 'assets', 'employee-guide');
  const candidate = path.resolve(docsRoot, approved);
  if (path.dirname(candidate) !== assetsRoot) {
    throw new Error(`Guide image escapes the approved directory: ${relativePath}`);
  }

  const rootStats = await fsAPI.lstat(assetsRoot);
  if (rootStats.isSymbolicLink() || !rootStats.isDirectory()) {
    throw new Error(`Guide image directory must be a real directory: ${assetsRoot}`);
  }
  const stats = await fsAPI.lstat(candidate);
  if (stats.isSymbolicLink()) {
    throw new Error(`Guide image must not be a symbolic link: ${relativePath}`);
  }
  if (!stats.isFile() || stats.size === 0) {
    throw new Error(`Guide image is missing or empty: ${relativePath}`);
  }

  const [canonicalRoot, canonicalCandidate] = await Promise.all([
    fsAPI.realpath(assetsRoot),
    fsAPI.realpath(candidate),
  ]);
  if (path.dirname(canonicalCandidate) !== canonicalRoot) {
    throw new Error(`Guide image escapes the canonical approved directory: ${relativePath}`);
  }
  return canonicalCandidate;
}

function collectGuideImagePaths(markdown) {
  const paths = [];
  const seen = new Set();
  for (const line of String(markdown).replace(/\r\n?/g, '\n').split('\n')) {
    const image = line.match(/^!\[[^\]]*\]\(([^)]+)\)$/);
    if (!image) continue;
    const source = approvedImagePath(image[1]);
    if (!seen.has(source)) {
      seen.add(source);
      paths.push(source);
    }
  }
  return paths;
}

function renderGuideHTML(markdown, { version, fontURL }) {
  const approvedFontURL = approvedGuideFontURL(fontURL);
  const lines = String(markdown).replace(/\r\n?/g, '\n').split('\n');
  const blocks = [];
  let paragraph = [];
  let list = null;
  let fence = null;

  function flushParagraph() {
    if (paragraph.length) blocks.push(`<p>${renderInline(paragraph.join(' '))}</p>`);
    paragraph = [];
  }

  function flushList() {
    if (!list) return;
    const items = list.items.map((item) => `<li>${renderInline(item)}</li>`).join('');
    blocks.push(`<${list.tag}>${items}</${list.tag}>`);
    list = null;
  }

  function flushText() {
    flushParagraph();
    flushList();
  }

  for (const line of lines) {
    if (fence) {
      if (/^```\s*$/.test(line)) {
        blocks.push(`<pre><code>${escapeHTML(fence.join('\n'))}</code></pre>`);
        fence = null;
      } else {
        fence.push(line);
      }
      continue;
    }
    if (/^```(?:text)?\s*$/.test(line)) {
      flushText();
      fence = [];
      continue;
    }
    if (!line.trim()) {
      flushText();
      continue;
    }

    const image = line.match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
    if (image) {
      flushText();
      const source = approvedImagePath(image[2]);
      blocks.push(`<figure><img src="${source}" alt="${escapeHTML(image[1])}"></figure>`);
      continue;
    }

    const heading = line.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      flushText();
      const level = heading[1].length;
      blocks.push(`<h${level}>${renderInline(heading[2])}</h${level}>`);
      continue;
    }

    const ordered = line.match(/^\d+\.\s+(.+)$/);
    const unordered = line.match(/^[-*]\s+(.+)$/);
    const item = ordered || unordered;
    if (item) {
      flushParagraph();
      const tag = ordered ? 'ol' : 'ul';
      if (list && list.tag !== tag) flushList();
      if (!list) list = { tag, items: [] };
      list.items.push(item[1]);
      continue;
    }

    flushList();
    paragraph.push(line.trim());
  }

  if (fence) throw new Error('Unclosed guide code fence');
  flushText();

  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><style>
@page { size: A4; margin: 14mm 15mm 16mm; }
* { box-sizing: border-box; }
  @font-face { font-family: "GuideCJK"; src: url(${JSON.stringify(approvedFontURL)}) format("truetype"); font-style: normal; font-weight: normal; }
body { margin: 0; font-family: "GuideCJK", "Microsoft YaHei", "Segoe UI", sans-serif; font-size: 10.5pt; color: #1f2937; line-height: 1.48; }
h1 { font-size: 23pt; line-height: 1.2; color: #17345f; margin: 0 0 8mm; }
h2 { break-before: page; font-size: 17pt; line-height: 1.25; color: #1d4ed8; margin: 0 0 5mm; }
h2:first-of-type { break-before: auto; }
h3 { break-after: avoid; font-size: 12.5pt; color: #17345f; margin: 5mm 0 2mm; }
p { margin: 0 0 3.5mm; }
ol, ul { margin: 0 0 4mm; padding-left: 7mm; }
li { margin-bottom: 1.5mm; }
p, li { orphans: 3; widows: 3; }
strong { color: #17345f; }
pre { white-space: pre-wrap; padding: 8px 10px; background: #f3f4f6; border-radius: 6px; }
code { padding: 0.3mm 1mm; border-radius: 3px; background: #eef2f7; font-family: ui-monospace, SFMono-Regular, Consolas, "GuideCJK", monospace; font-size: 0.92em; }
figure { margin: 3.5mm 0 4mm; break-inside: avoid; text-align: center; }
img { max-width: 100%; max-height: 66mm; object-fit: contain; border: 0.25mm solid #dbe4ef; border-radius: 3mm; }
.document-version { display: inline-block; margin: 0 0 7mm; padding: 1.5mm 3mm; border-radius: 999px; color: #475569; background: #eef4fb; font-size: 9pt; }
</style></head><body>
<p class="document-version">适用版本 ${escapeHTML(version)}</p>
${blocks.join('\n')}
</body></html>`;
}

module.exports = {
  approvedGuideFontURL,
  approvedImagePath,
  collectGuideImagePaths,
  escapeHTML,
  guideFontPathForPlatform,
  renderGuideHTML,
  validateGuideImageFile,
};

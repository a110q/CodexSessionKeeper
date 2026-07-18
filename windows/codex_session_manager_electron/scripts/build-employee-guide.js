'use strict';

const { app, BrowserWindow } = require('electron');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const {
  collectGuideImagePaths,
  guideFontPathForPlatform,
  renderGuideHTML,
  validateGuideImageFile,
} = require('./employee-guide-markdown');
const packageJSON = require('../package.json');

const root = path.resolve(__dirname, '../../..');
const source = path.join(root, 'docs/员工安装与使用说明.md');
const output = path.join(root, 'dist/Codex会话管理-安装与使用说明.pdf');
const docsRoot = path.join(root, 'docs');

app.disableHardwareAcceleration();

async function buildGuide() {
  let window;
  let temporary;
  let temporaryOutput;
  try {
    const markdown = await fs.readFile(source, 'utf8');
    for (const relativePath of collectGuideImagePaths(markdown)) {
      await validateGuideImageFile({ docsRoot, relativePath });
    }
    const fontPath = guideFontPathForPlatform(process.platform);
    const fontStats = await fs.lstat(fontPath);
    if (fontStats.isSymbolicLink() || !fontStats.isFile() || fontStats.size === 0) {
      throw new Error(`Guide font is missing or unsafe: ${fontPath}`);
    }
    const html = renderGuideHTML(markdown, {
      version: process.env.APP_VERSION || packageJSON.version,
      fontURL: pathToFileURL(fontPath).href,
    });
    await fs.mkdir(path.dirname(output), { recursive: true });
    temporary = path.join(docsRoot, `.employee-guide-${process.pid}-${randomUUID()}.html`);
    const temporaryHandle = await fs.open(temporary, 'wx', 0o600);
    try {
      await temporaryHandle.writeFile(html, 'utf8');
      await temporaryHandle.sync();
    } finally {
      await temporaryHandle.close();
    }
    window = new BrowserWindow({
      show: false,
      webPreferences: {
        sandbox: true,
        nodeIntegration: false,
        contextIsolation: true,
      },
    });
    await window.loadFile(temporary);
    const renderStatus = await window.webContents.executeJavaScript(`
      (async () => {
        await document.fonts.ready;
        const loadedFonts = await document.fonts.load('16px "GuideCJK"', '中文测试');
        return {
          fontLoaded: loadedFonts.length > 0 && document.fonts.check('16px "GuideCJK"', '中文测试'),
          brokenImages: Array.from(document.images)
            .filter((image) => !image.complete || image.naturalWidth === 0)
            .map((image) => image.getAttribute('src')),
        };
      })()
    `);
    if (!renderStatus.fontLoaded) {
      throw new Error(`Guide font failed to render: ${fontPath}`);
    }
    if (renderStatus.brokenImages.length > 0) {
      throw new Error(`Guide images failed to render: ${renderStatus.brokenImages.join(', ')}`);
    }
    const pdf = await window.webContents.printToPDF({
      pageSize: 'A4',
      preferCSSPageSize: true,
      printBackground: true,
      displayHeaderFooter: true,
      headerTemplate: '<span></span>',
      footerTemplate: '<div style="width:100%;font-size:8px;color:#64748b;text-align:center;"><span class="pageNumber"></span> / <span class="totalPages"></span></div>',
      margins: { top: 0, bottom: 0, left: 0, right: 0 },
    });
    temporaryOutput = `${output}.${process.pid}.${randomUUID()}.tmp`;
    await fs.writeFile(temporaryOutput, pdf, { mode: 0o600 });
    await fs.rename(temporaryOutput, output);
    temporaryOutput = undefined;
    await fs.chmod(output, 0o600);
  } finally {
    if (window && !window.isDestroyed()) window.destroy();
    if (temporary) await fs.rm(temporary, { force: true });
    if (temporaryOutput) await fs.rm(temporaryOutput, { force: true });
  }
}

app.whenReady()
  .then(buildGuide)
  .then(() => app.quit())
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });

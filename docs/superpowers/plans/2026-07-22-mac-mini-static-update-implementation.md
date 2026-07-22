# Mac mini Static Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the signed company-LAN update service from the old NAS endpoint to a fixed Mac mini endpoint at `http://192.168.10.54:18080/codex-session-keeper/stable/`, add a first-install download page, and prove `1.0.99 -> 1.1.0` Windows updating end to end.

**Architecture:** `Config/UpdateServer.json` is the repository source of truth for the fixed release root. Packaged clients embed that value and continue using the existing signed-manifest, employee-confirmed download, hash verification, backup drain, and restart-install state machines. A native Nginx LaunchDaemon on the always-on Mac mini serves `/Users/Shared/codex-update-site` read-only to private LAN ranges; the atomic publisher exposes `release.json` last and then updates the first-install page.

**Tech Stack:** Swift 6 and Sparkle 2.9.4 on macOS 14+; Electron 43.1.0, electron-updater 6.8.9, Node.js 24, PowerShell 5.1, and NSIS on Windows x64; Node ESM release tools; Bash; Homebrew Nginx; launchd.

## Global Constraints

- The fixed release root is exactly `http://192.168.10.54:18080/codex-session-keeper/stable/`.
- The Windows feed is exactly `http://192.168.10.54:18080/codex-session-keeper/stable/windows/`.
- The macOS feed is exactly `http://192.168.10.54:18080/codex-session-keeper/stable/macos/appcast.xml`.
- The server binds only `192.168.10.54:18080`, has no public port forwarding, and permits RFC 1918 sources only: `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`.
- Employees cannot configure an update URL, and no renderer IPC accepts a URL, path, version, channel, command, or options object.
- Keep `autoDownload = false`, `autoInstallOnAppQuit = false`, and `allowDowngrade = false`.
- Automatic connection failures remain silent; manual connection failures remain visible and non-blocking.
- `release.json` is the last update metadata file published; `index.html` changes only after that publication succeeds.
- Nginx workers can read but cannot write `/Users/Shared/codex-update-site`; publishing requires an administrator account.
- Do not modify the green UGREEN NAS, its Docker configuration, or the SMB incremental-backup endpoint at `192.168.10.99`.
- Historical design/plan files under `docs/superpowers/` remain unchanged even though they document the superseded NAS update architecture.
- Any command that installs Nginx, writes `/Users/Shared`, installs a LaunchDaemon, publishes a release, or runs a Setup EXE requires a fresh explicit user approval immediately before execution.

---

## File Map

### Create

- `Config/UpdateServer.json` — single repository source for the fixed release root.
- `scripts/update/update-server.mjs` — validates and derives release/feed URLs for Node release tools.
- `scripts/update/update-server.test.mjs` — validates the fixed configuration and rejects unsafe variants.
- `scripts/update/build-download-page.mjs` — renders the first-install page from the verified signed manifest.
- `scripts/update/build-download-page.test.mjs` — checks links, escaping, and invalid-manifest rejection.
- `scripts/update/mac-mini-deployment.test.mjs` — checks the Nginx and installer safety invariants.
- `deploy/mac-mini/nginx.conf` — native Nginx configuration bound to `192.168.10.54:18080`.
- `deploy/mac-mini/install-static-update-server.sh` — guarded Homebrew/launchd installer for the target Mac mini.
- `release-notes/1.1.0.json` — exact signed release notes used by both clients and the download page.
- `docs/Mac-mini内网更新部署与发布.md` — administrator runbook for build, deployment, publication, and recovery.

### Modify

- `scripts/update/build-release-manifest.mjs` — derive the Sparkle download prefix from shared configuration.
- `scripts/update/verify-release-directory.mjs` — verify appcast URLs against shared configuration.
- `scripts/update/release-manifest.test.mjs` — generate fixture appcasts with the configured prefix.
- `scripts/update/publish-release.sh` — remove NAS wording and publish the generated download page after `release.json`.
- `scripts/build_app.sh` — embed the fixed configured URL and remove the environment override.
- `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift` — require the packaged URL rather than retaining the old NAS fallback.
- `Tests/CodexSessionVaultCoreTests/UpdateCheckClientTests.swift` — use a neutral test-only URL.
- `windows/codex_session_manager_electron/src/update/update-service.js` — require the fixed release root and derive the Windows feed.
- `windows/codex_session_manager_electron/src/main.js` — load bundled `UpdateServer.json` and pass it into `UpdateService`.
- `windows/codex_session_manager_electron/package.json` — embed the Mac mini feed and bundle `UpdateServer.json`.
- `windows/codex_session_manager_electron/test/update/update-service.test.js` — exercise the configured Mac mini endpoint.
- `windows/codex_session_manager_electron/test/build/windows-installer-script.test.js` — enforce config/feed consistency in the package.
- `README.md` — point administrators to the Mac mini runbook.
- `docs/操作手册.md` — replace NAS update-service instructions with Mac mini instructions.

### Delete

- `deploy/nas/docker-compose.yml` — superseded update-service deployment; unrelated NAS backup code remains.
- `deploy/nas/nginx.conf` — superseded container Nginx configuration.
- `docs/NAS内网更新部署与发布.md` — superseded by the Mac mini runbook.

---

### Task 1: Add one validated update-server configuration for release tooling

**Files:**
- Create: `Config/UpdateServer.json`
- Create: `scripts/update/update-server.mjs`
- Create: `scripts/update/update-server.test.mjs`
- Modify: `scripts/update/build-release-manifest.mjs:18-30`
- Modify: `scripts/update/verify-release-directory.mjs:8-17`
- Modify: `scripts/update/release-manifest.test.mjs:190-205`

**Interfaces:**
- Consumes: a JSON object with `releaseBaseURL: string`.
- Produces: `parseUpdateServerConfig(value)` and immutable `UPDATE_SERVER` with `releaseBaseURL`, `windowsFeedURL`, `macDownloadPrefix`, and `macAppcastURL` strings.

- [ ] **Step 1: Write the failing configuration tests**

Create `scripts/update/update-server.test.mjs`:

```javascript
import assert from 'node:assert/strict';
import test from 'node:test';

import { parseUpdateServerConfig, UPDATE_SERVER } from './update-server.mjs';

const RELEASE_BASE = 'http://192.168.10.54:18080/codex-session-keeper/stable/';

test('repository update server is the fixed Mac mini endpoint', () => {
  assert.deepEqual(UPDATE_SERVER, {
    releaseBaseURL: RELEASE_BASE,
    windowsFeedURL: `${RELEASE_BASE}windows/`,
    macDownloadPrefix: `${RELEASE_BASE}macos/`,
    macAppcastURL: `${RELEASE_BASE}macos/appcast.xml`,
  });
});

test('update server parser rejects mutable or ambiguous URLs', () => {
  for (const releaseBaseURL of [
    'ftp://192.168.10.54:18080/codex-session-keeper/stable/',
    'http://user:pass@192.168.10.54:18080/codex-session-keeper/stable/',
    'http://192.168.10.54:18080/codex-session-keeper/stable/?channel=beta',
    'http://192.168.10.54:18080/codex-session-keeper/stable/#latest',
    'http://192.168.10.54:18080/other/stable/',
    'http://192.168.10.54:18080/codex-session-keeper/stable',
  ]) {
    assert.throws(
      () => parseUpdateServerConfig({ releaseBaseURL }),
      /releaseBaseURL/,
      releaseBaseURL,
    );
  }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
node --test scripts/update/update-server.test.mjs
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `scripts/update/update-server.mjs`.

- [ ] **Step 3: Add the configuration and parser**

Create `Config/UpdateServer.json`:

```json
{
  "releaseBaseURL": "http://192.168.10.54:18080/codex-session-keeper/stable/"
}
```

Create `scripts/update/update-server.mjs`:

```javascript
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.resolve(MODULE_DIRECTORY, '..', '..', 'Config', 'UpdateServer.json');

export function parseUpdateServerConfig(value) {
  if (!value || typeof value !== 'object' || typeof value.releaseBaseURL !== 'string') {
    throw new Error('releaseBaseURL must be a string');
  }
  const raw = value.releaseBaseURL;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error('releaseBaseURL must be an absolute URL');
  }
  if (!['http:', 'https:'].includes(url.protocol)
      || url.username || url.password || url.search || url.hash
      || url.pathname !== '/codex-session-keeper/stable/'
      || url.href !== raw) {
    throw new Error('releaseBaseURL must be a canonical HTTP(S) stable-root URL');
  }
  return Object.freeze({
    releaseBaseURL: url.href,
    windowsFeedURL: new URL('windows/', url).href,
    macDownloadPrefix: new URL('macos/', url).href,
    macAppcastURL: new URL('macos/appcast.xml', url).href,
  });
}

export const UPDATE_SERVER = parseUpdateServerConfig(
  JSON.parse(readFileSync(CONFIG_PATH, 'utf8')),
);
```

- [ ] **Step 4: Replace duplicated Node release-tool prefixes**

In both `build-release-manifest.mjs` and `verify-release-directory.mjs`, import:

```javascript
import { UPDATE_SERVER } from './update-server.mjs';
```

Delete each hard-coded `MAC_DOWNLOAD_PREFIX` and replace its uses with:

```javascript
UPDATE_SERVER.macDownloadPrefix
```

In `release-manifest.test.mjs`, import the same object and build fixture enclosure URLs with:

```javascript
`${UPDATE_SERVER.macDownloadPrefix}${zipName}`
```

- [ ] **Step 5: Run the focused and complete release-tool tests**

Run:

```bash
node --test scripts/update/update-server.test.mjs
node --test scripts/update/*.test.mjs
```

Expected: both commands PASS with zero failed tests.

- [ ] **Step 6: Commit Task 1**

```bash
git add Config/UpdateServer.json scripts/update/update-server.mjs scripts/update/update-server.test.mjs scripts/update/build-release-manifest.mjs scripts/update/verify-release-directory.mjs scripts/update/release-manifest.test.mjs
git commit -m "refactor: centralize the internal update endpoint"
```

---

### Task 2: Make the Windows package consume the fixed Mac mini endpoint

**Files:**
- Modify: `windows/codex_session_manager_electron/src/update/update-service.js:6-42`
- Modify: `windows/codex_session_manager_electron/src/main.js:150-225`
- Modify: `windows/codex_session_manager_electron/package.json:39-70`
- Modify: `windows/codex_session_manager_electron/test/update/update-service.test.js:1-95`
- Modify: `windows/codex_session_manager_electron/test/build/windows-installer-script.test.js:1-90`

**Interfaces:**
- Consumes: bundled `UpdateServer.json` containing `releaseBaseURL`.
- Produces: `UpdateService({ releaseBaseURL })`; the service derives the only permitted Windows feed as `new URL('windows/', releaseBaseURL)`.

- [ ] **Step 1: Write failing Windows configuration tests**

At the top of `windows-installer-script.test.js`, add:

```javascript
const repositoryRoot = path.join(appRoot, '..', '..');
const updateServerPath = path.join(repositoryRoot, 'Config', 'UpdateServer.json');
```

Add this test:

```javascript
test('Windows package embeds the fixed configured update server', () => {
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  const updateServer = JSON.parse(fs.readFileSync(updateServerPath, 'utf8'));
  const expectedFeed = new URL('windows/', updateServer.releaseBaseURL).href;

  assert.equal(
    updateServer.releaseBaseURL,
    'http://192.168.10.54:18080/codex-session-keeper/stable/'
  );
  assert.deepEqual(packageJson.build.publish, [{ provider: 'generic', url: expectedFeed }]);
  assert.ok(packageJson.build.extraResources.some((entry) =>
    entry.from === '../../Config/UpdateServer.json' && entry.to === 'UpdateServer.json'
  ));
});
```

In `update-service.test.js`, load the repository configuration and stop injecting a separately maintained Windows URL:

```javascript
const updateServer = require('../../../../Config/UpdateServer.json');
const RELEASE_BASE = updateServer.releaseBaseURL;
const WINDOWS_FEED = new URL('windows/', RELEASE_BASE).href;
```

Change `makeService()` to pass only:

```javascript
releaseBaseURL: RELEASE_BASE,
```

Delete its `windowsFeedURL` argument. Add:

```javascript
test('derives the only Windows feed from the fixed release root', async () => {
  const setup = makeService();
  await setup.service.check({ manual: true });
  await setup.service.download();
  assert.deepEqual(setup.updater.feedURL, {
    provider: 'generic',
    url: 'http://192.168.10.54:18080/codex-session-keeper/stable/windows/',
  });
});
```

- [ ] **Step 2: Run the Windows tests to verify the package test fails**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/update/update-service.test.js test/build/windows-installer-script.test.js
```

Expected: FAIL because `package.json` still points at `192.168.10.99` and does not bundle `UpdateServer.json`.

- [ ] **Step 3: Require and derive the feed in `UpdateService`**

Delete the module-level `RELEASE_BASE_URL` and `WINDOWS_FEED_URL`. Change the constructor parameters to require `releaseBaseURL` and remove `windowsFeedURL`:

```javascript
constructor({
  autoUpdater,
  backupAgent,
  currentBuild,
  currentVersion,
  fetchImpl = globalThis.fetch,
  now = () => new Date(),
  publicKeyBase64,
  releaseBaseURL,
  sendState = () => {},
  stateStore,
  timeoutMs = 5000,
}) {
```

After the existing type checks, add:

```javascript
if (typeof releaseBaseURL !== 'string') {
  throw new TypeError('UpdateService requires releaseBaseURL.');
}
const parsedReleaseBaseURL = new URL(releaseBaseURL);
if (parsedReleaseBaseURL.pathname !== '/codex-session-keeper/stable/'
    || parsedReleaseBaseURL.search || parsedReleaseBaseURL.hash
    || parsedReleaseBaseURL.username || parsedReleaseBaseURL.password) {
  throw new TypeError('releaseBaseURL must be the canonical stable root.');
}
this.releaseBaseURL = parsedReleaseBaseURL.href;
this.windowsFeedURL = new URL('windows/', parsedReleaseBaseURL).href;
```

Remove the old assignments that independently construct both URLs. Keep all existing manifest verification, feed containment, progress, installer hashing, backup drain, and install behavior unchanged.

- [ ] **Step 4: Load bundled configuration in `main.js`**

Inside `createUpdateService()`, resolve both resources using the same packaged/development rule:

```javascript
const configRoot = app.isPackaged
  ? process.resourcesPath
  : path.join(__dirname, '..', '..', '..', 'Config');
const keysPath = path.join(configRoot, 'UpdateKeys.json');
const updateServerPath = path.join(configRoot, 'UpdateServer.json');
const updateServer = JSON.parse(fs.readFileSync(updateServerPath, 'utf8'));
const releaseBaseURL = new URL(String(updateServer.releaseBaseURL || ''));
if (releaseBaseURL.protocol !== 'http:'
    || releaseBaseURL.href !== 'http://192.168.10.54:18080/codex-session-keeper/stable/') {
  throw new Error('UpdateServer.json does not contain the approved releaseBaseURL');
}
```

Pass it into the service:

```javascript
releaseBaseURL: releaseBaseURL.href,
```

Change the startup configuration error copy to:

```javascript
dialog.showErrorBox(
  '更新功能配置错误',
  '更新服务器、公钥或版本信息无效，请联系管理员。',
);
```

Keep the renderer boundary unchanged: no IPC argument may provide an update URL.

- [ ] **Step 5: Bundle the configuration and set Electron Builder feed**

In `package.json`, add to `extraResources`:

```json
{
  "from": "../../Config/UpdateServer.json",
  "to": "UpdateServer.json"
}
```

Replace the generic publisher with:

```json
"publish": [
  {
    "provider": "generic",
    "url": "http://192.168.10.54:18080/codex-session-keeper/stable/windows/"
  }
]
```

- [ ] **Step 6: Run focused and full Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/update/update-service.test.js test/build/windows-installer-script.test.js
npm test
```

Expected: focused tests PASS; the full suite reports zero failures.

- [ ] **Step 7: Commit Task 2**

```bash
git add windows/codex_session_manager_electron/src/update/update-service.js windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/test/update/update-service.test.js windows/codex_session_manager_electron/test/build/windows-installer-script.test.js
git commit -m "feat: point Windows updates at the Mac mini"
```

---

### Task 3: Embed the same fixed endpoint in macOS builds

**Files:**
- Modify: `scripts/build_app.sh:4-25`
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift:8-58`
- Modify: `Tests/CodexSessionVaultCoreTests/UpdateCheckClientTests.swift:6-14`
- Modify: `scripts/update/update-server.test.mjs`

**Interfaces:**
- Consumes: `Config/UpdateServer.json.releaseBaseURL` during packaging and `CSKUpdateBaseURL` from the packaged `Info.plist` at runtime.
- Produces: packaged `CSKUpdateBaseURL` and `SUFeedURL`; no runtime fallback to the old NAS.

- [ ] **Step 1: Add failing source-of-truth assertions**

Add the `node:fs`, `node:path`, and `node:url` imports beside the existing imports at the top of `update-server.test.mjs`, then append the constants and test:

```javascript
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '..', '..');

test('macOS packaging reads UpdateServer.json and retains no NAS fallback', () => {
  const buildScript = readFileSync(path.join(repositoryRoot, 'scripts', 'build_app.sh'), 'utf8');
  const coordinator = readFileSync(
    path.join(repositoryRoot, 'Sources', 'CodexSessionVault', 'Update', 'MacUpdateCoordinator.swift'),
    'utf8',
  );

  assert.match(buildScript, /Config\/UpdateServer\.json/);
  assert.doesNotMatch(buildScript, /UPDATE_BASE_URL:-/);
  assert.doesNotMatch(buildScript, /192\.168\.10\.99/);
  assert.doesNotMatch(coordinator, /fallbackBaseURL/);
  assert.doesNotMatch(coordinator, /192\.168\.10\.99/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
node --test scripts/update/update-server.test.mjs
```

Expected: FAIL on the old `UPDATE_BASE_URL` default and `fallbackBaseURL`.

- [ ] **Step 3: Read the fixed config in `build_app.sh`**

Replace the environment default with:

```bash
UPDATE_SERVER_CONFIG="$ROOT_DIR/Config/UpdateServer.json"
UPDATE_KEYS="$ROOT_DIR/Config/UpdateKeys.json"
[[ -f "$UPDATE_SERVER_CONFIG" ]] || { echo "missing update server config: $UPDATE_SERVER_CONFIG" >&2; exit 2; }
[[ -f "$UPDATE_KEYS" ]] || { echo "missing update keys: $UPDATE_KEYS" >&2; exit 2; }

SERVER_PLIST="$(mktemp "${TMPDIR:-/tmp}/codex-update-server.XXXXXX.plist")"
KEYS_PLIST="$(mktemp "${TMPDIR:-/tmp}/codex-update-keys.XXXXXX.plist")"
trap 'rm -f "$SERVER_PLIST" "$KEYS_PLIST"' EXIT
/usr/bin/plutil -convert xml1 -o "$SERVER_PLIST" "$UPDATE_SERVER_CONFIG"
/usr/bin/plutil -convert xml1 -o "$KEYS_PLIST" "$UPDATE_KEYS"
UPDATE_BASE_URL="$(/usr/libexec/PlistBuddy -c 'Print :releaseBaseURL' "$SERVER_PLIST")"
[[ "$UPDATE_BASE_URL" == "http://192.168.10.54:18080/codex-session-keeper/stable/" ]] || {
  echo "unexpected fixed update server: $UPDATE_BASE_URL" >&2
  exit 2
}
```

Remove the earlier single-file `KEYS_PLIST` setup and the environment override. Keep writing `CSKUpdateBaseURL` and `${UPDATE_BASE_URL}macos/appcast.xml` into `Info.plist`.

- [ ] **Step 4: Remove the runtime NAS fallback**

Delete `fallbackBaseURL` from `MacUpdateCoordinator`. Replace base URL selection with:

```swift
let baseURL = (bundle.object(forInfoDictionaryKey: "CSKUpdateBaseURL") as? String)
    .flatMap(URL.init(string:))
```

Construct `UpdateCheckClient` only when both the URL and public key are valid:

```swift
if let baseURL,
   let encodedKey = bundle.object(forInfoDictionaryKey: "CSKManifestPublicKey") as? String,
   let publicKey = Data(base64Encoded: encodedKey),
   publicKey.count == 32 {
    self.checkClient = UpdateCheckClient(
        baseURL: baseURL,
        publicKey: publicKey,
        transport: URLSessionUpdateTransport(timeout: 5),
        timeout: .seconds(5)
    )
} else {
    self.checkClient = nil
}
```

In `UpdateCheckClientTests.swift`, use a fixture-only origin so tests do not duplicate production configuration:

```swift
private let baseURL = URL(string: "http://updates.test/codex-session-keeper/stable/")!
```

- [ ] **Step 5: Run Node and Swift tests**

Run:

```bash
node --test scripts/update/update-server.test.mjs
swift test
```

Expected: both PASS with zero failures.

- [ ] **Step 6: Commit Task 3**

```bash
git add scripts/build_app.sh Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift Tests/CodexSessionVaultCoreTests/UpdateCheckClientTests.swift scripts/update/update-server.test.mjs
git commit -m "feat: embed the Mac mini endpoint in macOS builds"
```

---

### Task 4: Generate and atomically publish the employee download page

**Files:**
- Create: `scripts/update/build-download-page.mjs`
- Create: `scripts/update/build-download-page.test.mjs`
- Modify: `scripts/update/publish-release.sh:1-220`

**Interfaces:**
- Consumes: a verified stable directory with canonical `release.json` and a `windows-x64` artifact.
- Produces: `renderDownloadPage(manifest): string` and CLI `build-download-page.mjs --stable-root ABS --output ABS`.

- [ ] **Step 1: Write failing download-page tests**

Create `scripts/update/build-download-page.test.mjs`:

```javascript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
node --test scripts/update/build-download-page.test.mjs
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND`.

- [ ] **Step 3: Implement the static page generator**

Create `scripts/update/build-download-page.mjs`:

```javascript
#!/usr/bin/env node
import { lstat, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

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

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runCLI().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
```

- [ ] **Step 4: Integrate the page after `release.json` publication**

In `publish-release.sh`:

- Change usage text to `usage: $0 /absolute/verified/stable/root /absolute/site/codex-session-keeper/stable`.
- Remove the word `nas` from variable names and messages.
- After `publish_metadata ... release.json`, add:

```bash
SITE_ROOT="$(dirname "$DESTINATION_ROOT")"
DOWNLOAD_PAGE="$INCOMING_ROOT/index.html"
node "$SCRIPT_DIR/build-download-page.mjs" \
  --stable-root "$DESTINATION_ROOT" \
  --output "$DOWNLOAD_PAGE"
fsync_file "$DOWNLOAD_PAGE"
publish_metadata "$DOWNLOAD_PAGE" "$SITE_ROOT/index.html"
```

Do not move these lines before the `release.json` publication.

- [ ] **Step 5: Run page, release, and shell syntax tests**

Run:

```bash
node --test scripts/update/build-download-page.test.mjs
node --test scripts/update/*.test.mjs
bash -n scripts/update/publish-release.sh
```

Expected: every test PASS; Bash syntax exits `0`.

- [ ] **Step 6: Commit Task 4**

```bash
git add scripts/update/build-download-page.mjs scripts/update/build-download-page.test.mjs scripts/update/publish-release.sh
git commit -m "feat: publish the employee download page"
```

---

### Task 5: Add the guarded native Nginx deployment bundle

**Files:**
- Create: `deploy/mac-mini/nginx.conf`
- Create: `deploy/mac-mini/install-static-update-server.sh`
- Create: `scripts/update/mac-mini-deployment.test.mjs`

**Interfaces:**
- Consumes: target Mac mini address `192.168.10.54`, Homebrew at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`, and an administrator password entered interactively by the user.
- Produces: LaunchDaemon `com.company.codex-update-server`, site root `/Users/Shared/codex-update-site`, and listener `192.168.10.54:18080`.

- [ ] **Step 1: Write failing deployment-invariant tests**

Create `scripts/update/mac-mini-deployment.test.mjs`:

```javascript
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const nginx = () => readFileSync(path.join(root, 'deploy', 'mac-mini', 'nginx.conf'), 'utf8');
const installer = () => readFileSync(
  path.join(root, 'deploy', 'mac-mini', 'install-static-update-server.sh'),
  'utf8',
);

test('Nginx is fixed to the Mac mini, private ranges, and read-only HTTP methods', () => {
  const source = nginx();
  assert.match(source, /listen 192\.168\.10\.54:18080;/);
  assert.match(source, /root \/Users\/Shared\/codex-update-site;/);
  assert.match(source, /allow 10\.0\.0\.0\/8;/);
  assert.match(source, /allow 172\.16\.0\.0\/12;/);
  assert.match(source, /allow 192\.168\.0\.0\/16;/);
  assert.match(source, /deny all;/);
  assert.match(source, /\$request_method !~ \^\(GET\|HEAD\)\$/);
  assert.match(source, /return 405;/);
  assert.match(source, /autoindex off;/);
  assert.match(source, /Cache-Control "no-cache"/);
  assert.match(source, /max-age=31536000, immutable/);
});

test('installer refuses the wrong host and installs a root launch daemon', () => {
  const source = installer();
  assert.match(source, /EXPECTED_IP="192\.168\.10\.54"/);
  assert.match(source, /\/sbin\/ifconfig/);
  assert.match(source, /com\.company\.codex-update-server/);
  assert.match(source, /\/Library\/LaunchDaemons/);
  assert.match(source, /UserName.*root/);
  assert.match(source, /ProgramArguments/);
  assert.match(source, /daemon off;/);
  assert.doesNotMatch(source, /docker/i);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
node --test scripts/update/mac-mini-deployment.test.mjs
```

Expected: FAIL with `ENOENT` for `deploy/mac-mini/nginx.conf`.

- [ ] **Step 3: Add the native Nginx configuration**

Create `deploy/mac-mini/nginx.conf`:

```nginx
user _www;
worker_processes auto;
error_log /var/log/codex-update-nginx-error.log warn;
pid /var/run/codex-update-nginx.pid;

events {
    worker_connections 256;
}

http {
    default_type application/octet-stream;
    types {
        text/html html;
        application/json json;
        application/xml xml;
        application/octet-stream sig yml zip exe;
    }
    access_log /var/log/codex-update-nginx-access.log;
    sendfile on;
    etag on;
    server_tokens off;

    server {
        listen 192.168.10.54:18080;
        server_name _;
        root /Users/Shared/codex-update-site;
        index index.html;
        autoindex off;
        client_max_body_size 1k;

        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        deny all;

        if ($request_method !~ ^(GET|HEAD)$) {
            return 405;
        }

        location ~ /\. {
            return 404;
        }

        location ~* \.(json|sig|xml|yml)$ {
            add_header Cache-Control "no-cache" always;
            add_header X-Content-Type-Options "nosniff" always;
            try_files $uri =404;
        }

        location ~* \.(zip|exe)$ {
            add_header Cache-Control "public, max-age=31536000, immutable" always;
            add_header X-Content-Type-Options "nosniff" always;
            try_files $uri =404;
        }

        location / {
            add_header X-Content-Type-Options "nosniff" always;
            try_files $uri $uri/ =404;
        }
    }
}
```

- [ ] **Step 4: Add the guarded installer**

Create `deploy/mac-mini/install-static-update-server.sh` with this complete behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail

EXPECTED_IP="192.168.10.54"
LABEL="com.company.codex-update-server"
SITE_ROOT="/Users/Shared/codex-update-site"
CONFIG_DEST="/usr/local/etc/codex-update-nginx.conf"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

/sbin/ifconfig | /usr/bin/awk '/inet / { print $2 }' | /usr/bin/grep -Fxq "$EXPECTED_IP" || {
  echo "refusing deployment: this Mac does not own $EXPECTED_IP" >&2
  exit 2
}

BREW_BIN=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [[ -x "$candidate" ]]; then
    BREW_BIN="$candidate"
    break
  fi
done
[[ -n "$BREW_BIN" ]] || {
  echo "Homebrew is required; install it from the company-approved source first" >&2
  exit 2
}

if ! "$BREW_BIN" list --versions nginx >/dev/null 2>&1; then
  "$BREW_BIN" install nginx
fi
NGINX_BIN="$("$BREW_BIN" --prefix nginx)/bin/nginx"
[[ -x "$NGINX_BIN" ]] || { echo "nginx binary is missing" >&2; exit 2; }

if /usr/sbin/lsof -nP -iTCP@"$EXPECTED_IP":18080 -sTCP:LISTEN | /usr/bin/grep -q .; then
  if ! sudo /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "port 18080 is already owned by another process" >&2
    exit 2
  fi
fi

sudo /usr/bin/install -d -o root -g admin -m 0775 \
  "$SITE_ROOT" \
  "$SITE_ROOT/codex-session-keeper" \
  "$SITE_ROOT/codex-session-keeper/stable" \
  "$SITE_ROOT/codex-session-keeper/stable/macos" \
  "$SITE_ROOT/codex-session-keeper/stable/windows"

MARKER_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-root.XXXXXX")"
PLIST_TEMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/codex-update-launchd.XXXXXX.plist")"
cleanup() { /bin/rm -f "$MARKER_TEMP" "$PLIST_TEMP"; }
trap cleanup EXIT
/usr/bin/printf '%s\n' 'codex-session-keeper-update-root-v1' > "$MARKER_TEMP"
sudo /usr/bin/install -o root -g admin -m 0664 "$MARKER_TEMP" "$SITE_ROOT/.codex-update-root"
sudo /usr/bin/install -d -o root -g wheel -m 0755 /usr/local/etc
sudo /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/nginx.conf" "$CONFIG_DEST"

/usr/bin/plutil -create xml1 "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :UserName string root" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $NGINX_BIN" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string -c" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $CONFIG_DEST" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string -g" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string daemon off;" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string /var/log/codex-update-launchd.log" "$PLIST_TEMP"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string /var/log/codex-update-launchd-error.log" "$PLIST_TEMP"

sudo "$NGINX_BIN" -t -c "$CONFIG_DEST"
if sudo /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  sudo /bin/launchctl bootout "system/$LABEL"
fi
sudo /usr/bin/install -o root -g wheel -m 0644 "$PLIST_TEMP" "$PLIST_DEST"
sudo /bin/launchctl bootstrap system "$PLIST_DEST"
sudo /bin/launchctl enable "system/$LABEL"
sudo /bin/launchctl kickstart -k "system/$LABEL"
/usr/bin/curl --fail --silent --show-error --head \
  "http://192.168.10.54:18080/codex-session-keeper/" >/dev/null || true
echo "installed $LABEL on http://192.168.10.54:18080/"
```

The final `curl` may return `404` before the first release page exists; it must not mask installer success. Make the script executable with:

```bash
chmod 0755 deploy/mac-mini/install-static-update-server.sh
```

- [ ] **Step 5: Run deployment source tests and local syntax checks**

Run:

```bash
node --test scripts/update/mac-mini-deployment.test.mjs
bash -n deploy/mac-mini/install-static-update-server.sh
```

Expected: test PASS; Bash syntax exits `0`. Do not run the installer in this task.

- [ ] **Step 6: Commit Task 5**

```bash
git add deploy/mac-mini/nginx.conf deploy/mac-mini/install-static-update-server.sh scripts/update/mac-mini-deployment.test.mjs
git commit -m "feat: add native Mac mini update hosting"
```

---

### Task 6: Retire the NAS update deployment and rewrite operator documentation

**Files:**
- Delete: `deploy/nas/docker-compose.yml`
- Delete: `deploy/nas/nginx.conf`
- Delete: `docs/NAS内网更新部署与发布.md`
- Create: `docs/Mac-mini内网更新部署与发布.md`
- Create: `release-notes/1.1.0.json`
- Modify: `README.md:120-135`
- Modify: `docs/操作手册.md:1-150`

**Interfaces:**
- Consumes: the fixed URLs, deployment files, publisher commands, and approval boundaries from Tasks 1-5.
- Produces: one current administrator runbook with no instruction to operate the NAS update service.

- [ ] **Step 1: Write the Mac mini runbook**

Create `docs/Mac-mini内网更新部署与发布.md` with these exact sections and commands:

````markdown
# Mac mini 内网更新部署与发布

正式发布根地址：

`http://192.168.10.54:18080/codex-session-keeper/stable/`

## 安全边界

- 仅允许 RFC 1918 私有地址访问，禁止公网端口转发。
- 员工和 Nginx worker 只有读取权限；管理员通过本机文件系统发布。
- 私钥只保存在发布 Mac 钥匙串和经批准的离线加密备份中。
- 安装 Nginx、LaunchDaemon 或发布版本前必须再次取得明确批准。

## 首次部署

1. 在目标 Mac mini 上确认 `ifconfig` 包含 `192.168.10.54`。
2. 确认 Mac mini 不会在工作时间自动休眠。
3. 从干净仓库运行 `deploy/mac-mini/install-static-update-server.sh`。
4. 验证 `sudo launchctl print system/com.company.codex-update-server`。
5. 验证 `NGINX_BIN="$("$(command -v brew)" --prefix nginx)/bin/nginx" && sudo "$NGINX_BIN" -t -c /usr/local/etc/codex-update-nginx.conf`。

## 构建与候选组装

使用现有 macOS 和 Windows 构建命令生成同版本、同构建号产物。然后运行：

```bash
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip" \
  --windows-exe "$PWD/dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "$PWD/dist/windows/latest.yml" \
  --notes-file "$PWD/release-notes/1.1.0.json" \
  --output "$PWD/.release-staging/1.1.0"

node scripts/update/verify-release-directory.mjs \
  --root "$PWD/.release-staging/1.1.0/codex-session-keeper/stable"
```

## 原子发布

先把候选复制到 Mac mini 站点所在文件系统，再发布：

```bash
sudo install -d -o root -g admin -m 0775 \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0

rsync -a --delete \
  "$PWD/.release-staging/1.1.0/" \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0/

scripts/update/publish-release.sh \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0/codex-session-keeper/stable \
  /Users/Shared/codex-update-site/codex-session-keeper/stable
```

发布顺序为版本化产物、appcast、`latest.yml`、`release.json.sig`、`release.json`，最后生成并替换员工下载页 `index.html`。

## 发布后验证

```bash
curl -fsS http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.54:18080/codex-session-keeper/stable/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
curl -fsS -r 0-1023 -D - -o /dev/null http://192.168.10.54:18080/codex-session-keeper/stable/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
curl -X POST -i http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -fsS http://192.168.10.54:18080/codex-session-keeper/
```

要求：清单 `no-cache`，版本化安装包 `immutable`，Range 请求返回 `206 Partial Content`，POST 返回 `405`，目录不列文件，下载页只链接已签名正式版本。

## 故障处理

- 服务停止：`sudo launchctl kickstart -k system/com.company.codex-update-server`。
- 配置异常：先运行 Nginx `-t`，通过后再重启 LaunchDaemon。
- 版本缺陷：修复后发布更高版本，不降低 `release.json` 版本。
- 文件疑似被修改：停止发布并保留现场，不使用未经验证的文件覆盖。
- 版本化安装包默认保留当前版本和前两个稳定版本；删除是单独审批操作。
````

- [ ] **Step 2: Update employee and repository documentation**

In `README.md`, replace “发布到 NAS” with “发布到固定内网 IP 为 `192.168.10.54` 的 Mac mini”，and link `docs/Mac-mini内网更新部署与发布.md`.

In `docs/操作手册.md`:

- Change first-install source from “公司 NAS” to `http://192.168.10.54:18080/codex-session-keeper/`.
- Change project structure from `deploy/nas/` to `deploy/mac-mini/`.
- Change publication approval text from NAS mutation to Mac mini Nginx/LaunchDaemon/publication mutation.
- Link the new Mac mini runbook.
- Preserve the existing employee-confirmed update behavior, test commands, data-preservation requirements, and historical verification records.

- [ ] **Step 3: Add the exact signed `1.1.0` release notes**

Create `release-notes/1.1.0.json`:

```json
[
  "增加公司局域网静态网页自动更新支持",
  "更新服务器迁移至公司 Mac mini",
  "保留员工确认下载和重启安装流程"
]
```

- [ ] **Step 4: Remove only the superseded NAS update-service files**

Run:

```bash
git rm deploy/nas/docker-compose.yml deploy/nas/nginx.conf docs/NAS内网更新部署与发布.md
```

Do not remove or edit the direct NAS incremental-backup implementation or its historical design/plan files.

- [ ] **Step 5: Verify current operational files contain no old update endpoint**

Run:

```bash
rg -n "192\.168\.10\.99:18080|deploy/nas|NAS内网更新部署与发布" \
  README.md Config Sources Tests scripts windows deploy docs/操作手册.md docs/Mac-mini内网更新部署与发布.md
```

Expected: no output. References to `192.168.10.99` in direct SMB backup files and historical `docs/superpowers/` files are allowed and must remain.

- [ ] **Step 6: Commit Task 6**

```bash
git add README.md docs/操作手册.md docs/Mac-mini内网更新部署与发布.md release-notes/1.1.0.json deploy/mac-mini
git add -u deploy/nas docs/NAS内网更新部署与发布.md
git commit -m "docs: migrate update operations to the Mac mini"
```

---

### Task 7: Run complete automated verification and rebuild both release versions

**Files:**
- Verify only: all files changed in Tasks 1-6
- Generated and ignored: `dist/macos/*`, `dist/windows/*`, `.release-staging/*`

**Interfaces:**
- Consumes: committed implementation, signing public config, resolved Sparkle framework, official Python/Git Bash/Node tools on Windows.
- Produces: clean tests plus rebuilt `1.0.99` and `1.1.0` artifacts that embed `192.168.10.54`.

- [ ] **Step 1: Run all repository-side tests**

Run on the development Mac:

```bash
swift test
node --test scripts/update/*.test.mjs
bash -n scripts/update/publish-release.sh
bash -n deploy/mac-mini/install-static-update-server.sh
cd windows/codex_session_manager_electron && npm test
```

Expected: every suite PASS with zero failed tests; both Bash checks exit `0`.

- [ ] **Step 2: Build and inspect macOS `1.0.99`**

Run:

```bash
APP_VERSION=1.0.99 APP_BUILD=10099 scripts/build_app.sh
/usr/libexec/PlistBuddy -c 'Print :CSKUpdateBaseURL' dist/codex_会话管理.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' dist/codex_会话管理.app/Contents/Info.plist
codesign --verify --deep --strict dist/codex_会话管理.app
shasum -a 256 dist/macos/CodexSessionKeeper-1.0.99-macos-arm64.zip
```

Expected URLs are the exact release root and macOS appcast URL from Global Constraints; codesign exits `0`; record the SHA-256.

- [ ] **Step 3: Build and inspect macOS `1.1.0`**

Run the same commands with `APP_VERSION=1.1.0 APP_BUILD=10100` and archive name `CodexSessionKeeper-1.1.0-macos-arm64.zip`. Expected: exact Mac mini URLs, codesign success, and a recorded SHA-256.

- [ ] **Step 4: Synchronize the clean implementation to the Windows test repository**

On the Windows test computer, use the existing clean repository:

```powershell
Set-Location 'C:\Users\171\Downloads\CodexSessionKeeper-Windows-Test-online-9e0a730'
git status --short
git switch codex/nas-auto-update
git pull --ff-only origin codex/nas-auto-update
git status --short
git rev-parse HEAD
```

Expected: both status checks are empty; pull is fast-forward-only; HEAD contains all Task 1-6 commits. If GitHub is temporarily unavailable, stop without modifying or cleaning anything and retry later.

- [ ] **Step 5: Build Windows `1.0.99` and `1.1.0`**

Run only after the previously validated official Python/Git Bash/curl/unzip environment is available:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.0.99 -Build 10099
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.1.0 -Build 10100
```

Expected: each command exits `0`; its embedded `npm test` reports zero failures; outputs are exactly:

```text
dist\windows\CodexSessionKeeper-1.0.99-windows-x64-Setup.exe
dist\windows\CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
dist\windows\latest.yml
```

- [ ] **Step 6: Verify Windows metadata, hashes, and clean source state**

Run:

```powershell
Get-FileHash -Algorithm SHA256 dist\windows\CodexSessionKeeper-1.0.99-windows-x64-Setup.exe
Get-FileHash -Algorithm SHA256 dist\windows\CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
Get-FileHash -Algorithm SHA256 dist\windows\latest.yml
Get-Content dist\windows\latest.yml
git status --short
```

Expected: `latest.yml` names `1.1.0` and its exact byte size; all hashes are recorded; Git status is empty because the build script restored temporary metadata.

- [ ] **Step 7: Copy Windows outputs through the existing controlled company transfer path**

Copy only the two Setup EXEs and `latest.yml` to the development/release Mac `dist/windows/`. Do not copy Codex task history, private keys, npm caches, `win-unpacked`, or temporary logs.

- [ ] **Step 8: Assemble and verify the `1.1.0` candidate**

Use the committed `release-notes/1.1.0.json`, then run:

```bash
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip" \
  --windows-exe "$PWD/dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "$PWD/dist/windows/latest.yml" \
  --notes-file "$PWD/release-notes/1.1.0.json" \
  --output "$PWD/.release-staging/1.1.0"

node scripts/update/verify-release-directory.mjs \
  --root "$PWD/.release-staging/1.1.0/codex-session-keeper/stable"
```

Expected final JSON:

```json
{"verified":true,"version":"1.1.0","build":10100}
```

- [ ] **Step 9: Verify no source changes were produced**

Run:

```bash
git status --short
```

Expected: empty. The exact release notes were already reviewed and committed in Task 6.

---

### Task 8: Deploy and publish on the target Mac mini

**Files / external state:**
- Target: `/Users/Shared/codex-update-site`
- Target: `/usr/local/etc/codex-update-nginx.conf`
- Target: `/Library/LaunchDaemons/com.company.codex-update-server.plist`
- Target service: `system/com.company.codex-update-server`

**Interfaces:**
- Consumes: verified `1.1.0` candidate from Task 7 and deployment bundle from Task 5.
- Produces: LAN download page and signed stable update tree at `192.168.10.54:18080`.

- [ ] **Step 1: Stop and obtain explicit deployment approval**

Report the exact target paths and that the next command installs Homebrew Nginx if missing, writes a LaunchDaemon, opens listener `192.168.10.54:18080`, and creates `/Users/Shared/codex-update-site`. Do not continue until the user explicitly approves this external-state change.

- [ ] **Step 2: Run read-only target preflight**

On the target Mac mini:

```bash
/sbin/ifconfig | /usr/bin/awk '/inet / { print $2 }'
/usr/sbin/lsof -nP -iTCP@192.168.10.54:18080 -sTCP:LISTEN
/usr/bin/pmset -g
git status --short
```

Expected: `192.168.10.54` appears; port `18080` is unused or owned by the already installed Codex update service; power settings and operator confirmation establish that work-hour sleep is disabled; Git status is empty. Stop on any mismatch.

- [ ] **Step 3: Install or refresh the native service**

Run:

```bash
deploy/mac-mini/install-static-update-server.sh
sudo launchctl print system/com.company.codex-update-server
```

Expected: installer exits `0`; launchd reports a running service; Nginx worker processes run as `_www` while the launchd master runs as root.

- [ ] **Step 4: Copy the verified candidate onto the same filesystem**

Run:

```bash
sudo install -d -o root -g admin -m 0775 \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0
rsync -a --delete \
  "$PWD/.release-staging/1.1.0/" \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0/
```

Expected: only public release files are copied; no private key, key backup, `.git`, task history, or build cache is present below `.verified-staging`.

- [ ] **Step 5: Stop and obtain explicit publication approval**

Report the verified candidate version/build, Windows and macOS artifact SHA-256 values, destination, and the exact publication command. Do not publish until the user explicitly approves.

- [ ] **Step 6: Atomically publish**

Run:

```bash
scripts/update/publish-release.sh \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0/codex-session-keeper/stable \
  /Users/Shared/codex-update-site/codex-session-keeper/stable
```

Expected: output contains `published 1.1.0`; `release.json` was the final update metadata replacement; `/Users/Shared/codex-update-site/codex-session-keeper/index.html` was replaced afterward.

- [ ] **Step 7: Verify HTTP behavior from the Mac mini and an employee computer**

Run from both hosts:

```bash
curl -fsS http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.54:18080/codex-session-keeper/stable/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
curl -fsS -r 0-1023 -D - -o /dev/null http://192.168.10.54:18080/codex-session-keeper/stable/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
curl -X POST -i http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -fsS http://192.168.10.54:18080/codex-session-keeper/
```

Expected: signed manifest downloads; metadata reports `no-cache`; Setup reports immutable long cache and correct `Content-Length`; Range returns `206 Partial Content`; POST returns `405`; page links only the `1.1.0` Windows Setup.

- [ ] **Step 8: Verify restart recovery without changing NAS**

Run:

```bash
sudo launchctl kickstart -k system/com.company.codex-update-server
curl -fsS http://192.168.10.54:18080/codex-session-keeper/stable/release.json >/dev/null
```

Expected: service returns after restart and curl exits `0`. Confirm no NAS page, share, Docker project, or file was modified.

---

### Task 9: Complete Windows `1.0.99 -> 1.1.0` end-to-end acceptance

**Files / external state:**
- Installer: `CodexSessionKeeper-1.0.99-windows-x64-Setup.exe`
- Update target: signed `1.1.0` served by `192.168.10.54:18080`
- User data: existing Windows test account Codex sessions and local incremental backup state

**Interfaces:**
- Consumes: Task 7 baseline installer and Task 8 published release.
- Produces: recorded proof of first download, update discovery, download verification, restart install, and data preservation.

- [ ] **Step 1: Stop and obtain explicit Setup execution approval**

Report the exact `1.0.99` Setup path, size, SHA-256, installed versions, and running target processes. Do not close apps or run Setup until the user explicitly approves.

- [ ] **Step 2: Establish a clean acceptance baseline**

On the Windows test computer:

```powershell
Get-FileHash -Algorithm SHA256 .\dist\windows\CodexSessionKeeper-1.0.99-windows-x64-Setup.exe
Get-Process | Where-Object { $_.Path -like '*codex*会话管理*.exe' } | Select-Object Id,Path
```

Use the application UI to exit naturally if it is running. Record visible session count, backup status, current settings, snapshot count, installed versions, and shortcuts. Do not delete the independent historical `1.0.14` entry during this acceptance test.

- [ ] **Step 3: Install the new-endpoint `1.0.99` baseline interactively**

Run the Setup EXE with no silent, elevation-bypass, or SmartScreen-bypass arguments. Expected: current-user installation exits `0`, requests no administrator elevation, launches normally, and preserves all recorded data.

- [ ] **Step 4: Verify first-install download page separately**

Open in the Windows browser:

```text
http://192.168.10.54:18080/codex-session-keeper/
```

Expected: page shows current version `1.1.0`; the button downloads the exact published Setup filename; downloaded SHA-256 equals the Task 7 `1.1.0` hash. Delete only this browser-downloaded duplicate after recording the result.

- [ ] **Step 5: Trigger and inspect update discovery**

Start `1.0.99`, wait at least 5 seconds, and if necessary click “检查更新”. Expected: dialog shows `1.1.0`, signed release notes, “稍后提醒”, and “立即更新”. Click “稍后提醒” once and confirm no Setup file is downloaded by electron-updater.

- [ ] **Step 6: Download and defer restart**

Open the update dialog again, click “立即更新”, and record increasing bytes/percentage. Expected: UI enters verifying, then ready. Click “稍后重启”; confirm application sessions and local backup remain usable and the ready state persists.

- [ ] **Step 7: Restart and install**

Choose “重启并更新”. Expected: backup drains within 5 seconds, the verified Setup runs, the application relaunches as `1.1.0`, and the completion dialog appears exactly once.

- [ ] **Step 8: Verify installation and data preservation**

Record:

- executable ProductVersion/FileVersion and SHA-256;
- Apps & Features entry for `1.1.0` with no third duplicate entry;
- desktop and Start Menu shortcut targets;
- session count and ability to open an existing session;
- snapshot visibility;
- local incremental backup status, manifest, and cursor continuity;
- unchanged settings and NAS backup identity;
- zero persistent target processes after normal UI exit.

Expected: all match the baseline except the intended version/executable change.

- [ ] **Step 9: Run automated negative-path evidence without modifying the live release**

From the clean repository, run:

```powershell
Set-Location 'C:\Users\171\Downloads\CodexSessionKeeper-Windows-Test-online-9e0a730\windows\codex_session_manager_electron'
node --test test\update\update-service.test.js
npm test
git status --short
```

Expected: tests prove silent scheduled timeout, visible manual timeout, invalid signature rejection, wrong feed URL rejection, tampered Setup deletion, and backup-drain cancellation; full suite has zero failures; Git status is empty. Do not corrupt or replace the live Mac mini release to repeat these cases.

- [ ] **Step 10: Record final acceptance result**

Add the measured hashes, sizes, timestamps, test counts, HTTP checks, installed version, data-preservation checks, and any observed OS prompts to the current verification section of `docs/操作手册.md`. Commit only this evidence:

```bash
git add docs/操作手册.md
git commit -m "docs: record Mac mini update acceptance"
```

Do not declare the rollout ready if any acceptance item failed or if source status is dirty.

---

## Final Verification Gate

After all nine tasks, run on the development Mac:

```bash
swift test
node --test scripts/update/*.test.mjs
bash -n scripts/update/publish-release.sh
bash -n deploy/mac-mini/install-static-update-server.sh
cd windows/codex_session_manager_electron && npm test
cd ../.. && git status --short
rg -n "192\.168\.10\.99:18080|deploy/nas|NAS内网更新部署与发布" \
  README.md Config Sources Tests scripts windows deploy docs/操作手册.md docs/Mac-mini内网更新部署与发布.md
```

Expected: all tests PASS; both Bash checks exit `0`; Git status is empty; the final `rg` has no output. Historical `docs/superpowers/` records and direct SMB backup code may still mention NAS server `192.168.10.99`, and that is intentional.

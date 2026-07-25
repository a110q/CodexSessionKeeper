# Latest Product Integration and macOS OOM Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce one release branch that contains the latest direct-backup implementation, the internal Windows/macOS updater, bounded large-JSONL memory behavior, and the macOS local-network permission required to reach the company update server.

**Architecture:** Use `codex/nas-direct-backup` at `f50eeb06dd0c08eb24f9e95cf84a4939d99fdb1b` as the latest backup baseline and merge it into the isolated update integration branch. Preserve update-specific files and contracts from `codex/nas-auto-update`, combine the few shared package/build surfaces deliberately, and let the complete Swift, Electron, update-protocol, packaging, and large-JSONL suites reject any lost behavior.

**Tech Stack:** Swift 6.3, SwiftUI, Sparkle 2.9.4, Node.js 24, Electron 43, electron-builder 26, Bash, Nginx.

## Global Constraints

- Do not reopen the currently installed unsafe macOS `1.0.99` package.
- Do not modify, truncate, move, or parse the real 5.94 GB JSONL file through the application.
- Do not modify `/codex-session-keeper/stable/`, the Windows stable installer, or the employee download page.
- Do not operate the NAS.
- Keep the original `codex/nas-auto-update` branch unchanged.
- Integrate on `codex/nas-auto-update-integrated`.
- Preserve the direct-backup branch's bounded streaming and isolated large-file verification.
- Preserve automatic update discovery, explicit user download confirmation, explicit restart/install confirmation, signed manifests, and testing/stable scopes.
- Add `NSLocalNetworkUsageDescription`; keep `NSAllowsLocalNetworking`.
- Build Apple Silicon (`arm64`) macOS artifacts only.
- Keep ad-hoc signing; do not add Developer ID or notarization.
- Never print or copy private signing keys.

---

### Task 1: Add red integration and local-network contracts

**Files:**
- Create: `scripts/update/latest-product-integration.test.mjs`
- Inspect: `scripts/build_app.sh`
- Inspect: `Package.swift`

**Interfaces:**
- Consumes: source tree at the integration branch
- Produces: a Node test proving that the bounded backup implementation and update implementation coexist and that packaged apps declare the local-network privacy description

- [ ] **Step 1: Add the failing test**

Create `scripts/update/latest-product-integration.test.mjs` with assertions that:

```javascript
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

test('latest bounded backup and signed updater coexist', () => {
  assert.equal(
    existsSync('Sources/CodexSessionVaultCore/Backup/SessionBackupStreamer.swift'),
    true,
    'latest bounded Swift backup streamer is missing',
  );
  assert.equal(
    existsSync('Tests/CodexSessionVaultCoreTests/LargeJSONLEndToEndAcceptanceTests.swift'),
    true,
    'large JSONL acceptance suite is missing',
  );
  assert.equal(
    existsSync('Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift'),
    true,
    'macOS updater is missing',
  );
  assert.equal(existsSync('Config/UpdateServer.testing.json'), true);
  assert.equal(
    existsSync('windows/codex_session_manager_electron/src/update/update-service.js'),
    true,
    'Windows updater is missing',
  );
});

test('macOS package explains and allows company-LAN update access', () => {
  const script = readFileSync('scripts/build_app.sh', 'utf8');
  assert.match(script, /<key>NSLocalNetworkUsageDescription<\/key>/);
  assert.match(script, /用于连接公司局域网更新服务器/);
  assert.match(script, /<key>NSAllowsLocalNetworking<\/key>\s*<true\/>/);
});
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
node --test scripts/update/latest-product-integration.test.mjs
```

Expected: both tests fail on the pre-integration branch: the latest backup streamer is absent and the local-network usage description is absent.

- [ ] **Step 3: Commit only the red contracts**

Run:

```bash
git add scripts/update/latest-product-integration.test.mjs \
  docs/superpowers/plans/2026-07-24-latest-integration-and-macos-oom-recovery-plan.md
git commit -m "test: require latest backup and updater integration"
```

---

### Task 2: Merge the latest direct-backup product baseline

**Files:**
- Merge: `codex/nas-direct-backup`
- Preserve: `Package.swift`
- Preserve: `scripts/build_app.sh`
- Combine: `windows/codex_session_manager_electron/package.json`
- Regenerate: `windows/codex_session_manager_electron/package-lock.json`

**Interfaces:**
- Consumes: direct-backup commit `f50eeb06dd0c08eb24f9e95cf84a4939d99fdb1b`
- Produces: one source tree containing direct backup plus signed update code

- [ ] **Step 1: Start a non-committing merge**

Run:

```bash
git merge --no-commit --no-ff -X theirs codex/nas-direct-backup
git diff --name-only --diff-filter=U
```

Expected: the second command has no output. If it lists any path, run
`git merge --abort` and stop instead of guessing.

- [ ] **Step 2: Restore the update-aware Swift package contract**

Ensure `Package.swift` contains both pinned dependencies:

```swift
.package(url: "https://github.com/swiftlang/swift-testing.git", revision: "937120cbc281cf29727fdfb8734482158508b4fc"),
.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
```

and the executable target depends on:

```swift
"CodexSessionVaultCore",
.product(name: "Sparkle", package: "Sparkle")
```

- [ ] **Step 3: Restore the update-aware macOS build script**

Use the pre-merge update build pipeline as the base for `scripts/build_app.sh`.
It must retain stable/testing configuration selection, Sparkle framework
embedding, ad-hoc signing, arm64 verification, ZIP output, DMG output, and
`DISABLE_SWIFTPM_SANDBOX`.

- [ ] **Step 4: Combine Windows package metadata**

Keep the update package's:

```json
"electron-updater": "6.8.9"
```

generic publish URL, `extraResources`, NSIS configuration, pinned Electron
archive checksum, and `package:win` command. Add the direct-backup branch's
`guide:pdf`, `dist:win`, and `postdist:win` scripts plus
`@electron/packager`.

Run:

```bash
npm install --package-lock-only --ignore-scripts
```

from `windows/codex_session_manager_electron`.

- [ ] **Step 5: Verify required source surfaces**

Run:

```bash
node --test scripts/update/latest-product-integration.test.mjs
swift test --filter LargeJSONL
node --test scripts/acceptance/large-jsonl-runner.test.js
node --test scripts/update/*.test.mjs
```

Expected: the integration coexistence test now fails only for the missing
local-network usage description. All backup/update suites otherwise pass.

---

### Task 3: Add macOS local-network privacy permission

**Files:**
- Modify: `scripts/build_app.sh`
- Test: `scripts/update/latest-product-integration.test.mjs`
- Test: `scripts/update/macos-package.test.mjs`

**Interfaces:**
- Consumes: fixed LAN endpoint `192.168.10.54:18080`
- Produces: packaged `Info.plist` containing a user-facing privacy reason

- [ ] **Step 1: Add the exact privacy key**

Insert before `NSAppTransportSecurity`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>用于连接公司局域网更新服务器，检查并下载 codex_会话管理 的新版本。</string>
```

Keep:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

- [ ] **Step 2: Extend packaging assertions**

Make `scripts/update/macos-package.test.mjs` verify both keys and the exact
Chinese description.

- [ ] **Step 3: Run focused tests and verify GREEN**

Run:

```bash
node --test \
  scripts/update/latest-product-integration.test.mjs \
  scripts/update/macos-package.test.mjs
```

Expected: all focused tests pass.

- [ ] **Step 4: Commit the integration**

Run:

```bash
git add -A
git commit
```

Use merge commit message:

```text
merge: integrate latest bounded backup with auto update
```

---

### Task 4: Run complete integration verification

**Files:**
- Verify: entire source tree

**Interfaces:**
- Consumes: integrated source
- Produces: a clean, test-passing release candidate source revision

- [ ] **Step 1: Run complete Swift tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
swift test
```

- [ ] **Step 2: Run complete Electron tests**

Run from `windows/codex_session_manager_electron`:

```bash
npm test
```

- [ ] **Step 3: Run update and acceptance tests**

Run:

```bash
node --test scripts/update/*.test.mjs
node --test scripts/acceptance/large-jsonl-runner.test.js
```

- [ ] **Step 4: Verify source state**

Run:

```bash
git status --short
git rev-parse HEAD
```

Expected: clean status and one integrated revision.

---

### Task 5: Rebuild and republish only the testing candidate

**Files:**
- Produce: `dist/macos/CodexSessionKeeper-1.0.99-macos-arm64.{zip,dmg}`
- Produce: `dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.{zip,dmg}`
- Publish: `/Users/Shared/codex-update-site/codex-session-keeper/testing`

**Interfaces:**
- Consumes: integrated clean revision
- Produces: signed, verified testing Appcast and artifacts

- [ ] **Step 1: Build `1.0.99` with testing configuration**

Run in a normal Terminal:

```bash
APP_VERSION=1.0.99 APP_BUILD=10099 UPDATE_SCOPE=testing ./scripts/build_app.sh
```

- [ ] **Step 2: Build `1.1.0` with stable configuration**

Run:

```bash
APP_VERSION=1.1.0 APP_BUILD=10100 UPDATE_SCOPE=stable ./scripts/build_app.sh
```

- [ ] **Step 3: Reassemble and verify the testing release**

Use `build-release-manifest.mjs --server-scope testing`, then
`verify-release-directory.mjs --root <absolute-testing-root>`.

- [ ] **Step 4: Publish with candidate mode**

Use:

```bash
publish-release.sh --candidate \
  <absolute-verified-testing-root> \
  /Users/Shared/codex-update-site/codex-session-keeper/testing
```

Expected: stable hashes and `index.html` hash remain unchanged.

---

### Task 6: Repeat monitored manual acceptance

**Files and state:**
- Install: rebuilt `1.0.99` DMG
- Observe: real session counts and backup status
- Observe: Nginx access log

**Interfaces:**
- Consumes: rebuilt testing candidate
- Produces: safe `1.0.99 → 1.1.0` acceptance evidence

- [ ] **Step 1: Install rebuilt `1.0.99` without launching**

Verify version `1.0.99`, build `10099`, architecture `arm64`, testing Appcast,
and the local-network privacy description.

- [ ] **Step 2: Launch under memory sampling**

Sample RSS, physical footprint, compressed memory, and swap every second.
Fail if the application exceeds the large-JSONL acceptance budget or the
kernel reports swap exhaustion.

- [ ] **Step 3: Approve Local Network**

The user personally approves the macOS Local Network prompt. If no prompt is
shown, inspect System Settings → Privacy & Security → Local Network without
changing unrelated permissions.

- [ ] **Step 4: Verify no pre-consent download**

Confirm the update prompt shows `1.1.0` and Nginx records no ZIP GET before the
user clicks “立即更新”.

- [ ] **Step 5: Complete both user confirmations**

The user clicks “立即更新”, then “重启并更新”. Verify `1.1.0 / 10100`, stable
future feed, unchanged session count, resumed backup, one app instance, and no
NAS access.

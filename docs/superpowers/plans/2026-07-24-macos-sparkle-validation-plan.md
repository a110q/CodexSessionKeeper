# macOS Sparkle Internal Update Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the missing safety gates, candidate-channel packaging, arm64 DMG output, and real-device validation for the existing Sparkle 2 macOS updater.

**Architecture:** Keep the existing `MacUpdateCoordinator`, `SparkleUpdateDriver`, signed `release.json`, and Sparkle Appcast architecture. Add a small pure consent policy in the core module, add an exact internal `testing` server scope alongside `stable`, and make the existing build produce both an update ZIP and a manual-install DMG. Publish candidate files to an isolated Mac mini path, then manually validate `1.0.99 → 1.1.0` before any stable promotion.

**Tech Stack:** Swift 6, SwiftUI, Sparkle 2.9.4, Swift Testing, Node.js built-in test runner, Bash, Homebrew Nginx, Sparkle EdDSA signing tools.

## Global Constraints

- Target macOS 14 or newer on Apple Silicon only; every application binary must report `arm64`.
- Do not add Intel or universal builds.
- Do not apply for or require Apple Developer ID; application bundles use ad-hoc signing.
- Sparkle update ZIPs must use the existing EdDSA account `local.codex.session-manager`.
- Never print, copy into Git, or upload either update private key.
- Stable URL remains `http://192.168.10.54:18080/codex-session-keeper/stable/`.
- Candidate URL is exactly `http://192.168.10.54:18080/codex-session-keeper/testing/`.
- Automatic checks are allowed; automatic download and unconfirmed installation remain disabled.
- Do not modify Windows update behavior, Windows release filenames, or the validated Windows `1.1.0` installer.
- Do not operate the NAS.
- Do not publish the employee download page or stable macOS release until the candidate update passes.
- Do not delete existing DMGs, Windows installers, updater caches, applications, sessions, or backups.
- Versioned artifacts are immutable: never replace different bytes under an existing versioned filename.

---

## File Map

Files created:

- `Config/UpdateServer.testing.json` — exact candidate update root used only by candidate baseline builds.
- `Sources/CodexSessionVaultCore/Update/MacUpdateConsentPolicy.swift` — pure authorization policy for download and restart/install actions.
- `Tests/CodexSessionVaultCoreTests/MacUpdateConsentPolicyTests.swift` — regression tests proving only the two confirmed UI states authorize actions.
- `scripts/update/macos-package.test.mjs` — packaging contract tests for arm64 ZIP/DMG production and ad-hoc verification.

Files modified:

- `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift` — consult the pure consent policy before invoking Sparkle download or installation paths.
- `scripts/build_app.sh` — select exact stable/testing configuration and produce verified ZIP plus DMG.
- `scripts/update/update-server.mjs` — expose immutable stable and testing server descriptors.
- `scripts/update/update-server.test.mjs` — validate both exact endpoints and reject other paths.
- `scripts/update/build-release-manifest.mjs` — generate Appcast URLs for a selected exact server scope.
- `scripts/update/release-manifest.test.mjs` — verify candidate Appcast URLs while preserving signed manifest semantics.
- `scripts/update/publish-release.sh` — add candidate mode that never replaces the employee page.
- `scripts/update/build-download-page.test.mjs` — prove candidate publication cannot publish `index.html`.

Files intentionally unchanged:

- `Config/UpdateServer.json`
- `Config/UpdateKeys.json`
- `windows/**`
- `deploy/mac-mini/nginx.conf`
- `deploy/mac-mini/install-static-update-server.sh`

---

### Task 1: Synchronize and establish the verified baseline

**Files:**
- Inspect: all tracked files
- Preserve: `docs/superpowers/specs/2026-07-24-macos-sparkle-auto-update-design.md`
- Preserve: `docs/superpowers/plans/2026-07-24-macos-sparkle-validation-plan.md`

**Interfaces:**
- Consumes: remote branch `windows-test/codex/nas-auto-update`
- Produces: a clean local branch containing upstream commit `01c27bebdf86c265e29679edae9a0c571a55851c` or a descendant plus the local documentation commits

- [ ] **Step 1: Verify the worktree is clean**

Run:

```bash
git status --short
```

Expected: no output.

- [ ] **Step 2: Fetch the update branch without changing the checked-out files**

Run:

```bash
git fetch windows-test codex/nas-auto-update
```

Expected: exit `0` and `windows-test/codex/nas-auto-update` advances to the current GitHub branch.

- [ ] **Step 3: Prove the previously validated Windows commit remains in history**

Run:

```bash
git merge-base --is-ancestor \
  01c27bebdf86c265e29679edae9a0c571a55851c \
  windows-test/codex/nas-auto-update
```

Expected: exit `0`, no output. Stop if the exit code is nonzero.

- [ ] **Step 4: Replay the local documentation commits on the synchronized branch**

Run:

```bash
git rebase windows-test/codex/nas-auto-update
```

Expected: rebase completes without conflicts. If a conflict appears, abort with
`git rebase --abort` and report it instead of guessing.

- [ ] **Step 5: Run the existing baseline suites before changing code**

Run:

```bash
swift test
node --test scripts/update/*.test.mjs
```

Expected: both commands exit `0`; no test failures.

- [ ] **Step 6: Record the baseline without committing generated files**

Run:

```bash
git status --short
git rev-parse HEAD
```

Expected: status is empty and the printed HEAD contains the synchronized source plus documentation commits.

---

### Task 2: Make user consent an explicit tested policy

**Files:**
- Create: `Sources/CodexSessionVaultCore/Update/MacUpdateConsentPolicy.swift`
- Create: `Tests/CodexSessionVaultCoreTests/MacUpdateConsentPolicyTests.swift`
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`

**Interfaces:**
- Consumes: `UpdatePresentationState`
- Produces:
  - `MacUpdateUserAction`
  - `MacUpdateConsentPolicy.allows(_:in:) -> Bool`
- Used by: `MacUpdateCoordinator.beginDownload()` and `MacUpdateCoordinator.restartAndInstall()`

- [ ] **Step 1: Write the failing consent-policy tests**

Create:

```swift
import Testing
@testable import CodexSessionVaultCore

@Suite
struct MacUpdateConsentPolicyTests {
    @Test
    func downloadRequiresTheAvailableState() {
        #expect(MacUpdateConsentPolicy.allows(
            .beginDownload,
            in: .available(version: "1.1.0", notes: [])
        ))
        for state in nonAvailableStates {
            #expect(!MacUpdateConsentPolicy.allows(.beginDownload, in: state))
        }
    }

    @Test
    func installRequiresTheReadyState() {
        #expect(MacUpdateConsentPolicy.allows(
            .restartAndInstall,
            in: .ready(version: "1.1.0")
        ))
        for state in nonReadyStates {
            #expect(!MacUpdateConsentPolicy.allows(.restartAndInstall, in: state))
        }
    }

    private var nonAvailableStates: [UpdatePresentationState] {
        [
            .idle,
            .checking,
            .downloading(version: "1.1.0", received: 1, total: 2),
            .extracting(version: "1.1.0", progress: 0.5),
            .ready(version: "1.1.0"),
            .installing(version: "1.1.0"),
            .failed(message: "failed"),
            .upToDate(version: "1.1.0"),
            .completed(version: "1.1.0"),
        ]
    }

    private var nonReadyStates: [UpdatePresentationState] {
        [
            .idle,
            .checking,
            .available(version: "1.1.0", notes: []),
            .downloading(version: "1.1.0", received: 1, total: 2),
            .extracting(version: "1.1.0", progress: 0.5),
            .installing(version: "1.1.0"),
            .failed(message: "failed"),
            .upToDate(version: "1.1.0"),
            .completed(version: "1.1.0"),
        ]
    }
}
```

- [ ] **Step 2: Run the new suite and verify it fails**

Run:

```bash
swift test --filter MacUpdateConsentPolicyTests
```

Expected: FAIL because `MacUpdateConsentPolicy` and `MacUpdateUserAction` do not exist.

- [ ] **Step 3: Implement the minimal pure policy**

Create:

```swift
public enum MacUpdateUserAction: Equatable, Sendable {
    case beginDownload
    case restartAndInstall
}

public enum MacUpdateConsentPolicy {
    public static func allows(
        _ action: MacUpdateUserAction,
        in state: UpdatePresentationState
    ) -> Bool {
        switch (action, state) {
        case (.beginDownload, .available):
            return true
        case (.restartAndInstall, .ready):
            return true
        default:
            return false
        }
    }
}
```

- [ ] **Step 4: Wire both side-effect entry points to the policy**

Replace the first guard in `beginDownload()` with:

```swift
guard MacUpdateConsentPolicy.allows(.beginDownload, in: state),
      case .available(let version, _) = state else {
    return
}
```

Replace the first guard in `restartAndInstall()` with:

```swift
guard MacUpdateConsentPolicy.allows(.restartAndInstall, in: state),
      case .ready(let version) = state else {
    return
}
```

Do not add any other call to `updater.checkForUpdates()` or any direct install call.

- [ ] **Step 5: Run focused and full Swift tests**

Run:

```bash
swift test --filter MacUpdateConsentPolicyTests
swift test
```

Expected: both commands exit `0`.

- [ ] **Step 6: Commit the consent gate**

```bash
git add \
  Sources/CodexSessionVaultCore/Update/MacUpdateConsentPolicy.swift \
  Tests/CodexSessionVaultCoreTests/MacUpdateConsentPolicyTests.swift \
  Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift
git commit -m "test: enforce macOS update consent gates"
```

---

### Task 3: Add an exact candidate server scope

**Files:**
- Create: `Config/UpdateServer.testing.json`
- Modify: `scripts/update/update-server.mjs`
- Modify: `scripts/update/update-server.test.mjs`
- Modify: `scripts/build_app.sh`

**Interfaces:**
- Produces:
  - `UPDATE_SERVERS.stable`
  - `UPDATE_SERVERS.testing`
  - `updateServerForScope(scope)`
- Consumed by: macOS packaging and release assembly

- [ ] **Step 1: Add failing endpoint tests**

Add to `scripts/update/update-server.test.mjs`:

```javascript
test('candidate server is the exact isolated Mac mini path', () => {
  assert.deepEqual(updateServerForScope('testing'), {
    scope: 'testing',
    releaseBaseURL: 'http://192.168.10.54:18080/codex-session-keeper/testing/',
    windowsFeedURL: 'http://192.168.10.54:18080/codex-session-keeper/testing/windows/',
    macDownloadPrefix: 'http://192.168.10.54:18080/codex-session-keeper/testing/macos/',
    macAppcastURL: 'http://192.168.10.54:18080/codex-session-keeper/testing/macos/appcast.xml',
  });
});

test('server scope rejects unknown values', () => {
  for (const scope of ['', 'beta', '../stable', 'testing/']) {
    assert.throws(() => updateServerForScope(scope), /scope/);
  }
});
```

Update the import to include `updateServerForScope`.
Update the existing stable descriptor assertion to include:

```javascript
scope: 'stable',
```

- [ ] **Step 2: Run the endpoint test and verify it fails**

Run:

```bash
node --test scripts/update/update-server.test.mjs
```

Expected: FAIL because `updateServerForScope` is not exported.

- [ ] **Step 3: Add the immutable testing configuration**

Create `Config/UpdateServer.testing.json`:

```json
{
  "releaseBaseURL": "http://192.168.10.54:18080/codex-session-keeper/testing/"
}
```

Refactor `update-server.mjs` so the parser accepts an explicit expected scope:

```javascript
export function parseUpdateServerConfig(value, scope = 'stable') {
  if (!['stable', 'testing'].includes(scope)) {
    throw new Error('update server scope must be stable or testing');
  }
  if (!value || typeof value !== 'object' || typeof value.releaseBaseURL !== 'string') {
    throw new Error('releaseBaseURL must be a string');
  }
  const url = new URL(value.releaseBaseURL);
  const expectedPath = `/codex-session-keeper/${scope}/`;
  if (!['http:', 'https:'].includes(url.protocol)
      || url.username || url.password || url.search || url.hash
      || url.pathname !== expectedPath
      || url.href !== value.releaseBaseURL) {
    throw new Error(`releaseBaseURL must be a canonical HTTP(S) ${scope}-root URL`);
  }
  return Object.freeze({
    scope,
    releaseBaseURL: url.href,
    windowsFeedURL: new URL('windows/', url).href,
    macDownloadPrefix: new URL('macos/', url).href,
    macAppcastURL: new URL('macos/appcast.xml', url).href,
  });
}
```

Load the two JSON files and export:

```javascript
export const UPDATE_SERVERS = Object.freeze({
  stable: parseUpdateServerConfig(stableConfig, 'stable'),
  testing: parseUpdateServerConfig(testingConfig, 'testing'),
});

export const UPDATE_SERVER = UPDATE_SERVERS.stable;

export function updateServerForScope(scope) {
  const server = UPDATE_SERVERS[scope];
  if (!server) throw new Error('update server scope must be stable or testing');
  return server;
}
```

- [ ] **Step 4: Make the macOS build select only the two declared scopes**

At the top of `scripts/build_app.sh`, add:

```bash
UPDATE_SCOPE="${UPDATE_SCOPE:-stable}"
case "$UPDATE_SCOPE" in
  stable)
    UPDATE_SERVER_CONFIG="$ROOT_DIR/Config/UpdateServer.json"
    EXPECTED_UPDATE_BASE_URL="http://192.168.10.54:18080/codex-session-keeper/stable/"
    ;;
  testing)
    UPDATE_SERVER_CONFIG="$ROOT_DIR/Config/UpdateServer.testing.json"
    EXPECTED_UPDATE_BASE_URL="http://192.168.10.54:18080/codex-session-keeper/testing/"
    ;;
  *)
    echo "UPDATE_SCOPE must be stable or testing" >&2
    exit 2
    ;;
esac
```

Replace the hard-coded URL assertion with:

```bash
[[ "$UPDATE_BASE_URL" == "$EXPECTED_UPDATE_BASE_URL" ]] || {
  echo "unexpected fixed update server for $UPDATE_SCOPE: $UPDATE_BASE_URL" >&2
  exit 2
}
```

- [ ] **Step 5: Run endpoint and full Node tests**

Run:

```bash
node --test scripts/update/update-server.test.mjs
node --test scripts/update/*.test.mjs
```

Expected: both commands exit `0`.

- [ ] **Step 6: Commit the candidate scope**

```bash
git add \
  Config/UpdateServer.testing.json \
  scripts/update/update-server.mjs \
  scripts/update/update-server.test.mjs \
  scripts/build_app.sh
git commit -m "feat: add isolated macOS update candidate scope"
```

---

### Task 4: Produce and verify arm64 ZIP and DMG artifacts

**Files:**
- Modify: `scripts/build_app.sh`
- Create: `scripts/update/macos-package.test.mjs`

**Interfaces:**
- Inputs:
  - `APP_VERSION`
  - `APP_BUILD`
  - `UPDATE_SCOPE`
- Outputs:
  - `dist/macos/CodexSessionKeeper-<version>-macos-arm64.zip`
  - `dist/macos/CodexSessionKeeper-<version>-macos-arm64.dmg`

- [ ] **Step 1: Write a failing packaging-contract test**

Create:

```javascript
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
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
node --test scripts/update/macos-package.test.mjs
```

Expected: FAIL because the build does not yet generate or verify a DMG.

- [ ] **Step 3: Add deterministic DMG staging and cleanup**

In `scripts/build_app.sh`, define:

```bash
DMG_PATH="$MACOS_DIST_DIR/CodexSessionKeeper-$APP_VERSION-macos-arm64.dmg"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/codex-macos-dmg.XXXXXX")"
cleanup() {
  rm -f "$SERVER_PLIST" "$KEYS_PLIST"
  if [[ -d "$DMG_STAGE" && "$DMG_STAGE" == *"/codex-macos-dmg."* ]]; then
    rm -rf "$DMG_STAGE"
  fi
}
trap cleanup EXIT
```

After ad-hoc signing and ZIP creation, add:

```bash
ARCHS="$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/CodexSessionVault")"
[[ "$ARCHS" == "arm64" ]] || {
  echo "unexpected application architectures: $ARCHS" >&2
  exit 2
}
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

/usr/bin/ditto "$APP_DIR" "$DMG_STAGE/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

echo "$ARCHIVE_PATH"
echo "$DMG_PATH"
```

- [ ] **Step 4: Run the contract test**

Run:

```bash
node --test scripts/update/macos-package.test.mjs
```

Expected: PASS.

- [ ] **Step 5: Run a real test build**

Run:

```bash
APP_VERSION=1.0.99 APP_BUILD=10099 UPDATE_SCOPE=testing ./scripts/build_app.sh
```

Expected: exit `0`; the final two lines name the versioned ZIP and DMG.

- [ ] **Step 6: Verify the real outputs**

Run:

```bash
/usr/bin/hdiutil verify dist/macos/CodexSessionKeeper-1.0.99-macos-arm64.dmg
/usr/bin/codesign --verify --deep --strict dist/codex_会话管理.app
/usr/bin/lipo -archs dist/codex_会话管理.app/Contents/MacOS/CodexSessionVault
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' dist/codex_会话管理.app/Contents/Info.plist
```

Expected:

- DMG verification succeeds.
- Code-sign verification succeeds.
- architecture output is exactly `arm64`.
- feed URL is exactly the `testing/macos/appcast.xml` URL.

- [ ] **Step 7: Commit packaging**

```bash
git add scripts/build_app.sh scripts/update/macos-package.test.mjs
git commit -m "build: emit verified macOS arm64 DMG"
```

---

### Task 5: Generate and publish an isolated candidate release

**Files:**
- Modify: `scripts/update/build-release-manifest.mjs`
- Modify: `scripts/update/release-manifest.test.mjs`
- Modify: `scripts/update/publish-release.sh`
- Modify: `scripts/update/build-download-page.test.mjs`

**Interfaces:**
- `assembleRelease({ build, generateAppcast, macZip, manifestPrivateKeyPem, manifestPublicKeyBase64, notesFile, output, publishedAt, sparklePublicKeyBase64, updateServer, version, windowsExe, windowsYml })`
- CLI option: `--server-scope stable|testing`
- Publisher option: `--candidate`

- [ ] **Step 1: Add a failing candidate Appcast test**

Add to `release-manifest.test.mjs` a fixture that calls:

```javascript
const candidateOutput = path.join(root, 'candidate-output');
const candidate = await assembleRelease({
  build: 10100,
  generateAppcast: async ({ downloadPrefix, macDirectory, zipName, zipBytes }) => {
    await writeFile(
      path.join(macDirectory, 'appcast.xml'),
      signedAppcast({
        version: '1.1.0',
        build: 10100,
        zipName,
        zipBytes,
        privateKeyPem: sparkleKey.privateKeyPem,
        downloadPrefix,
      }),
    );
  },
  macZip,
  manifestPrivateKeyPem: manifestKey.privateKeyPem,
  manifestPublicKeyBase64: manifestKey.publicKeyBase64,
  notesFile,
  output: candidateOutput,
  publishedAt: '2026-07-21T00:00:00Z',
  sparklePublicKeyBase64: sparkleKey.publicKeyBase64,
  updateServer: updateServerForScope('testing'),
  version: '1.1.0',
  windowsExe,
  windowsYml,
});
const appcast = await readFile(
  path.join(candidate.releaseRoot, 'macos', 'appcast.xml'),
  'utf8',
);
assert.match(
  appcast,
  /http:\/\/192\.168\.10\.54:18080\/codex-session-keeper\/testing\/macos\//,
);
assert.doesNotMatch(appcast, /\/stable\/macos\//);
```

The signed `release.json` field `channel` remains `stable`; only the isolated
server root and Appcast download prefix change.

Change the test helper signature to:

```javascript
function signedAppcast({
  version,
  build,
  zipName,
  zipBytes,
  privateKeyPem,
  downloadPrefix = UPDATE_SERVER.macDownloadPrefix,
}) {
  const enclosureSignature = signManifest(zipBytes, privateKeyPem);
  const prefix = Buffer.from(
    `<?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><title>${version}</title><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${version}</sparkle:shortVersionString><enclosure url="${downloadPrefix}${zipName}" length="${zipBytes.length}" type="application/octet-stream" sparkle:edSignature="${enclosureSignature}"></enclosure></item></channel></rss>`,
  );
  const feedSignature = signManifest(prefix, privateKeyPem);
  return Buffer.concat([
    prefix,
    Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${feedSignature}\nlength: ${prefix.length}\n-->\n`),
  ]);
}
```

- [ ] **Step 2: Add a failing candidate publisher test**

Add to `build-download-page.test.mjs`:

```javascript
test('candidate publication cannot replace the employee page', () => {
  const source = readFileSync(publishScriptPath, 'utf8');
  assert.match(source, /--candidate/);
  assert.match(source, /PUBLISH_PAGE=0/);
  assert.match(source, /if \[\[ "\$PUBLISH_PAGE" == 1 \]\]/);
});
```

- [ ] **Step 3: Run both focused tests and verify failure**

Run:

```bash
node --test \
  scripts/update/release-manifest.test.mjs \
  scripts/update/build-download-page.test.mjs
```

Expected: FAIL because candidate server selection and publisher mode are absent.

- [ ] **Step 4: Parameterize release assembly with an exact server descriptor**

In `build-release-manifest.mjs`:

```javascript
export async function assembleRelease({
  build,
  generateAppcast = defaultGenerateAppcast,
  macZip,
  manifestPrivateKeyPem,
  manifestPublicKeyBase64,
  notesFile,
  output,
  publishedAt = new Date().toISOString(),
  sparklePublicKeyBase64,
  updateServer = UPDATE_SERVER,
  version,
  windowsExe,
  windowsYml,
}) {
  if (![UPDATE_SERVERS.stable, UPDATE_SERVERS.testing].includes(updateServer)) {
    throw new Error('updateServer must be a declared stable or testing server');
  }
  const releaseRoot = path.join(
    output,
    'codex-session-keeper',
    updateServer.scope,
  );
  const macDirectory = path.join(releaseRoot, 'macos');
  const windowsDirectory = path.join(releaseRoot, 'windows');

  await generateAppcast({
    build,
    downloadPrefix: updateServer.macDownloadPrefix,
    macDirectory,
    version,
    zipBytes,
    zipName: macName,
  });

  const verified = await verifyReleaseDirectory(
    releaseRoot,
    manifestPublicKey,
    { sparklePublicKeyBase64: sparklePublicKey },
  );
  return {
    releaseRoot,
    stableRoot: releaseRoot,
    verified,
  };
}
```

Pass `downloadPrefix: updateServer.macDownloadPrefix` to every
`generateAppcast()` callback, including the production default. The default
callback must pass that prefix to Sparkle's `generate_appcast` as the
`--download-url-prefix` value.

Keep `stableRoot` as an alias in the return value so existing callers and tests
remain compatible.

Add the required CLI pair:

```text
--server-scope stable
```

or:

```text
--server-scope testing
```

Resolve it only through `updateServerForScope()`. Do not accept arbitrary URLs.

- [ ] **Step 5: Add candidate mode to the atomic publisher**

At the beginning of `publish-release.sh`:

```bash
PUBLISH_PAGE=1
if [[ "${1:-}" == "--candidate" ]]; then
  PUBLISH_PAGE=0
  shift
fi
```

Keep the existing two absolute-path arguments after the optional flag. Wrap only
the download-page build and publish block:

```bash
if [[ "$PUBLISH_PAGE" == 1 ]]; then
  SITE_ROOT="$(dirname "$DESTINATION_ROOT")"
  DOWNLOAD_PAGE="$INCOMING_ROOT/index.html"
  node "$SCRIPT_DIR/build-download-page.mjs" \
    --stable-root "$DESTINATION_ROOT" \
    --output "$DOWNLOAD_PAGE"
  fsync_file "$DOWNLOAD_PAGE"
  publish_metadata "$DOWNLOAD_PAGE" "$SITE_ROOT/index.html"
fi
```

All artifact verification, same-filesystem checks, symlink checks, immutable
versioned-file checks, fsync calls, and atomic metadata replacements remain
active in candidate mode.

- [ ] **Step 6: Run the focused and full Node suites**

Run:

```bash
node --test \
  scripts/update/release-manifest.test.mjs \
  scripts/update/build-download-page.test.mjs
node --test scripts/update/*.test.mjs
```

Expected: both commands exit `0`.

- [ ] **Step 7: Commit candidate publishing**

```bash
git add \
  scripts/update/build-release-manifest.mjs \
  scripts/update/release-manifest.test.mjs \
  scripts/update/publish-release.sh \
  scripts/update/build-download-page.test.mjs
git commit -m "feat: isolate macOS update candidates"
```

---

### Task 6: Build and cryptographically verify the two macOS versions

**Files:**
- Read: `Config/UpdateKeys.json`
- Read: `release-notes/1.1.0.json`
- Produce: `dist/macos/*.zip`
- Produce: `dist/macos/*.dmg`
- Produce: a fresh temporary candidate release directory

**Interfaces:**
- Consumes the existing Windows `1.1.0` installer and `latest.yml`
- Produces a verified `testing` release tree

- [ ] **Step 1: Run all tests from a clean source tree**

Run:

```bash
swift test
node --test scripts/update/*.test.mjs
git status --short
```

Expected: both suites exit `0`; status is empty before building.

- [ ] **Step 2: Build the candidate baseline**

Run:

```bash
APP_VERSION=1.0.99 APP_BUILD=10099 UPDATE_SCOPE=testing ./scripts/build_app.sh
```

Expected: verified `1.0.99` ZIP and DMG are created with a testing feed URL.

- [ ] **Step 3: Preserve baseline hashes before building the target**

Run:

```bash
shasum -a 256 \
  dist/macos/CodexSessionKeeper-1.0.99-macos-arm64.zip \
  dist/macos/CodexSessionKeeper-1.0.99-macos-arm64.dmg
```

Expected: two SHA-256 values are printed and copied into the validation record.

- [ ] **Step 4: Build the stable-configured target**

Run:

```bash
APP_VERSION=1.1.0 APP_BUILD=10100 UPDATE_SCOPE=stable ./scripts/build_app.sh
```

Expected: verified `1.1.0` ZIP and DMG are created with the stable feed URL.

- [ ] **Step 5: Verify keys without outputting private material**

Run:

```bash
swift package resolve
test -x .build/artifacts/sparkle/Sparkle/bin/generate_appcast
test -x .build/artifacts/sparkle/Sparkle/bin/generate_keys
/usr/bin/security find-generic-password \
  -a release \
  -s "CodexSessionKeeper Update Manifest Ed25519" >/dev/null
```

Expected: Sparkle tools and the manifest signing keychain item are present.
Keychain access, if prompted, is approved by the user. Never add `-w` to this
inspection command because that would print the private key material.

- [ ] **Step 6: Assemble the testing release**

Create a fresh directory and run:

```bash
CANDIDATE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/codex-macos-candidate.XXXXXX")"
CANDIDATE_OUTPUT="$CANDIDATE_PARENT/release"
test ! -e "$CANDIDATE_OUTPUT"
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip" \
  --windows-exe "/Users/mqzj/Downloads/CodexSessionKeeper-Windows-builds-01c27be-20260723-105726/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "/Users/mqzj/Downloads/CodexSessionKeeper-Windows-builds-01c27be-20260723-105726/latest.yml" \
  --notes-file "$PWD/release-notes/1.1.0.json" \
  --server-scope testing \
  --output "$CANDIDATE_OUTPUT"
```

Expected: exit `0`, verified version `1.1.0`, build `10100`, and a release root
under `codex-session-keeper/testing`.

- [ ] **Step 7: Verify artifact identity**

Run:

```bash
shasum -a 256 \
  dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip \
  dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.dmg \
  /Users/mqzj/Downloads/CodexSessionKeeper-Windows-builds-01c27be-20260723-105726/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
```

Expected:

- Windows hash remains
  `6A9C27A10EE9EDC3EBF59C83D4E5283F197DBAFAC7187B7832B147B55264A9A9`.
- Mac hashes are recorded for transfer and post-transfer comparison.

- [ ] **Step 8: Confirm the build did not modify source**

Run:

```bash
git status --short
```

Expected: no tracked changes and no unexpected untracked source files. Build
outputs under ignored directories are allowed.

---

### Task 7: Publish only the candidate tree to the Mac mini

**Files:**
- Transfer: verified candidate release tree
- Transfer: `scripts/update/publish-release.sh`
- Remote destination: `/Users/Shared/codex-update-site/codex-session-keeper/testing`

**Interfaces:**
- Consumes: candidate release root from Task 6
- Produces: read-only HTTP candidate endpoints

- [ ] **Step 1: Re-establish a bounded SSH control connection**

The user enters the SSH password directly. Use a dedicated socket with a bounded
persist duration and verify it with:

```bash
ssh -S /tmp/codex-fwq-192.168.10.54-macos.sock \
  -O check fwq@192.168.10.54
```

Expected: `Master running`.

- [ ] **Step 2: Inspect the remote candidate destination before writing**

Run read-only checks for:

```text
/Users/Shared/codex-update-site/.codex-update-root
/Users/Shared/codex-update-site/codex-session-keeper/testing
```

Expected: marker value is `codex-session-keeper-update-root-v1`; no symlink is
present in the destination chain. Stop on any mismatch.

- [ ] **Step 3: Create only the isolated candidate destination**

After the marker and path checks pass, the user enters the administrator
password for:

```bash
/usr/bin/sudo /usr/bin/install -d \
  -o root \
  -g admin \
  -m 0775 \
  /Users/Shared/codex-update-site/codex-session-keeper/testing
```

Expected: the exact directory exists, is owned by `root:admin`, and has mode
`0775`. Do not change permissions on the stable directory or site root.

- [ ] **Step 4: Transfer to a new remote temporary directory**

Use `scp` over the control socket. Do not copy directly into the served tree.
After transfer, compare every Mac ZIP, Appcast, release manifest, signature, and
Windows installer SHA-256 with Task 6.

Expected: every transferred hash matches.

- [ ] **Step 5: Publish in candidate mode**

On the Mac mini run:

```bash
./publish-release.sh --candidate \
  /absolute/remote/verified/codex-session-keeper/testing \
  /Users/Shared/codex-update-site/codex-session-keeper/testing
```

Expected: publication exits `0`; it does not create or replace
`/Users/Shared/codex-update-site/codex-session-keeper/index.html`.

- [ ] **Step 6: Validate HTTP behavior**

Run with `/usr/bin/curl --noproxy '*'`:

```text
GET  /codex-session-keeper/testing/release.json                  → 200
GET  /codex-session-keeper/testing/release.json.sig              → 200
GET  /codex-session-keeper/testing/macos/appcast.xml             → 200
HEAD /codex-session-keeper/testing/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip → 200
POST /codex-session-keeper/testing/release.json                   → 405
```

Expected: exact statuses above; ZIP `Content-Length` matches Task 6.

- [ ] **Step 7: Regress the stable Windows endpoints**

Expected:

```text
stable/release.json → 200
stable/windows/latest.yml → 200
stable Windows Setup HEAD → 200 with 104653535 bytes
```

No stable file hash may change during candidate publication.

---

### Task 8: Perform the manual `1.0.99 → 1.1.0` Mac update

**Files and state:**
- Install manually: `CodexSessionKeeper-1.0.99-macos-arm64.dmg`
- Observe only: `~/.codex`
- Observe only: local incremental backup status and app update cache

**Interfaces:**
- Consumes: testing Appcast and candidate ZIP
- Produces: a complete human-confirmed acceptance record

- [ ] **Step 1: Capture the pre-install baseline**

Record without modifying data:

- existing installed application path, version, build, size, and SHA-256;
- active and archived session counts;
- local incremental backup status;
- running application processes;
- `git status --short`.

If another version is running, ask the user to quit it normally. Do not force
terminate it.

- [ ] **Step 2: Let the user install the 1.0.99 DMG**

The user mounts the DMG and drags the app into Applications. If Gatekeeper
blocks the first launch, the user performs the documented right-click “打开” or
“隐私与安全性 → 仍要打开” action. Do not remove quarantine attributes or alter
security settings.

- [ ] **Step 3: Verify the baseline before checking updates**

Expected:

- version `1.0.99`, build `10099`;
- main executable architecture exactly `arm64`;
- `SUFeedURL` points to `testing/macos/appcast.xml`;
- application opens without a white screen or crash;
- session counts and backup status match the pre-install baseline.

- [ ] **Step 4: Observe automatic discovery without clicking for the user**

Expected within the scheduled initial check:

- update prompt shows `1.1.0`;
- “稍后提醒” and “立即更新” are present;
- Nginx log shows manifest and signature reads;
- no ZIP GET occurs before the user clicks “立即更新”.

- [ ] **Step 5: User confirms download**

The user personally clicks “立即更新”.

Expected:

- ZIP GET begins only after the click;
- progress is shown;
- signature verification succeeds;
- the application reaches “版本 1.1.0 已准备好”;
- the application remains running until the second confirmation.

- [ ] **Step 6: User confirms restart and install**

The user personally clicks “重启并更新”.

Expected:

- local backup is drained before quit;
- Sparkle replaces the application;
- application relaunches as version `1.1.0`, build `10100`;
- the installed app now points to the stable Appcast for future checks.

- [ ] **Step 7: Complete post-update acceptance**

Verify:

- one main application instance;
- window renders normally;
- active plus archived session total is unchanged;
- incremental backup resumes and remains running;
- no session, snapshot, or backup was deleted or restored;
- manual “检查更新…” reports the current version as up to date;
- no NAS access occurred.

- [ ] **Step 8: Preserve evidence and stop before stable promotion**

Record:

- pre/post versions and hashes;
- ZIP/DMG/Appcast hashes;
- server access-log timeline;
- Gatekeeper prompts actually observed;
- session and backup counts;
- any Sparkle error.

Do not publish stable macOS files or the employee page in this task. Stable
promotion and the dual-platform employee page require the follow-up plan.

---

## Final Verification

Run:

```bash
swift test
node --test scripts/update/*.test.mjs
git status --short
```

Expected:

- all Swift and Node tests pass;
- working tree is clean;
- Mac candidate acceptance is documented as passed;
- stable Windows endpoints and hashes remain unchanged;
- stable macOS and employee page have not yet been modified.

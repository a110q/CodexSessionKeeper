# NAS LAN Auto Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `1.1.0` as the first employee-facing macOS arm64 and Windows x64 release with signed, user-confirmed updates served only from the company UGREEN NAS.

**Architecture:** A read-only Nginx container on the NAS serves one signed cross-platform release manifest plus Sparkle and Electron Builder feeds. Both clients verify the same Ed25519 manifest before offering an update, then delegate platform installation to Sparkle 2.9.4 or `electron-updater` 6.8.9; the app owns prompting, progress, and the five-second backup drain gate. Release tooling builds versioned artifacts first and publishes feed files last so clients never observe a half-published release.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, SwiftUI, CryptoKit, Sparkle 2.9.4, macOS 14 arm64; Electron 43.1.0, Node.js, `node:test`, Electron Builder 26.15.3, `electron-updater` 6.8.9, Windows 10 x64 NSIS; Docker Compose, `nginx:alpine`, Ed25519, SHA-256.

## Global Constraints

- The employee update base URL is exactly `http://192.168.10.99:18080/codex-session-keeper/stable/` and is reachable only on the company LAN.
- The first employee-facing release is `1.1.0`; `1.0.99` is a test bootstrap used only for update rehearsal and must never be placed in the employee download directory.
- Initial supported artifacts are macOS arm64 and Windows x64 only.
- Update checks start five seconds after the main window is ready and run at most once every eight hours.
- One update check, including both manifest and signature fetches, has one shared five-second timeout.
- NAS unavailability is silent and must not affect launch, session management, snapshots, restore, or incremental backup.
- Employees must click `立即更新` before download and `重启并更新` before the app intentionally quits for installation; the alternatives are `稍后提醒` and `稍后重启`.
- `required` remains in schema version 1 but the client must reject `required: true`; this release cannot force an update.
- The detached signature is Ed25519 over the exact UTF-8 bytes of `release.json`; artifact integrity is lowercase 64-character SHA-256 plus exact byte size.
- The manifest signing private key and Sparkle private key stay off the NAS; private keys are stored in the release Mac Keychain and have an encrypted offline backup.
- Do not add a NAS write API, WebDAV, SMB credentials, client upload, update telemetry, access logging, forced update, beta channel, or automatic retry loop.
- Nginx mounts the update directory read-only, disables directory listing and access logs, exposes host port `18080`, and uses `restart: unless-stopped`.
- macOS uses Sparkle 2.9.4 with `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`; Windows uses Electron Builder NSIS per-user install with `autoDownload = false` and `autoInstallOnAppQuit = false`.
- Without Apple Developer ID or Windows Authenticode certificates, first installation warnings are expected and must be documented rather than bypassed.
- Before intentional update restart, stop incremental backup and wait at most five seconds for the active scan/write; if it does not drain, resume backup and cancel installation.
- Preserve Electron `sandbox: true`, `contextIsolation: true`, `nodeIntegration: false`, trusted IPC sender validation, navigation guards, and renderer prohibition on arbitrary URLs or filesystem paths.
- A release is rolled back by rebuilding the old code under a higher semantic version and build number; never publish a lower version.
- Retain exactly the latest three stable versioned artifact sets on NAS, but never delete them from an automated client request.
- Keep `.codegraph/` untracked and out of every commit.

---

## File Structure

### Shared release protocol and publishing

- Create: `scripts/update/release-manifest.mjs`
  - Schema construction, validation, Ed25519 signing/verification, SHA-256, and stable JSON serialization.
- Create: `scripts/update/keychain.mjs`
  - Read and create the manifest signing key in macOS Keychain without writing private material into the repository.
- Create: `scripts/update/generate-update-keys.mjs`
  - Generate the Ed25519 manifest key and write only the raw public key into the tracked configuration.
- Create: `scripts/update/backup-update-keys.sh`
  - Export both Keychain secrets into one password-encrypted offline archive without leaving plaintext output.
- Create: `scripts/update/build-release-manifest.mjs`
  - Hash real macOS and Windows artifacts, build `release.json`, and write its detached signature.
- Create: `scripts/update/verify-release-directory.mjs`
  - Verify a fully staged release directory before NAS publication.
- Create: `scripts/update/publish-release.sh`
  - Copy versioned assets before feeds and perform same-filesystem atomic feed replacement.
- Create: `scripts/update/release-manifest.test.mjs`
  - Protocol, signature, validation, and tamper tests.
- Create during Task 1 and complete during Task 4: `Config/UpdateKeys.json`
  - Tracked public keys only: manifest raw public key first, then Sparkle EdDSA public key after Sparkle tooling is resolved.
- Modify: `.gitignore`
  - Exclude release staging output and any exported private-key backup.

### macOS update client

- Create: `Sources/CodexSessionVaultCore/Update/ReleaseManifest.swift`
  - Codable schema, strict validation, platform selection, and semantic version/build comparison.
- Create: `Sources/CodexSessionVaultCore/Update/UpdateCheckClient.swift`
  - Shared-deadline HTTP fetch, Ed25519 verification, and typed update result.
- Create: `Sources/CodexSessionVaultCore/Update/UpdatePresentationState.swift`
  - Pure, testable update-prompt state machine used by the macOS coordinator.
- Create: `Tests/CodexSessionVaultCoreTests/ReleaseManifestTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/UpdateCheckClientTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/UpdatePresentationStateTests.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
  - Add a waitable, timeout-bounded stop-and-drain operation.
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
  - Cover successful drain and timeout.
- Create: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`
  - Startup/eight-hour scheduling, local check timestamp, Sparkle ownership, state machine, completion marker, and backup gate.
- Create: `Sources/CodexSessionVault/Update/SparkleUpdateDriver.swift`
  - Complete `SPUUserDriver` adapter for the app-owned two-stage UI.
- Create: `Sources/CodexSessionVault/Update/UpdatePromptView.swift`
  - Exact Chinese prompt, progress, ready-to-restart, failure, and completion UI.
- Modify: `Sources/CodexSessionVault/main.swift`
  - Read bundle version, expose backup drain/restart, inject coordinator, attach the update overlay, and add `检查更新…`.
- Modify: `Package.swift`
  - Pin Sparkle 2.9.4 exactly and link it only into the executable target.
- Modify: `scripts/build_app.sh`
  - Parameterize version/build/feed/keys, embed Sparkle, add local-network/Sparkle plist keys, zip correctly, and ad-hoc sign the complete bundle.

### Windows update client

- Create: `windows/codex_session_manager_electron/src/update/release-manifest.js`
  - Strict schema, raw Ed25519 verification, version comparison, and artifact selection.
- Create: `windows/codex_session_manager_electron/src/update/update-state-store.js`
  - Atomic local `lastCheckAt`, pending version, and one-shot completion marker.
- Create: `windows/codex_session_manager_electron/src/update/update-service.js`
  - Manifest check, Electron updater lifecycle, artifact verification, state broadcasting, and backup-gated install.
- Create: `windows/codex_session_manager_electron/test/update/release-manifest.test.js`
- Create: `windows/codex_session_manager_electron/test/update/update-service.test.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
  - Add `stopAndDrain(timeoutMs)`.
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`
  - Cover drain and timeout.
- Modify: `windows/codex_session_manager_electron/src/main.js`
  - Instantiate the updater, schedule checks, register fixed-action IPC, and use `app.getVersion()`.
- Modify: `windows/codex_session_manager_electron/src/preload.js`
  - Expose fixed updater actions and sanitized state events.
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
  - Render the update state machine and exact user actions.
- Modify: `windows/codex_session_manager_electron/src/index.html`
  - Add the update dialog.
- Modify: `windows/codex_session_manager_electron/src/styles.css`
  - Style the update dialog and progress bar.
- Modify: `windows/codex_session_manager_electron/test/security/electron-security.test.js`
  - Assert sender validation and absence of URL/path IPC inputs.
- Modify: `windows/codex_session_manager_electron/package.json`
- Modify: `windows/codex_session_manager_electron/package-lock.json`
  - Replace Electron Packager with Electron Builder and add `electron-updater`.
- Create: `scripts/build_windows_installer.ps1`
  - Reproducible Windows x64 NSIS build on a Windows x64 release machine.
- Modify: `scripts/build_windows_exe.sh`
  - Fail with a migration message so the old portable package cannot be published accidentally.

### NAS deployment and operating documentation

- Create: `deploy/nas/docker-compose.yml`
- Create: `deploy/nas/nginx.conf`
- Create: `deploy/nas/codex-updates/.gitkeep`
- Create: `docs/NAS内网更新部署与发布.md`
- Modify: `README.md`
- Modify: `docs/操作手册.md`
- Modify: `windows/codex_session_manager_electron/README_WIN10_EXE.md`

---

### Task 1: Signed Release Manifest and Key Lifecycle

**Files:**
- Create: `scripts/update/release-manifest.mjs`
- Create: `scripts/update/keychain.mjs`
- Create: `scripts/update/generate-update-keys.mjs`
- Create: `scripts/update/backup-update-keys.sh`
- Create: `scripts/update/release-manifest.test.mjs`
- Create during this task: `Config/UpdateKeys.json`
- Modify: `.gitignore`

**Interfaces:**
- Produces `stableManifestBytes(manifest: object): Buffer`.
- Produces `validateManifest(manifest: object): object`.
- Produces `signManifest(bytes: Buffer, privateKeyPem: string): string` and `verifyManifest(bytes: Buffer, signatureBase64: string, publicKeyBase64: string): boolean`.
- Produces `sha256File(path: string): Promise<{ size: number, sha256: string }>`.
- Produces `readManifestPrivateKey(): string` and `ensureManifestKey(): { privateKeyPem: string, publicKeyBase64: string }` backed by Keychain service `CodexSessionKeeper Update Manifest Ed25519`, account `release`.
- Produces tracked `Config/UpdateKeys.json` containing `schemaVersion` and `manifestPublicKey`; Task 4 adds `sparklePublicEDKey`. No private key field is permitted at either stage.

- [ ] **Step 1: Write the failing protocol tests**

Create `scripts/update/release-manifest.test.mjs` with a valid fixture and tests for deterministic bytes, valid signature, one-byte tampering, bad schema, `required: true`, absolute/cross-origin URL, bad SHA-256, excessive notes, and missing platform:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import {
  stableManifestBytes,
  validateManifest,
  signManifest,
  verifyManifest,
} from './release-manifest.mjs';

const fixture = () => ({
  schemaVersion: 1,
  channel: 'stable',
  version: '1.1.0',
  build: 10100,
  publishedAt: '2026-07-21T00:00:00Z',
  required: false,
  notes: ['新增公司内网更新功能'],
  platforms: {
    'macos-arm64': { url: 'macos/CodexSessionKeeper-1.1.0-macos-arm64.zip', size: 12, sha256: 'a'.repeat(64) },
    'windows-x64': { url: 'windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe', size: 34, sha256: 'b'.repeat(64) },
  },
});

test('signs exact stable bytes and rejects tampering', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const bytes = stableManifestBytes(validateManifest(fixture()));
  const signature = signManifest(bytes, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  const rawPublicKey = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  assert.equal(verifyManifest(bytes, signature, rawPublicKey), true);
  bytes[bytes.length - 2] ^= 1;
  assert.equal(verifyManifest(bytes, signature, rawPublicKey), false);
});

test('rejects forced updates and unsafe artifact URLs', () => {
  assert.throws(() => validateManifest({ ...fixture(), required: true }), /required must be false/);
  const manifest = fixture();
  manifest.platforms['macos-arm64'].url = 'http://attacker.invalid/app.zip';
  assert.throws(() => validateManifest(manifest), /relative URL/);
});
```

- [ ] **Step 2: Run the manifest tests and verify RED**

Run:

```bash
node --test scripts/update/release-manifest.test.mjs
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `release-manifest.mjs`.

- [ ] **Step 3: Implement the protocol module**

Use Node built-ins only. Validation must return a deep-cloned value, reject unknown top-level/platform fields, require both exact platform keys, cap notes at 20 entries and 500 UTF-8 bytes each, and require relative URLs with no `..`, query, fragment, or leading slash. Build raw public keys into the standard Ed25519 SPKI prefix:

```js
import { createHash, createPublicKey, sign, verify } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';

const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SHA256 = /^[a-f0-9]{64}$/;
const PLATFORM_KEYS = ['macos-arm64', 'windows-x64'];

export function stableManifestBytes(manifest) {
  return Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
}

export function signManifest(bytes, privateKeyPem) {
  return sign(null, bytes, privateKeyPem).toString('base64');
}

export function verifyManifest(bytes, signatureBase64, publicKeyBase64) {
  const raw = Buffer.from(publicKeyBase64, 'base64');
  if (raw.length !== 32 || Buffer.from(signatureBase64, 'base64').length !== 64) return false;
  const key = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
  return verify(null, bytes, key, Buffer.from(signatureBase64, 'base64'));
}

export async function sha256File(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return { size: (await stat(path)).size, sha256: hash.digest('hex') };
}
```

Implement `validateManifest` around these exact field sets:

```js
const topFields = ['schemaVersion', 'channel', 'version', 'build', 'publishedAt', 'required', 'notes', 'platforms'];
const artifactFields = ['url', 'size', 'sha256'];
// schemaVersion === 1, channel === 'stable', VERSION.test(version),
// Number.isSafeInteger(build) && build > 0, valid canonical ISO timestamp,
// required === false, and Object.keys(platforms).sort() equals PLATFORM_KEYS.
```

Every failed condition must throw `new Error('Invalid release manifest: <specific reason>')`; tests assert stable reason fragments rather than a generic parse error.

- [ ] **Step 4: Implement manifest Keychain generation and public configuration**

Use `execFileSync` argument arrays, never a shell string. `ensureManifestKey()` checks Keychain first, generates Ed25519 only if absent, stores PKCS#8 PEM with `security add-generic-password -U`, and returns the raw 32-byte public key. `generate-update-keys.mjs` writes actual generated values, not sample key text:

```js
const output = { schemaVersion: 1, manifestPublicKey };
if (sparklePublicEDKey !== undefined) output.sparklePublicEDKey = sparklePublicEDKey;
await writeFile(configPath, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
```

The script requires the manifest key to decode to exactly 32 bytes. When Task 4 passes `--sparkle-public-key`, it also requires that key to decode to exactly 32 bytes before updating the same file. Add these ignore rules:

```gitignore
.release-staging/
*.update-private-key.pem
*.sparkle-private-key
```

Run the manifest generator on the release Mac:

```bash
node scripts/update/generate-update-keys.mjs
```

Expected: `Config/UpdateKeys.json` is created with the manifest public key, Keychain contains the manifest private key, and `rg -n "PRIVATE KEY|privateKey" Config/UpdateKeys.json` prints no matches.

Create `backup-update-keys.sh` with one required absolute output path. It must reject an existing output, export the manifest PEM with `security find-generic-password`, export the Sparkle seed with `generate_keys --account local.codex.session-manager -x`, stream both through `tar` and password-prompted AES-256 encryption, and clean a `mktemp -d` directory on every exit:

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && "$1" = /* ]] || { echo "usage: $0 /absolute/output.tar.enc" >&2; exit 2; }
OUTPUT="$1"
[[ ! -e "$OUTPUT" ]] || { echo "output already exists: $OUTPUT" >&2; exit 2; }
KEY_BACKUP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-update-keys.XXXXXX")"
trap 'rm -rf "$KEY_BACKUP_TMP"' EXIT
security find-generic-password -a release -s "CodexSessionKeeper Update Manifest Ed25519" -w > "$KEY_BACKUP_TMP/manifest-private.pem"
"$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_keys" --account local.codex.session-manager -x "$KEY_BACKUP_TMP/sparkle-private.key"
tar -C "$KEY_BACKUP_TMP" -cf - manifest-private.pem sparkle-private.key \
  | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$OUTPUT"
chmod 600 "$OUTPUT"
echo "$OUTPUT"
```

Do not run this export until the Sparkle key exists in Task 4 and the user has supplied/approved the mounted encrypted offline-backup destination.

- [ ] **Step 5: Run tests and secret scans**

Run:

```bash
node --test scripts/update/release-manifest.test.mjs
bash -n scripts/update/backup-update-keys.sh
git diff --check
git status --short
```

Expected: all manifest tests PASS; the backup script parses; diff check is clean; no generated private-key file appears in Git status.

- [ ] **Step 6: Commit**

```bash
git add .gitignore Config/UpdateKeys.json scripts/update
git commit -m "feat: add signed release manifest protocol"
```

### Task 2: Swift Manifest Validation and Five-Second Update Check

**Files:**
- Create: `Sources/CodexSessionVaultCore/Update/ReleaseManifest.swift`
- Create: `Sources/CodexSessionVaultCore/Update/UpdateCheckClient.swift`
- Create: `Sources/CodexSessionVaultCore/Update/UpdatePresentationState.swift`
- Create: `Tests/CodexSessionVaultCoreTests/ReleaseManifestTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/UpdateCheckClientTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/UpdatePresentationStateTests.swift`

**Interfaces:**
- Consumes the exact schema and raw 32-byte `manifestPublicKey` produced by Task 1.
- Produces `SemanticVersion.init(_:) throws` and `Comparable` conformance.
- Produces `ReleaseManifest.validated() throws -> ReleaseManifest` and `artifact(for: UpdatePlatform) throws -> ReleaseArtifact`.
- Produces `UpdatePlatform.macosArm64` and `.windowsX64`, encoded as the manifest keys.
- Produces `UpdateCheckClient.check(currentVersion:currentBuild:platform:) async -> UpdateCheckResult`.
- Produces `.available(manifest:artifact:)`, `.upToDate`, `.unavailable`, and `.invalid(message:)`; only `.invalid` is user-visible.
- Produces `UpdatePresentationMachine.apply(_:)` and exact states `.idle`, `.checking`, `.available`, `.downloading`, `.extracting`, `.ready`, `.installing`, `.failed`, `.upToDate`, and `.completed`.

- [ ] **Step 1: Write failing Swift protocol tests**

Use Swift Testing and an injected transport. The contract tests must include:

```swift
@Test func newerVersionIsAvailableAfterSignatureVerification() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let baseURL = URL(string: "http://192.168.10.99:18080/codex-session-keeper/stable/")!
    let manifestURL = baseURL.appendingPathComponent("release.json")
    let signatureURL = baseURL.appendingPathComponent("release.json.sig")
    let manifestData = try validManifestData(version: "1.1.0", build: 10100)
    let signature = try privateKey.signature(for: manifestData).base64EncodedData()
    let transport = StubUpdateTransport(responses: [manifestURL: manifestData, signatureURL: signature])
    let client = UpdateCheckClient(
        baseURL: baseURL,
        publicKey: privateKey.publicKey.rawRepresentation,
        transport: transport,
        timeout: .seconds(5)
    )
    let result = await client.check(currentVersion: "1.0.99", currentBuild: 10099, platform: .macosArm64)
    guard case .available(let manifest, let artifact) = result else {
        Issue.record("Expected available update"); return
    }
    #expect(manifest.version == "1.1.0")
    #expect(artifact.url.hasSuffix("macos-arm64.zip"))
}

@Test func tamperedManifestIsInvalid() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let baseURL = URL(string: "http://192.168.10.99:18080/codex-session-keeper/stable/")!
    let original = try validManifestData(version: "1.1.0", build: 10100)
    let signature = try privateKey.signature(for: original).base64EncodedData()
    var tampered = original
    tampered[tampered.startIndex] ^= 1
    let client = UpdateCheckClient(
        baseURL: baseURL,
        publicKey: privateKey.publicKey.rawRepresentation,
        transport: StubUpdateTransport(responses: [
            baseURL.appendingPathComponent("release.json"): tampered,
            baseURL.appendingPathComponent("release.json.sig"): signature,
        ]),
        timeout: .seconds(5)
    )
    #expect(await client.check(currentVersion: "1.0.99", currentBuild: 10099, platform: .macosArm64)
        == .invalid(message: "更新信息验证失败，请联系管理员"))
}
```

Define the test helpers in the same test file so no network is used:

```swift
private struct StubUpdateTransport: UpdateTransport {
    let responses: [URL: Data]
    func data(from url: URL) async throws -> Data {
        guard let data = responses[url] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

private func validManifestData(version: String, build: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1,
        "channel": "stable",
        "version": version,
        "build": build,
        "publishedAt": "2026-07-21T00:00:00Z",
        "required": false,
        "notes": ["新增公司内网更新功能"],
        "platforms": [
            "macos-arm64": ["url": "macos/CodexSessionKeeper-1.1.0-macos-arm64.zip", "size": 12, "sha256": String(repeating: "a", count: 64)],
            "windows-x64": ["url": "windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe", "size": 34, "sha256": String(repeating: "b", count: 64)],
        ],
    ], options: [.sortedKeys])
}
```

Also cover `1.10.0 > 1.9.9`, equal version/higher build, equal build, downgrade, invalid prerelease text, `required: true`, wrong platform, 31-byte public key, unavailable transport, and one shared deadline across the two fetches.

Add a reducer test that applies `.found`, `.downloadStarted`, `.downloadProgress`, `.extractionProgress`, `.downloadReady`, and `.installStarted` in order, asserting the exact associated version/byte/progress values at each state. Add separate failure, dismiss, up-to-date, and completion transitions.

- [ ] **Step 2: Run the focused Swift tests and verify RED**

Run:

```bash
swift test --filter 'ReleaseManifestTests|UpdateCheckClientTests|UpdatePresentationStateTests'
```

Expected: compilation fails because the `Update` types do not exist.

- [ ] **Step 3: Implement strict models and version comparison**

Define the public types exactly:

```swift
public enum UpdatePlatform: String, Codable, Sendable {
    case macosArm64 = "macos-arm64"
    case windowsX64 = "windows-x64"
}

public struct ReleaseArtifact: Codable, Equatable, Sendable {
    public let url: String
    public let size: Int64
    public let sha256: String
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channel: String
    public let version: String
    public let build: Int
    public let publishedAt: Date
    public let required: Bool
    public let notes: [String]
    public let platforms: [String: ReleaseArtifact]
}

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
}
```

`validated()` must mirror Task 1 rather than accepting what `Codable` can decode: exact schema/channel, `required == false`, two exact platform keys, positive safe build, 20/500-byte note limits, lowercase SHA-256, positive size, and safe relative artifact URL. Availability is:

```swift
let remote = try SemanticVersion(manifest.version)
let local = try SemanticVersion(currentVersion)
let isNewer = remote > local || (remote == local && manifest.build > currentBuild)
```

A remote version/build lower than local is `.invalid`, not `.upToDate`, because a published feed must never move backward.

- [ ] **Step 4: Implement exact-byte verification and a shared timeout**

Define the transport and result surface:

```swift
public protocol UpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    case timeout
    case invalidConfiguration
}

public enum UpdateCheckResult: Equatable, Sendable {
    case available(manifest: ReleaseManifest, artifact: ReleaseArtifact)
    case upToDate
    case unavailable
    case invalid(message: String)
}
```

Define the presentation types and machine as value types so transitions remain independent of Sparkle:

```swift
public enum UpdatePresentationState: Equatable, Sendable {
    case idle
    case checking
    case available(version: String, notes: [String])
    case downloading(version: String, received: UInt64, total: UInt64?)
    case extracting(version: String, progress: Double)
    case ready(version: String)
    case installing(version: String)
    case failed(message: String)
    case upToDate(version: String)
    case completed(version: String)
}

public enum UpdatePresentationEvent: Equatable, Sendable {
    case checkStarted
    case found(version: String, notes: [String])
    case downloadStarted(version: String)
    case downloadProgress(version: String, received: UInt64, total: UInt64?)
    case extractionProgress(version: String, progress: Double)
    case downloadReady(version: String)
    case installStarted(version: String)
    case failed(message: String)
    case upToDate(version: String)
    case completed(version: String)
    case dismiss
}

public struct UpdatePresentationMachine: Equatable, Sendable {
    public private(set) var state: UpdatePresentationState = .idle
    public mutating func apply(_ event: UpdatePresentationEvent) {
        switch event {
        case .checkStarted: state = .checking
        case .found(let version, let notes): state = .available(version: version, notes: notes)
        case .downloadStarted(let version): state = .downloading(version: version, received: 0, total: nil)
        case .downloadProgress(let version, let received, let total): state = .downloading(version: version, received: received, total: total)
        case .extractionProgress(let version, let progress): state = .extracting(version: version, progress: progress)
        case .downloadReady(let version): state = .ready(version: version)
        case .installStarted(let version): state = .installing(version: version)
        case .failed(let message): state = .failed(message: message)
        case .upToDate(let version): state = .upToDate(version: version)
        case .completed(let version): state = .completed(version: version)
        case .dismiss: state = .idle
        }
    }
}
```

Clamp extraction progress to `0...1` and require monotonic received bytes in the coordinator before emitting events.

`UpdateCheckClient` starts one throwing task group for the entire operation: one child performs both sequential GETs, the other sleeps for five seconds and throws `UpdateCheckError.timeout`; cancel the remaining child after the first completes. Parse only after:

```swift
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
guard publicKey.isValidSignature(signatureData, for: manifestData) else {
    return .invalid(message: "更新信息验证失败，请联系管理员")
}
let manifest = try decoder.decode(ReleaseManifest.self, from: manifestData).validated()
```

Map timeout, cancellation, connection refused, and HTTP non-2xx to `.unavailable`; map key, signature, schema, downgrade, and artifact validation failures to the exact `.invalid` message above. Configure the production `URLSession` as ephemeral with no cookies, no cache, and `timeoutIntervalForRequest = 5`.

- [ ] **Step 5: Run the focused and full Swift test suites**

Run:

```bash
swift test --filter 'ReleaseManifestTests|UpdateCheckClientTests'
swift test
```

Expected: focused tests PASS and the complete Swift suite PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexSessionVaultCore/Update Tests/CodexSessionVaultCoreTests/ReleaseManifestTests.swift Tests/CodexSessionVaultCoreTests/UpdateCheckClientTests.swift Tests/CodexSessionVaultCoreTests/UpdatePresentationStateTests.swift
git commit -m "feat: verify signed update manifests on macOS"
```

### Task 3: Timeout-Bounded macOS Backup Drain

**Files:**
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift:16-154`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
- Modify: `Sources/CodexSessionVault/main.swift:358-560`

**Interfaces:**
- Produces `BackupAgent.stopAndDrain(timeout: Duration) async -> Bool`.
- Produces `@MainActor VaultModel.prepareForUpdate(timeout: Duration) async -> Bool`.
- Preserves existing `stop()` and `startPolling(intervalSeconds:)` behavior.
- On timeout, `VaultModel` restarts polling at ten seconds and restarts lightweight backup-status refresh before returning `false`.

- [ ] **Step 1: Write failing drain tests**

Add one fast success test and one deterministic timeout test. The timeout test blocks the existing injected `now` closure inside a scan, starts `stopAndDrain(timeout: .milliseconds(50))`, expects `false`, then releases the scan and proves the agent can resume:

```swift
@Test func stopAndDrainTimesOutWithoutAbandoningActiveScan() async throws {
    let fixture = try BackupAgentFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let agent = BackupAgent(paths: fixture.paths, now: {
        entered.signal()
        release.wait()
        return fixture.now
    })
    let scan = Task.detached { try agent.performOneShotScan() }
    #expect(entered.wait(timeout: .now() + 1) == .success)
    #expect(await agent.stopAndDrain(timeout: .milliseconds(50)) == false)
    release.signal()
    try await scan.value
    #expect(await agent.stopAndDrain(timeout: .seconds(1)) == true)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter BackupAgentTests
```

Expected: compilation fails because `stopAndDrain` does not exist.

- [ ] **Step 3: Implement a one-shot drain gate**

Keep the existing `scanLock` serialization. `stopAndDrain` calls `stop()`, dispatches a waiter that locks/unlocks `scanLock`, and races it against `asyncAfter` through a lock-protected one-shot continuation so timeout returns without waiting for the blocked queue item:

```swift
private final class DrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if let result { continuation.resume(returning: result) }
            else { self.continuation = continuation }
        }
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

public func stopAndDrain(timeout: Duration = .seconds(5)) async -> Bool {
    stop()
    let gate = DrainGate()
    DispatchQueue.global(qos: .utility).async { [scanLock] in
        scanLock.lock(); scanLock.unlock(); gate.finish(true)
    }
    let clock = ContinuousClock()
    Task.detached {
        try? await clock.sleep(for: timeout)
        gate.finish(false)
    }
    return await gate.wait()
}
```

Before each polling scan, add a second `guard !Task.isCancelled else { break }` immediately before `performOneShotScan()` so a canceled polling task cannot begin a new scan after the drain waiter is queued.

- [ ] **Step 4: Add the VaultModel update gate**

Replace the hardcoded `appVersion` with `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"`. Add:

```swift
@MainActor
func prepareForUpdate(timeout: Duration = .seconds(5)) async -> Bool {
    localBackupStatusTask?.cancel()
    localBackupStatusTask = nil
    guard let agent = localBackupAgent else { return true }
    let drained = await agent.stopAndDrain(timeout: timeout)
    if !drained {
        agent.startPolling(intervalSeconds: 10)
        startLocalBackupStatusPolling()
    }
    return drained
}
```

Create the exact private helper `startLocalBackupStatusPolling()` by extracting the status-task body currently installed by `startLocalIncrementalBackup()`. Both startup and timeout recovery must call that helper.

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter BackupAgentTests
swift test
```

Expected: drain tests PASS and the complete Swift suite PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexSessionVaultCore/Backup/BackupAgent.swift Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift Sources/CodexSessionVault/main.swift
git commit -m "feat: drain macOS backups before updating"
```

### Task 4: Sparkle Integration and macOS Update UI

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`
- Create: `Sources/CodexSessionVault/Update/SparkleUpdateDriver.swift`
- Create: `Sources/CodexSessionVault/Update/UpdatePromptView.swift`
- Modify: `Sources/CodexSessionVault/main.swift:4612-4665`
- Modify: `scripts/build_app.sh`

**Interfaces:**
- Consumes `UpdateCheckClient`, `UpdateCheckResult`, and `VaultModel.prepareForUpdate(timeout:)`.
- Produces `@MainActor MacUpdateCoordinator: ObservableObject` with `state`, `start()`, `checkNow()`, `remindLater()`, `beginDownload()`, `restartAndInstall()`, and `deferRestart()`.
- Consumes `UpdatePresentationMachine` and its states from Task 2 rather than duplicating UI transition logic in the app target.
- Produces a complete `SparkleUpdateDriver: NSObject, SPUUserDriver` and one `SPUUpdater` initialized with the app bundle as host/application bundle.

- [ ] **Step 1: Pin Sparkle and verify dependency resolution**

Modify `Package.swift` with the exact dependency/product:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
```

and add `.product(name: "Sparkle", package: "Sparkle")` only to the `CodexSessionVault` executable target dependencies.

Run:

```bash
swift package resolve
swift build
```

Expected: Sparkle 2.9.4 resolves and the existing app builds before source integration.

Generate or reuse a Sparkle key under a project-specific Keychain account, read only its public half with Sparkle's `-p` mode, and add it to the tracked public configuration:

```bash
SPARKLE_TOOLS="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_TOOLS/generate_keys" --account local.codex.session-manager
SPARKLE_PUBLIC_ED_KEY="$("$SPARKLE_TOOLS/generate_keys" --account local.codex.session-manager -p)"
node scripts/update/generate-update-keys.mjs --sparkle-public-key "$SPARKLE_PUBLIC_ED_KEY"
```

Expected: `Config/UpdateKeys.json` now contains exactly `schemaVersion`, `manifestPublicKey`, and `sparklePublicEDKey`; both public keys decode to 32 bytes, while both private keys remain in Keychain.

- [ ] **Step 2: Implement the coordinator state machine**

The coordinator owns one `UpdatePresentationMachine`, one timer task, one `SPUUpdater`, one driver, one pending ready reply, and `@Published private(set) var isPresented`. It publishes the imported machine state with these exact payloads:

```swift
public enum UpdatePresentationState: Equatable, Sendable {
    case idle
    case checking
    case available(version: String, notes: [String])
    case downloading(version: String, received: UInt64, total: UInt64?)
    case extracting(version: String, progress: Double)
    case ready(version: String)
    case installing(version: String)
    case failed(message: String)
    case upToDate(version: String)
    case completed(version: String)
}
```

This block repeats Task 2's public contract for the task implementer; Task 4 imports it from `CodexSessionVaultCore` and must not redeclare it.

`start()` checks an atomic marker under the existing local vault root, waits five seconds, calls `check(silentUnavailable: true)`, and then schedules the next check no earlier than eight hours after persisted `lastCheckAt`. Persist only these fields:

```json
{"lastCheckAt":"2026-07-21T00:00:00Z","pendingVersion":"1.1.0"}
```

Write the file atomically with same-directory temporary file plus rename. `checkNow()` may show `已是最新版本` through `.upToDate(version: currentVersion)`; scheduled checks leave `.upToDate` and `.unavailable` idle.

- [ ] **Step 3: Implement every required SPUUserDriver callback**

`SparkleUpdateDriver` must implement the non-optional methods from Sparkle 2.9.4. Use these exact Swift-imported responsibilities:

```swift
func showUpdatePermissionRequest(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
}

func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    coordinator.acceptSparkleItem(version: appcastItem.displayVersionString, reply: reply)
}

func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    coordinator.setDownloadTotal(expectedContentLength)
}

func showDownloadDidReceiveData(ofLength length: UInt64) {
    coordinator.addDownloadedBytes(length)
}

func showExtractionReceivedProgress(_ progress: Double) {
    coordinator.setExtractionProgress(progress)
}

func showReadyToInstallAndRelaunch(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
    coordinator.holdReadyReply(reply)
}
```

Complete every remaining callback with this exact mapping:

| Sparkle callback | Required action |
|---|---|
| `showUserInitiatedUpdateCheckWithCancellation` | Store the cancellation block and emit `.checkStarted`. |
| `showUpdateReleaseNotesWithDownloadData` | Return immediately because signed JSON notes are already displayed. |
| `showUpdateReleaseNotesFailedToDownloadWithError` | Return immediately for the same reason. |
| `showUpdateNotFoundWithError:acknowledgement:` | Emit `.upToDate(currentVersion)` for a manual check, then invoke acknowledgement once. |
| `showUpdaterError:acknowledgement:` | Emit `.failed("更新失败，请稍后重试")`, then invoke acknowledgement once. |
| `showDownloadInitiatedWithCancellation` | Store the cancellation block and emit `.downloadStarted(targetVersion)`. |
| `showDownloadDidStartExtractingUpdate` | Emit `.extractionProgress(targetVersion, 0)`. |
| `showInstallingUpdateWithApplicationTerminated:retryTerminatingApplication:` | Emit `.installStarted(targetVersion)`; retain retry only while the app is still running. |
| `showUpdateInstalledAndRelaunched:acknowledgement:` | Emit `.completed(targetVersion)`, then invoke acknowledgement once. |
| `dismissUpdateInstallation` | Clear stored callbacks. If `deferredReady == true`, keep `.ready` and keep the overlay hidden; otherwise emit `.dismiss` unless current state is `.completed`. |
| `showUpdateInFocus` | Activate the app and reveal the update overlay. |

All acknowledgement/reply blocks are one-shot: set the stored property to `nil` before invoking it. Release notes are already present in signed JSON, so Sparkle release-note bytes never enter the UI.

When `beginDownload()` is called, set `installRequested = true` and call `updater.checkForUpdates()`. The next matching `showUpdateFound` replies `.install` without a second prompt. `showReadyToInstallAndRelaunch` stores its reply, emits `.ready`, and sets `isPresented = true`. `deferRestart()` sets `deferredReady = true`, sets `isPresented = false`, replies `.dismiss`, and keeps `.ready` locally. A later manual `检查更新…` while state is ready only sets `isPresented = true`; it does not redownload. `restartAndInstall()` first awaits `VaultModel.prepareForUpdate(.seconds(5))`; on success it writes `pendingVersion` and replies `.install`, or re-enters `checkForUpdates()` with an already-drained flag if the earlier reply was dismissed. On drain failure it sets `.failed(message: "备份仍在写入，已取消更新重启，请稍后重试")`.

- [ ] **Step 4: Build the exact SwiftUI update overlay**

`UpdatePromptView` is rendered only while `coordinator.isPresented == true`, switches over `UpdatePresentationState`, and uses exactly these buttons:

```swift
HStack {
    Button("稍后提醒", action: coordinator.remindLater)
    Button("立即更新", action: coordinator.beginDownload)
        .buttonStyle(.borderedProminent)
}

HStack {
    Button("稍后重启", action: coordinator.deferRestart)
    Button("重启并更新") { Task { await coordinator.restartAndInstall() } }
        .buttonStyle(.borderedProminent)
}
```

The download view shows `ProgressView(value:total:)` when total is known and an indeterminate progress view otherwise. Notes are plain text and capped by the manifest validator. Failures offer `知道了`; completion displays `已更新到 X.Y.Z` once and clears the marker on acknowledgement.

- [ ] **Step 5: Wire app lifecycle and manual check**

In `CodexSessionVaultApp`, create the coordinator after the `VaultModel` using a custom initializer and inject both environment objects. Attach a single overlay/sheet at the `ContentView` root and call `coordinator.start()` once from `.task`. Add `检查更新…` to the existing command menu and call `checkNow()`.

Use the bundle values rather than another hardcoded version:

```swift
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
```

Do not call Sparkle's own automatic scheduler; set `automaticallyChecksForUpdates = false` and `automaticallyDownloadsUpdates = false` before `startUpdater`.

- [ ] **Step 6: Parameterize and verify the macOS bundle**

`scripts/build_app.sh` requires these inputs, defaulting only version/build for local development:

```bash
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD="${APP_BUILD:-10100}"
UPDATE_BASE_URL="${UPDATE_BASE_URL:-http://192.168.10.99:18080/codex-session-keeper/stable/}"
UPDATE_KEYS="$ROOT_DIR/Config/UpdateKeys.json"
```

Read both public keys from `Config/UpdateKeys.json` with `/usr/bin/plutil` after converting JSON to a temporary plist. Write these Info.plist keys: `CFBundleVersion`, `CFBundleShortVersionString`, `SUFeedURL` ending `macos/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks=false`, `SUAllowsAutomaticUpdates=false`, `SURequireSignedFeed=true`, `SUVerifyUpdateBeforeExtraction=true`, and `NSAppTransportSecurity/NSAllowsLocalNetworking=true`.

Copy the resolved `Sparkle.framework` into `Contents/Frameworks`, add `@executable_path/../Frameworks` rpath if absent, sign nested Sparkle services/helpers before ad-hoc signing the app, and create the archive with `ditto -c -k --sequesterRsrc --keepParent`. Output exactly:

```text
dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip
```

- [ ] **Step 7: Test and inspect the macOS build**

Run:

```bash
swift test
APP_VERSION=1.0.99 APP_BUILD=10099 scripts/build_app.sh
plutil -p "dist/codex_会话管理.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/codex_会话管理.app"
otool -L "dist/codex_会话管理.app/Contents/MacOS/CodexSessionVault" | rg Sparkle
```

Expected: tests PASS; plist shows `1.0.99`, build `10099`, LAN feed, and signature flags; codesign verification succeeds; `otool` resolves `@rpath/Sparkle.framework`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Package.resolved Sources/CodexSessionVault/Update Sources/CodexSessionVault/main.swift scripts/build_app.sh
git commit -m "feat: add user-confirmed Sparkle updates"
```

### Task 5: Timeout-Bounded Windows Backup Drain

**Files:**
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js:29-80`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`

**Interfaces:**
- Produces `BackupAgent.stopAndDrain(timeoutMs = 5000): Promise<boolean>`.
- Preserves `stopPolling()` for existing callers.
- `stopAndDrain` waits for the current `scanPromise`, including its queued pass, but never longer than `timeoutMs`.

- [ ] **Step 1: Write failing Node tests**

Use a deferred scan method so the tests do not depend on filesystem speed:

```js
test('stopAndDrain waits for the in-flight scan', async (t) => {
  const { paths } = await makeTestPaths(t);
  const agent = new BackupAgent({ paths, now: makeClock() });
  let release;
  agent.performOneShotScanLocked = () => new Promise((resolve) => { release = resolve; });
  const scan = agent.performOneShotScan();
  assert.equal(typeof release, 'function');
  const draining = agent.stopAndDrain(500);
  release();
  assert.equal(await draining, true);
  await scan;
});

test('stopAndDrain returns false at its deadline', async (t) => {
  const { paths } = await makeTestPaths(t);
  const agent = new BackupAgent({ paths, now: makeClock() });
  agent.performOneShotScanLocked = () => new Promise(() => {});
  void agent.performOneShotScan();
  assert.equal(await agent.stopAndDrain(20), false);
});
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/agent.test.js
```

Expected: FAIL because `stopAndDrain` is not a function.

- [ ] **Step 3: Implement the drain race**

Add:

```js
async stopAndDrain(timeoutMs = 5000) {
  this.stopPolling();
  const active = this.scanPromise;
  if (!active) return true;
  let timer;
  try {
    return await Promise.race([
      active.then(() => true, () => true),
      new Promise((resolve) => { timer = setTimeout(() => resolve(false), timeoutMs); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
```

Do not clear `scanQueued` during drain: queued work may contain a pending manifest write and must finish before success.

- [ ] **Step 4: Run focused and full Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/agent.test.js
npm test
```

Expected: all backup tests PASS and the complete Electron test suite PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/test/backup/agent.test.js
git commit -m "feat: drain Windows backups before updating"
```

### Task 6: Windows Signed Update Service

**Files:**
- Create: `windows/codex_session_manager_electron/src/update/release-manifest.js`
- Create: `windows/codex_session_manager_electron/src/update/update-state-store.js`
- Create: `windows/codex_session_manager_electron/src/update/update-service.js`
- Create: `windows/codex_session_manager_electron/test/update/release-manifest.test.js`
- Create: `windows/codex_session_manager_electron/test/update/update-service.test.js`
- Modify: `windows/codex_session_manager_electron/package.json`
- Modify: `windows/codex_session_manager_electron/package-lock.json`

**Interfaces:**
- Consumes the Task 1 schema and `Config/UpdateKeys.json` public key bundled as an Electron extra resource.
- Consumes `BackupAgent.stopAndDrain(timeoutMs)` from Task 5.
- Produces `parseAndVerifyManifest(manifestBytes, signatureBytes, publicKeyBase64)` and `selectUpdate(manifest,currentVersion,currentBuild,'windows-x64')`; `currentBuild` comes from the validated integer `package.json.updateBuild` field.
- Produces `UpdateStateStore.read()`, `.write(patch)`, `.consumeCompletion(currentVersion)`, and `.markPending(version)`.
- Produces `UpdateService.start()`, `.check({ manual })`, `.download()`, `.deferRestart()`, `.restartAndInstall()`, `.getState()`, and `.dispose()`.

- [ ] **Step 1: Install exact updater dependencies**

Run from the Windows app directory:

```bash
npm uninstall @electron/packager
npm install --save electron-updater@6.8.9
npm install --save-dev electron-builder@26.15.3
```

Expected: `package-lock.json` updates, `@electron/packager` disappears, and Electron remains `^43.1.0`.

- [ ] **Step 2: Write failing manifest and service tests**

Use generated Ed25519 keys, fake fetch responses, a fake updater EventEmitter, a fake BrowserWindow sender, a fake state store, a fake backup agent, and a temporary downloaded file. Assert this exact state flow:

```js
assert.deepEqual(service.getState(), { phase: 'idle' });
await service.check({ manual: false });
assert.equal(service.getState().phase, 'available');
await service.download();
updater.emit('download-progress', { transferred: 5, total: 10, percent: 50 });
assert.equal(service.getState().phase, 'downloading');
updater.emit('update-downloaded', { downloadedFile: installerPath, version: '1.1.0' });
await service.waitForVerificationForTest();
assert.equal(service.getState().phase, 'ready');
```

Also assert: NAS timeout remains idle for scheduled checks; manual timeout becomes a non-blocking failure; tampered manifest is visible invalid; `required: true` is invalid; latest.yml version must equal signed manifest version; wrong size/hash deletes the temporary installer and never exposes ready; install calls backup drain first; drain timeout restarts polling and never calls `quitAndInstall`; successful install writes pending marker before `quitAndInstall(false, true)`.

- [ ] **Step 3: Run the update tests and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/update/*.test.js
```

Expected: FAIL because the update modules do not exist.

- [ ] **Step 4: Implement Windows manifest verification**

Use Node `crypto.verify(null, bytes, key, signature)` with the same SPKI prefix as Task 1. Validate raw bytes before `JSON.parse`, then mirror every Task 1 constraint. Version comparison accepts only three numeric components and compares integers, never strings.

Export this exact result contract:

```js
{ status: 'available', manifest, artifact }
{ status: 'up-to-date' }
{ status: 'invalid', message: '更新信息验证失败，请联系管理员' }
```

Connection/timeout classification belongs in `UpdateService`, not this pure module.

- [ ] **Step 5: Implement atomic state and completion markers**

Store `update-state.json` under the existing local vault root, not under the application install directory. Its schema is:

```json
{
  "schemaVersion": 1,
  "lastCheckAt": "2026-07-21T00:00:00.000Z",
  "pendingVersion": "1.1.0"
}
```

Write to `update-state.json.tmp-<pid>`, fsync the file, close, and rename. On launch, if `pendingVersion === app.getVersion()`, return `{ phase: 'completed', version }` once and atomically clear `pendingVersion`. Invalid/missing state is treated as empty and recorded in the existing local diagnostic log.

- [ ] **Step 6: Implement the Electron updater state machine**

Initialize:

```js
const WINDOWS_FEED_URL = 'http://192.168.10.99:18080/codex-session-keeper/stable/windows/';
autoUpdater.autoDownload = false;
autoUpdater.autoInstallOnAppQuit = false;
autoUpdater.allowDowngrade = false;
```

For manifest fetch, create one `AbortController`, start one five-second timer before `release.json`, use the same signal for `release.json.sig`, and clear it after both complete. `start()` waits five seconds after the window is ready, honors persisted eight-hour `lastCheckAt`, and owns one `setInterval` at eight hours. It emits only sanitized renderer state:

```js
{ phase: 'available', version, notes }
{ phase: 'downloading', version, transferred, total, percent }
{ phase: 'verifying', version }
{ phase: 'ready', version }
{ phase: 'failed', message }
{ phase: 'completed', version }
```

On `download()`, call `autoUpdater.setFeedURL({ provider: 'generic', url: WINDOWS_FEED_URL })`, then `autoUpdater.checkForUpdates()`. Require its update version to equal the already verified manifest and every returned file URL to resolve below the exact fixed `WINDOWS_FEED_URL` with a basename equal to the signed manifest artifact before calling `autoUpdater.downloadUpdate()`. On `update-downloaded`, stream SHA-256 over `downloadedFile`, compare exact byte size/hash, delete only that downloaded temporary installer on mismatch, then set ready. `restartAndInstall()` awaits `backupAgent.stopAndDrain(5000)`; false calls `backupAgent.startPolling(10000)` and fails with `备份仍在写入，已取消更新重启，请稍后重试`; true marks pending and calls `quitAndInstall(false, true)`.

- [ ] **Step 7: Run update and full Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/update/*.test.js
npm test
npm ls electron-updater electron-builder @electron/packager
```

Expected: all tests PASS; exact updater/builder versions are present; npm reports `@electron/packager` absent.

- [ ] **Step 8: Commit**

```bash
git add windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/package-lock.json windows/codex_session_manager_electron/src/update windows/codex_session_manager_electron/test/update
git commit -m "feat: add signed Windows update service"
```

### Task 7: Secure Windows IPC and Update Dialog

**Files:**
- Modify: `windows/codex_session_manager_electron/src/main.js:1-1550`
- Modify: `windows/codex_session_manager_electron/src/preload.js`
- Modify: `windows/codex_session_manager_electron/src/renderer.js:1-1100`
- Modify: `windows/codex_session_manager_electron/src/index.html:160-190`
- Modify: `windows/codex_session_manager_electron/src/styles.css:1209-1260`
- Modify: `windows/codex_session_manager_electron/test/security/electron-security.test.js`

**Interfaces:**
- Consumes `UpdateService` from Task 6.
- Produces trusted IPC handlers `update:get-state`, `update:check`, `update:download`, `update:defer-restart`, `update:install`, and event `update:state`.
- Produces preload methods `getUpdateState`, `checkForUpdates`, `downloadUpdate`, `deferUpdateRestart`, `installUpdate`, and `onUpdateState(listener)`.
- No update action accepts a URL, path, version, channel, command, or options object.

- [ ] **Step 1: Write failing IPC security tests**

Extend the existing source/registrar tests with exact assertions:

```js
for (const channel of [
  'update:get-state', 'update:check', 'update:download',
  'update:defer-restart', 'update:install',
]) {
  assert.equal(handlers.has(channel), true);
}
assert.match(preloadSource, /ipcRenderer\.invoke\('update:install'\)/);
assert.doesNotMatch(preloadSource, /update:install'\s*,\s*(url|path|options)/);
assert.doesNotMatch(mainSource, /ipcMain\.handle\s*\(/);
```

Invoke a handler with an untrusted sender and expect the existing registrar's rejection. Invoke each with a trusted sender and an extra argument and expect an arity/type rejection rather than using the argument.

- [ ] **Step 2: Run the security test and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/security/electron-security.test.js
```

Expected: FAIL because update channels are not registered.

- [ ] **Step 3: Wire UpdateService into the main process**

Replace the hardcoded `appVersion` with `app.getVersion()` after readiness. Read `updateBuild` from the packaged `package.json`, reject it unless it is a positive safe integer, and pass it as `currentBuild`. Instantiate one service with the existing `localBackupAgent`, main window accessor, vault root, public key loaded from `process.resourcesPath/UpdateKeys.json`, and imported `{ autoUpdater }`.

Register fixed, zero-argument handlers through `registerTrustedHandler`:

```js
registerTrustedHandler('update:get-state', () => updateService.getState());
registerTrustedHandler('update:check', () => updateService.check({ manual: true }));
registerTrustedHandler('update:download', () => updateService.download());
registerTrustedHandler('update:defer-restart', () => updateService.deferRestart());
registerTrustedHandler('update:install', () => updateService.restartAndInstall());
```

Start the service only after `createWindow()` has completed and the renderer has emitted its existing ready signal; dispose timers during `will-quit`. Keep all BrowserWindow security settings and navigation guards unchanged.

- [ ] **Step 4: Expose a narrow preload API**

Add:

```js
getUpdateState: () => ipcRenderer.invoke('update:get-state'),
checkForUpdates: () => ipcRenderer.invoke('update:check'),
downloadUpdate: () => ipcRenderer.invoke('update:download'),
deferUpdateRestart: () => ipcRenderer.invoke('update:defer-restart'),
installUpdate: () => ipcRenderer.invoke('update:install'),
onUpdateState: (listener) => {
  if (typeof listener !== 'function') throw new TypeError('listener must be a function');
  const wrapped = (_event, state) => listener(state);
  ipcRenderer.on('update:state', wrapped);
  return () => ipcRenderer.removeListener('update:state', wrapped);
},
```

The main process sends only objects produced by `UpdateService`; the renderer never receives the manifest URL, installer path, SHA-256, or signature.

- [ ] **Step 5: Add the exact update dialog**

Add one `role="dialog"`, `aria-modal="true"` block next to the existing overlays. It contains title, version, notes list, progress text/bar, error text, and two button rows with IDs:

```html
<button id="updateLaterButton" type="button">稍后提醒</button>
<button id="updateNowButton" type="button" class="primary">立即更新</button>
<button id="updateRestartLaterButton" type="button">稍后重启</button>
<button id="updateInstallButton" type="button" class="primary">重启并更新</button>
```

Renderer `state.update` starts as `{ phase: 'idle' }`. `renderUpdate()` uses `textContent` for version, notes, progress, and errors; it never uses `innerHTML`. Show the first row only for available, the progress block only for downloading/verifying, and the second row only for ready. `稍后提醒` closes until next launch/eight-hour check; `稍后重启` closes but retains ready state; completed shows `已更新到 X.Y.Z` once with `知道了`.

- [ ] **Step 6: Run security and full tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/security/electron-security.test.js
npm test
```

Expected: security test PASS and full suite PASS.

- [ ] **Step 7: Commit**

```bash
git add windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/src/preload.js windows/codex_session_manager_electron/src/renderer.js windows/codex_session_manager_electron/src/index.html windows/codex_session_manager_electron/src/styles.css windows/codex_session_manager_electron/test/security/electron-security.test.js
git commit -m "feat: add secure Windows update prompts"
```

### Task 8: Windows NSIS Packaging and Build Metadata

**Files:**
- Modify: `windows/codex_session_manager_electron/package.json`
- Modify: `windows/codex_session_manager_electron/package-lock.json`
- Create: `scripts/build_windows_installer.ps1`
- Modify: `scripts/build_windows_exe.sh`

**Interfaces:**
- Consumes Electron Builder 26.15.3 and `Config/UpdateKeys.json`.
- Produces `dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe` and `dist/windows/latest.yml`.
- Semantic version and integer update build come from `package.json.version` and `package.json.updateBuild`; the PowerShell script sets both from its required release inputs.

- [ ] **Step 1: Add exact Electron Builder configuration**

Set package version to `1.1.0`, add top-level `"updateBuild": 10100`, add `build:win`, and add this configuration:

```json
{
  "build": {
    "appId": "local.codex.session-manager",
    "productName": "codex_会话管理",
    "artifactName": "CodexSessionKeeper-${version}-windows-${arch}-Setup.${ext}",
    "directories": { "output": "../../dist/windows" },
    "files": ["src/**/*", "vendor/**/*", "package.json"],
    "extraResources": [
      { "from": "../../Config/UpdateKeys.json", "to": "UpdateKeys.json" }
    ],
    "win": { "target": [{ "target": "nsis", "arch": ["x64"] }] },
    "nsis": {
      "oneClick": false,
      "perMachine": false,
      "allowElevation": false,
      "allowToChangeInstallationDirectory": false,
      "createDesktopShortcut": true,
      "createStartMenuShortcut": true
    },
    "publish": [{
      "provider": "generic",
      "url": "http://192.168.10.99:18080/codex-session-keeper/stable/windows/"
    }]
  }
}
```

Set `scripts.package:win` to `npm run prepare:sqlite-win && electron-builder --win nsis --x64`.

- [ ] **Step 2: Create the Windows-native build script**

`scripts/build_windows_installer.ps1` accepts `-Version` and `-Build`, defaults them to `1.1.0` and `10100`, validates both, requires Windows x64, runs `npm ci`, updates both public package fields, runs tests, then builds:

```powershell
param([string]$Version = "1.1.0", [int]$Build = 10100)
$ErrorActionPreference = "Stop"
if (-not [Environment]::Is64BitOperatingSystem -or $env:OS -ne "Windows_NT") { throw "Windows x64 is required" }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be X.Y.Z" }
if ($Build -le 0) { throw "Build must be a positive integer" }
$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root "windows\codex_session_manager_electron"
Push-Location $App
try {
  npm ci
  $env:CODEX_RELEASE_VERSION = $Version
  $env:CODEX_RELEASE_BUILD = "$Build"
  node -e "const fs=require('fs');const p=require('./package.json');p.version=process.env.CODEX_RELEASE_VERSION;p.updateBuild=Number(process.env.CODEX_RELEASE_BUILD);fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n')"
  npm install --package-lock-only --ignore-scripts
  npm test
  npm run package:win
} finally { Pop-Location }
```

After build, require exactly one matching Setup exe and `latest.yml`, print their SHA-256 via `Get-FileHash`, and exit nonzero otherwise. The release operator copies those two outputs to the release Mac through the company-controlled file transfer path.

- [ ] **Step 3: Disable the obsolete portable builder**

Replace `scripts/build_windows_exe.sh` with a non-destructive failure:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "Portable Windows releases were retired before 1.1.0. Run scripts/build_windows_installer.ps1 on Windows x64." >&2
exit 1
```

This prevents an employee release from accidentally returning to an un-updatable portable directory.

- [ ] **Step 4: Verify package metadata and build on Windows x64**

Run on the Windows release/test machine:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.0.99 -Build 10099
```

Expected: all tests PASS; the installer is per-user NSIS; `latest.yml` names the same installer; Windows Apps & Features lists `codex_会话管理`; installation does not request administrator elevation.

- [ ] **Step 5: Commit**

```bash
git add windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/package-lock.json scripts/build_windows_installer.ps1 scripts/build_windows_exe.sh
git commit -m "build: replace Windows portable package with NSIS"
```

### Task 9: Release Assembly, Sparkle Feed, and Atomic Publication

**Files:**
- Create: `scripts/update/build-release-manifest.mjs`
- Create: `scripts/update/verify-release-directory.mjs`
- Create: `scripts/update/publish-release.sh`
- Test: `scripts/update/release-manifest.test.mjs`

**Interfaces:**
- Consumes macOS zip, Windows Setup exe, Electron `latest.yml`, Task 1 signing key, Sparkle private key, version, build, timestamp, and notes.
- Produces a complete staging tree under `.release-staging/1.1.0/codex-session-keeper/stable/`.
- `publish-release.sh` consumes exactly two absolute directory arguments: verified staging stable root and NAS stable root.
- Publication never modifies a path unless it contains `.codex-update-root` with exact content `codex-session-keeper-update-root-v1`.

- [ ] **Step 1: Add release assembly tests**

Use a temporary directory with small fake artifacts and ephemeral keys. Assert generated relative URLs, actual sizes/hashes, signature validity, rejection when `latest.yml` references a different exe/version, rejection when macOS appcast lacks the requested version, and verification failure after any artifact byte changes.

```js
test('release verifier detects artifact tampering', async () => {
  const release = await makeReleaseFixture();
  await verifyReleaseDirectory(release.root, release.publicKey);
  await appendFile(release.windowsInstaller, Buffer.from([0]));
  await assert.rejects(() => verifyReleaseDirectory(release.root, release.publicKey), /sha256 mismatch/);
});
```

- [ ] **Step 2: Run the release tests and verify RED**

Run:

```bash
node --test scripts/update/release-manifest.test.mjs
```

Expected: FAIL because release assembly exports do not exist.

- [ ] **Step 3: Generate Sparkle appcast and the signed common manifest**

`build-release-manifest.mjs` accepts only named arguments:

```text
--version 1.1.0 --build 10100
--mac-zip /absolute/path/CodexSessionKeeper-1.1.0-macos-arm64.zip
--windows-exe /absolute/path/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
--windows-yml /absolute/path/latest.yml
--notes-file /absolute/path/release-notes.json
--output /absolute/path/.release-staging/1.1.0
```

It validates filenames/version, invokes Sparkle 2.9.4 `generate_appcast --account local.codex.session-manager --download-url-prefix http://192.168.10.99:18080/codex-session-keeper/stable/macos/` over the staged macOS directory, requires one enclosure for `1.1.0`, copies Electron metadata, hashes both artifacts, writes manifest bytes once, signs those exact bytes from Keychain, and never edits the manifest after signing. Sparkle 2.9.4 embeds the signed-feed `sparkle-signatures` block inside `appcast.xml`; do not create or publish a separate `appcast.xml.sig`.

- [ ] **Step 4: Implement full staging verification**

Verification must perform all of these checks and exit nonzero on the first failure:

```text
release.json detached Ed25519 signature is valid
schema and both platform artifacts are valid
both artifact byte sizes and SHA-256 values match
artifact paths remain below the staging root after realpath resolution
appcast version, build, filename, length, and Sparkle signature match the macOS zip
latest.yml version and path match the Windows Setup exe
no private-key file and no unexpected executable exists in staging
```

Print one machine-readable final line on success:

```json
{"verified":true,"version":"1.1.0","build":10100}
```

- [ ] **Step 5: Implement guarded atomic NAS publication**

`publish-release.sh` resolves both arguments with `realpath`, rejects `/`, the repository root, `$HOME`, missing marker, different filesystems, symlinks in the destination chain, and staging verification failure. It copies versioned artifacts into a sibling `.incoming-1.1.0-<pid>`, fsyncs, renames them into platform directories, then publishes in this exact order:

```text
macos/appcast.xml with its embedded Sparkle feed signature
windows/latest.yml
release.json.sig
release.json last
```

Existing versioned artifacts are never overwritten unless their SHA-256 is identical. The script prints versions eligible for manual retention cleanup but does not delete them.

- [ ] **Step 6: Run release tests**

Run:

```bash
node --test scripts/update/release-manifest.test.mjs
git diff --check
```

Expected: all protocol and assembly tests PASS; diff check is clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/update
git commit -m "build: assemble and atomically publish updates"
```

### Task 10: Read-Only NAS Nginx Deployment

**Files:**
- Create: `deploy/nas/docker-compose.yml`
- Create: `deploy/nas/nginx.conf`
- Create: `deploy/nas/codex-updates/.gitkeep`
- Create: `docs/NAS内网更新部署与发布.md`

**Interfaces:**
- Serves `http://192.168.10.99:18080/codex-session-keeper/stable/` from the compose-relative `deploy/nas/codex-updates/` directory.
- Exposes no write method, directory listing, authentication page, or application API.
- The deployment marker is `deploy/nas/codex-updates/.codex-update-root` with exact content `codex-session-keeper-update-root-v1` on NAS; the tracked `.gitkeep` does not substitute for the runtime marker.

- [ ] **Step 1: Write the Compose and Nginx configuration**

Use this container boundary:

```yaml
services:
  codex-update-server:
    image: nginx:alpine
    container_name: codex-update-server
    restart: unless-stopped
    ports:
      - "18080:80"
    volumes:
      - ./codex-updates:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    read_only: true
    tmpfs:
      - /var/cache/nginx
      - /var/run
      - /tmp
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "3"
```

`nginx.conf` uses `autoindex off`, `access_log off`, `error_log /dev/stderr warn`, accepts only `GET`/`HEAD`, returns 405 for other methods, applies `Cache-Control: no-cache` to `.json`, `.sig`, `.xml`, and `.yml`, and applies `public, max-age=31536000, immutable` to versioned `.zip`/`.exe`. Limit request body to `1k` and do not proxy anywhere.

- [ ] **Step 2: Validate configuration locally without changing NAS**

Run:

```bash
docker compose -f deploy/nas/docker-compose.yml config
docker run --rm -v "$PWD/deploy/nas/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine nginx -t
```

Expected: Compose renders successfully and Nginx reports configuration syntax is okay.

- [ ] **Step 3: Write the operator runbook**

The runbook gives exact UGOS Pro UI steps: create a dedicated Docker project directory, copy the deploy files, create `codex-updates/.codex-update-root`, start the project, enable NAS/firewall access only from the company LAN, and verify:

```bash
curl -fsS http://192.168.10.99:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.99:18080/codex-session-keeper/stable/release.json
curl -X POST -i http://192.168.10.99:18080/codex-session-keeper/stable/release.json
```

Expected after first publication: GET returns signed JSON, HEAD has `Cache-Control: no-cache`, POST returns 405, and a directory URL does not list files. The runbook explicitly says the deployment step requires user approval because it changes NAS state; implementation work must stop before running it unless the user authorizes deployment.

- [ ] **Step 4: Commit**

```bash
git add deploy/nas docs/NAS内网更新部署与发布.md
git commit -m "docs: add read-only NAS update deployment"
```

### Task 11: Documentation, Full Verification, and 1.0.99 → 1.1.0 Rehearsal

**Files:**
- Modify: `README.md`
- Modify: `docs/操作手册.md`
- Modify: `windows/codex_session_manager_electron/README_WIN10_EXE.md`
- Verify all files changed by Tasks 1-10.

**Interfaces:**
- Produces the employee install/update instructions and administrator release checklist.
- Produces evidence that both platforms preserve sessions, snapshots, settings, incremental cursor data, and NAS backup configuration across update.
- Does not authorize NAS deployment; it assumes Task 10 deployment was separately approved and completed.

- [ ] **Step 1: Update employee documentation**

Document exactly:

```text
首次安装：从公司 NAS 的员工下载目录安装 1.1.0。
发现新版：选择“稍后提醒”不会下载；选择“立即更新”才开始下载。
下载完成：选择“稍后重启”可继续工作；选择“重启并更新”会先安全停止备份，然后安装并重启。
内网之外：检查会静默跳过，不影响软件使用。
首次系统警告：当前公司内部版本没有 Apple/Windows 商业证书，按公司管理员提供的安装说明确认来源。
```

Remove portable Windows distribution instructions and all GitHub release/update directions. Keep manual recovery instructions for historical packages.

- [ ] **Step 2: Run all automated verification**

Run on the release Mac:

```bash
swift test
node --test scripts/update/release-manifest.test.mjs
cd windows/codex_session_manager_electron && npm test
git diff --check
git status --short
```

Expected: every suite PASS; diff check is clean; only intentional tracked changes and untracked `.codegraph/` appear.

- [ ] **Step 3: Create and verify the encrypted offline key backup**

After the user confirms that an encrypted external volume named `CodexUpdateKeyBackup` is mounted, run:

```bash
scripts/update/backup-update-keys.sh /Volumes/CodexUpdateKeyBackup/codex-session-keeper-update-keys-2026-07-21.tar.enc
openssl enc -d -aes-256-cbc -pbkdf2 \
  -in /Volumes/CodexUpdateKeyBackup/codex-session-keeper-update-keys-2026-07-21.tar.enc \
  | tar -tf -
```

Expected: the encrypted archive exists with mode `600`; the password-protected listing contains only `manifest-private.pem` and `sparkle-private.key`. Do not extract it into the repository or copy it to NAS.

- [ ] **Step 4: Build the two rehearsal versions**

Build macOS bootstrap and candidate separately:

```bash
APP_VERSION=1.0.99 APP_BUILD=10099 scripts/build_app.sh
APP_VERSION=1.1.0 APP_BUILD=10100 scripts/build_app.sh
```

Build Windows bootstrap and candidate on Windows x64:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.0.99 -Build 10099
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.1.0 -Build 10100
```

Keep `1.0.99` under a test-only candidate directory. Assemble and verify only the `1.1.0` stable manifest. Do not place `1.0.99` under `codex-session-keeper/stable/`.

- [ ] **Step 5: Execute the macOS real-device rehearsal**

On a non-production standard-user test account, repeat once with the app in `/Applications` and once in the user's `Applications` directory. Install `1.0.99`, create a known session/snapshot/settings state, confirm incremental backup idle, then expose the verified `1.1.0` candidate feed. Record PASS for:

```text
prompt appears within 10 seconds on LAN
“稍后提醒” performs no artifact download
“立即更新” shows increasing byte progress
“稍后重启” leaves the app usable
“重启并更新” drains backup and relaunches 1.1.0
one-shot “已更新到 1.1.0” appears
session, snapshot, cursor, settings, and NAS backup identity are unchanged
NAS offline launch remains functional and silent
tampered manifest and tampered zip cannot install
```

- [ ] **Step 6: Execute the Windows real-device rehearsal**

On a Windows 10 x64 standard user account, install the NSIS `1.0.99` package and repeat the same acceptance list. Additionally record PASS for no administrator elevation, Apps & Features entry, `latest.yml` version match, tampered Setup exe deletion, and uninstall behavior. Confirm the old portable package is not offered.

- [ ] **Step 7: Verify retention and rollback procedure**

After a separately approved NAS publication, list stable artifacts and retain the current versioned files plus two prior versioned artifact sets. Simulate rollback without publishing: rebuild the last known-good code as `1.1.1` build `10101`, assemble it in staging, and verify clients consider it newer. Do not replace the live `1.1.0` feed during this simulation.

- [ ] **Step 8: Commit documentation and final verification evidence**

Add a dated rehearsal results section containing platform, OS version, source version, target version, each acceptance result, and artifact SHA-256 values; do not include employee names, IP logs, or private keys.

```bash
git add README.md docs/操作手册.md windows/codex_session_manager_electron/README_WIN10_EXE.md docs/NAS内网更新部署与发布.md
git commit -m "docs: finalize internal update rollout guide"
```

## Final Release Gate

Before declaring `1.1.0` ready for employee download, all conditions must be true:

```text
Swift, release-tooling, and Electron tests pass
both real-device 1.0.99 → 1.1.0 rehearsals pass
manifest, appcast, latest.yml, size, and hash verification pass
private-key scans find no repository or NAS copy
NAS Nginx is read-only, LAN-only, auto-starting, and does not list directories
release.json is the last file atomically published
employee download location contains 1.1.0, never 1.0.99
latest three stable releases are retained
```

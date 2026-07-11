# NAS Direct Incremental Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace automatic local conversation backups with a first-run-gated, fixed-company-NAS workflow that writes recoverable active and archived Codex session JSONL directly into validated per-employee, per-device directories.

**Architecture:** Add platform-specific NAS discovery and configuration services behind equivalent logical interfaces. Keep snapshots local, keep cursor/runtime metadata local, write conversation JSONL plus atomic manifest/status metadata to the NAS, and make every backup scan revalidate the trusted mount and device marker before writing. Recovery selects a validated device identity rather than accepting a filesystem path, so a replacement computer can restore an older device's sessions without acquiring its write identity.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, SwiftUI, Foundation, and CryptoKit on macOS 14+; Electron 43.1.0, Node.js, `node:test`, built-in `fs`/`crypto`, and the existing trusted IPC registrar on Windows 10 x64; SMB share `192.168.10.99/文件中转站`.

## Global Constraints

- The fixed endpoint is server `192.168.10.99`, share `文件中转站`, trusted root `codex会话备份`.
- The application must not accept a manually entered server, share, department path, employee path, or backup path.
- The application must not store SMB credentials or attempt an SMB login; it uses the operating system's existing SMB session.
- Department and employee folders must already exist and must be direct, canonical, non-link children of the trusted root hierarchy.
- The application may create only `devices/<device-name-and-suffix>/` and its fixed children below the chosen employee folder.
- NAS content is limited to `device.json`, session JSONL, `manifest.json`, and `status.json`; do not upload `auth.json`, `config.toml`, live `state_5.sqlite`, cursor SQLite, logs, recovery work packages, or full snapshots.
- Cursor SQLite, logs, configuration, and runtime status remain under the local `~/.codex-session-vault`; they must never contain copied conversation bodies.
- Incremental recovery writes validated NAS content directly and atomically into the final `~/.codex/sessions/recovered` destination; it must not create an intermediate local recovery package.
- There is no local pending conversation spool and no silent fallback from NAS to local storage.
- A failed NAS write, flush, rename, path validation, marker validation, or reconnect validation must not advance a committed cursor.
- If the NAS mount disappears, backup code must not recreate the missing mount path as a local directory.
- Full snapshots and their existing restore behavior remain local and unchanged.
- One employee may use multiple computers; each computer writes only to its stable UUID-backed device directory.
- Recovery may read any valid device directory under the configured employee, but the renderer/UI passes only device IDs, never filesystem paths.
- Incremental recovery restores only sessions still missing from the current Codex data and must never overwrite an existing session.
- The shared NAS identity `171` is accepted for this rollout; this feature prevents accidental misconfiguration and is not an employee confidentiality boundary.
- Preserve Electron `sandbox: true`, trusted IPC sender checks, navigation guards, and all existing restore path validation.
- Add no new runtime dependency.
- Keep `.codegraph/` untracked and out of every commit.

---

## File Structure

### macOS core

- Create: `Sources/CodexSessionVaultCore/NAS/NASModels.swift`
  - Codable endpoint, configuration, device marker, setup snapshot, and recovery-source identities.
- Create: `Sources/CodexSessionVaultCore/NAS/CompanyNASLocator.swift`
  - Resolves the real mounted SMB share from mount metadata, not from a lookalike path.
- Create: `Sources/CodexSessionVaultCore/NAS/NASPathValidator.swift`
  - Enforces direct-child, canonical path, extension, symlink, and mount-boundary rules.
- Create: `Sources/CodexSessionVaultCore/NAS/NASConfigurationService.swift`
  - Enumerates departments/employees, performs the write probe, provisions a device directory, persists logical identity, and resolves recovery sources.
- Create: `Sources/CodexSessionVaultCore/NAS/NASConfigurationStore.swift`
  - Atomically stores logical NAS identity under the local vault.
- Create: `Sources/CodexSessionVaultCore/Backup/DurableAtomicWriter.swift`
  - Same-directory temporary write, file synchronization, atomic rename, and cleanup.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupFileCommitter.swift`
  - New-file seed, append-and-sync, prefix reconciliation, and rewrite-to-temp operations.
- Create: `Sources/CodexSessionVaultCore/Backup/NASBackupRuntime.swift`
  - Owns startup gating, retry, local status, active agent lifecycle, and selected recovery device.
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupModels.swift`
  - Manifest v2 and NAS-specific status/progress fields with backward-compatible decoding.
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupPaths.swift`
  - Split remote content root from local control state; mirror source-relative session paths.
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
  - Revalidate target before every scan, use durable commit order, report seeding/pending progress, and recover from source rewrite or interrupted append.
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift`
  - Use durable atomic JSON writes.
- Modify: `Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift`
  - Read a caller-selected validated device root.
- Create: `Sources/CodexSessionVaultCore/Backup/IncrementalRecoveryRestorer.swift`
  - Preflight selected NAS sources and restore them atomically to final Codex recovery destinations without an intermediate package.
- Delete: `Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift`
  - Remove the obsolete package-building path.
- Modify: `Sources/CodexSessionVault/main.swift`
  - Replace eager local-agent startup, add setup/retry/reconfigure UI, display NAS state, select recovery devices, and pass logical recovery identity to the worker.
- Modify: `scripts/build_app.sh`
  - Set the macOS bundle version to `1.0.14` for the NAS-enabled build.

### macOS tests

- Create: `Tests/CodexSessionVaultCoreTests/CompanyNASLocatorTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/NASConfigurationServiceTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/DurableAtomicWriterTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/NASBackupRuntimeTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/IncrementalRecoveryRestorerTests.swift`
- Delete: `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`

### Windows/Electron core

- Create: `windows/codex_session_manager_electron/src/backup/nas-service.js`
  - Fixed UNC discovery, catalog, canonical validation, probe, device activation, and device listing.
- Create: `windows/codex_session_manager_electron/src/backup/nas-runtime.js`
  - Startup gating, validated agent lifecycle, retry, local status, and device-source resolution.
- Create: `windows/codex_session_manager_electron/src/backup/durable-write.js`
  - Synced same-directory temporary writes and atomic rename.
- Create: `windows/codex_session_manager_electron/src/settings.js`
  - Extracted atomic settings persistence with `nasBackup` schema.
- Modify: `windows/codex_session_manager_electron/src/backup/paths.js`
  - Accept remote `backupRoot` and local `stateRoot`; mirror source-relative paths.
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
  - Add target guard, durable commit ordering, progress, pending count, and rewrite/partial-append recovery.
- Modify: `windows/codex_session_manager_electron/src/backup/cursor-store.js`
  - Continue using `sql.js`, but write only the local cursor database path.
- Modify: `windows/codex_session_manager_electron/src/backup/manifest-store.js`
  - Use the durable writer for NAS metadata.
- Modify: `windows/codex_session_manager_electron/src/backup/models.js`
  - Manifest version 2.
- Modify: `windows/codex_session_manager_electron/src/backup/incremental-recovery.js`
  - Preflight selected device sources and restore directly to final Codex recovery destinations without an intermediate package.
- Modify: `windows/codex_session_manager_electron/src/main.js`
  - Remove eager local agent, initialize the NAS runtime, add protected setup/retry/device IPC, and resolve device IDs server-side.
- Modify: `windows/codex_session_manager_electron/src/preload.js`
  - Expose setup and recovery-device APIs without exposing raw paths.
- Modify: `windows/codex_session_manager_electron/src/index.html`
  - Add blocking first-run setup modal and reconfiguration entry.
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
  - Render setup states, department/employee selectors, NAS status, and recovery-device selection.
- Modify: `windows/codex_session_manager_electron/src/styles.css`
  - Style setup, error, progress, and status states.
- Modify: `windows/codex_session_manager_electron/package.json`
- Modify: `windows/codex_session_manager_electron/package-lock.json`
  - Set the Windows package version to `1.0.14`.

### Windows/Electron tests

- Create: `windows/codex_session_manager_electron/test/backup/nas-service.test.js`
- Create: `windows/codex_session_manager_electron/test/backup/nas-runtime.test.js`
- Create: `windows/codex_session_manager_electron/test/backup/durable-write.test.js`
- Create: `windows/codex_session_manager_electron/test/security/nas-ui-contract.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/paths.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`
- Modify: `windows/codex_session_manager_electron/test/security/electron-security.test.js`

### Documentation

- Modify: `README.md`
- Modify: `docs/操作手册.md`
- Modify: `windows/codex_session_manager_electron/README_WIN10_EXE.md`

---

### Task 1: Swift Trusted NAS Discovery and Configuration

**Files:**
- Create: `Sources/CodexSessionVaultCore/NAS/NASModels.swift`
- Create: `Sources/CodexSessionVaultCore/NAS/CompanyNASLocator.swift`
- Create: `Sources/CodexSessionVaultCore/NAS/NASPathValidator.swift`
- Create: `Sources/CodexSessionVaultCore/NAS/NASConfigurationStore.swift`
- Create: `Sources/CodexSessionVaultCore/NAS/NASConfigurationService.swift`
- Create: `Tests/CodexSessionVaultCoreTests/CompanyNASLocatorTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/NASConfigurationServiceTests.swift`

**Interfaces:**
- Produces `CompanyNASEndpoint.production`, `CompanyNASMount`, `NASBackupConfiguration`, `NASDeviceMarker`, `NASBackupTarget`, `NASRecoverySourceIdentity`, `NASSetupSnapshot`.
- Produces `NASDirectoryOption` and `NASRecoverySource` for UI-safe catalogs that contain logical identity, labels, and dates but no writable raw path.
- Produces `CompanyNASLocator.locate() throws -> CompanyNASMount`.
- Produces `NASConfigurationService.detect()`, `departments()`, `employees(in:)`, `activate(department:employee:)`, `resolveActiveTarget()`, and `recoverySources()`.
- Persists logical names and UUIDs only; no persisted absolute mount path.

- [ ] **Step 1: Write failing locator and configuration tests**

Use injected mounted-volume descriptors so tests never need the real NAS. Cover the production endpoint, wrong server, wrong share, a local lookalike `/Volumes/文件中转站`, missing trusted root, nested department names, symlinked department/employee entries, deterministic sorting, write/read/rename/delete probe failure, stable device UUID reuse, and marker collision.

The public-contract assertions must include:

```swift
let endpoint = CompanyNASEndpoint.production
#expect(endpoint.server == "192.168.10.99")
#expect(endpoint.share == "文件中转站")
#expect(endpoint.backupRootName == "codex会话备份")

let departments = try service.departments()
#expect(departments.map(\.name) == ["开发部", "运营部"])

let target = try service.activate(department: "运营部", employee: "陈超")
#expect(target.configuration.department == "运营部")
#expect(target.configuration.employee == "陈超")
#expect(target.backupRoot.lastPathComponent == "incremental-backups")
#expect(target.backupRoot.path.contains("/陈超/devices/"))
```

- [ ] **Step 2: Run the Swift NAS tests and verify RED**

Run:

```bash
swift test --filter 'CompanyNASLocatorTests|NASConfigurationServiceTests'
```

Expected: compilation fails because the NAS types do not exist.

- [ ] **Step 3: Implement the NAS domain and fixed mount resolver**

Define these exact core shapes in `NASModels.swift`:

```swift
public struct CompanyNASEndpoint: Codable, Equatable, Sendable {
    public static let production = CompanyNASEndpoint(
        server: "192.168.10.99",
        share: "文件中转站",
        backupRootName: "codex会话备份"
    )
    public let server: String
    public let share: String
    public let backupRootName: String
}

public struct NASBackupConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let endpoint: CompanyNASEndpoint
    public let department: String
    public let employee: String
    public let deviceID: UUID
    public let deviceName: String
    public let deviceDirectoryName: String
}

public struct NASRecoverySourceIdentity: Codable, Equatable, Hashable, Sendable {
    public let department: String
    public let employee: String
    public let deviceID: UUID
    public let deviceDirectoryName: String
}
```

`CompanyNASLocator` must obtain mounted volumes with `.volumeURLForRemountingKey`, accept only `smb` remount URLs whose host equals `192.168.10.99` and decoded share path equals `/文件中转站`, canonicalize the mount and trusted root, require the trusted root to be an existing directory, and return typed `notConnected`, `wrongShare`, or `trustedRootMissing` errors.

- [ ] **Step 4: Implement catalog, path validation, probe, marker, and configuration persistence**

`NASPathValidator` must validate one component at a time, reject empty/NUL/`.`/`..`/slash/backslash/absolute/drive/UNC values, walk each component with `lstat`-equivalent resource values, reject symbolic links, and confirm the resolved child is a direct child of its resolved parent.

`NASConfigurationService.activate` must execute this order:

```swift
let mount = try locator.locate()
let employeeRoot = try pathValidator.resolveEmployee(
    department: department,
    employee: employee,
    under: mount.trustedRootURL
)
try writeProbe.verifyWritableDirectory(employeeRoot)
let configuration = try makeConfiguration(for: employeeRoot, previous: store.load())
let target = try activateDevice(configuration, employeeRoot: employeeRoot)
try store.save(configuration)
return target
```

The employee write probe creates a random temporary child, writes bytes, synchronizes, reads the exact bytes back, renames the file in the same directory, deletes it, and deletes the probe directory. Configuration is saved only after `device.json` and the target-local probe succeed.

- [ ] **Step 5: Run the Swift NAS tests and verify GREEN**

Run:

```bash
swift test --filter 'CompanyNASLocatorTests|NASConfigurationServiceTests'
```

Expected: all selected tests pass and no probe artifacts remain in fixture directories.

- [ ] **Step 6: Commit the Swift NAS configuration layer**

```bash
git add Sources/CodexSessionVaultCore/NAS Tests/CodexSessionVaultCoreTests/CompanyNASLocatorTests.swift Tests/CodexSessionVaultCoreTests/NASConfigurationServiceTests.swift
git commit -m "feat: add trusted macOS NAS configuration"
```

---

### Task 2: Swift Remote Content Paths and Durable Atomic I/O

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/DurableAtomicWriter.swift`
- Create: `Tests/CodexSessionVaultCoreTests/DurableAtomicWriterTests.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupPaths.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupModels.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupManifestStoreTests.swift`

**Interfaces:**
- `BackupPaths.init(codexRoot:backupRoot:stateRoot:)` separates NAS content from local control state.
- `BackupPaths.backupFileURL(for sourceURL: URL) throws -> URL` mirrors `sessions` and `archived_sessions` source-relative paths.
- `DurableAtomicWriter.write(_:to:)` synchronizes a same-directory temporary file before rename.
- Manifest version becomes 2; old version-1 manifests remain decodable for read-only diagnostics.

- [ ] **Step 1: Write failing layout and durable-writer tests**

Assert the exact split:

```swift
let paths = BackupPaths(
    codexRoot: URL(fileURLWithPath: "/Users/alice/.codex"),
    backupRoot: URL(fileURLWithPath: "/Volumes/文件中转站/codex会话备份/运营部/陈超/devices/mac-a13f/incremental-backups"),
    stateRoot: URL(fileURLWithPath: "/Users/alice/.codex-session-vault/nas-state/mac-a13f")
)
#expect(paths.cursorDatabaseURL.path.hasPrefix("/Users/alice/.codex-session-vault/"))
#expect(paths.localStatusURL.path.hasPrefix("/Users/alice/.codex-session-vault/"))
#expect(paths.manifestURL.path.hasPrefix("/Volumes/文件中转站/"))
#expect(paths.remoteStatusURL.path.hasPrefix("/Volumes/文件中转站/"))
#expect(try paths.backupFileURL(for: URL(fileURLWithPath: "/Users/alice/.codex/sessions/2026/07/a.jsonl")).path.hasSuffix("/sessions/2026/07/a.jsonl"))
#expect(try paths.backupFileURL(for: URL(fileURLWithPath: "/Users/alice/.codex/archived_sessions/2026/07/a.jsonl")).path.hasSuffix("/archived_sessions/2026/07/a.jsonl"))
```

Also assert that a source outside the two session roots, a source containing a symlink component, and a non-JSONL source are rejected. For `DurableAtomicWriter`, inject a failing synchronize hook and assert the destination is unchanged and the temporary file is removed.

- [ ] **Step 2: Run the selected Swift tests and verify RED**

```bash
swift test --filter 'BackupPathsTests|DurableAtomicWriterTests|BackupManifestStoreTests'
```

Expected: failures reference missing `stateRoot`, `localStatusURL`, `remoteStatusURL`, and `backupFileURL(for:)`.

- [ ] **Step 3: Implement split paths and durable JSON commits**

The path contract must be:

```swift
public let codexRoot: URL
public let backupRoot: URL
public let stateRoot: URL
public var manifestURL: URL { backupRoot.appendingPathComponent("manifest.json") }
public var remoteStatusURL: URL { backupRoot.appendingPathComponent("status.json") }
public var cursorDatabaseURL: URL { stateRoot.appendingPathComponent("cursors.sqlite") }
public var localStatusURL: URL { stateRoot.appendingPathComponent("status.json") }
public var logURL: URL { stateRoot.appendingPathComponent("logs/backup-agent.log") }
```

`DurableAtomicWriter` opens a unique same-directory file with exclusive creation, writes all data, calls `FileHandle.synchronize()`, closes, then replaces or renames the destination. It removes only its own temporary path on failure. `BackupManifestStore.save` uses this writer. Do not use `Data.write(options: .atomic)` for NAS metadata after this task.

- [ ] **Step 4: Run the selected Swift tests and verify GREEN**

```bash
swift test --filter 'BackupPathsTests|DurableAtomicWriterTests|BackupManifestStoreTests'
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit split storage and durable metadata**

```bash
git add Sources/CodexSessionVaultCore/Backup/DurableAtomicWriter.swift Sources/CodexSessionVaultCore/Backup/BackupPaths.swift Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift Sources/CodexSessionVaultCore/Backup/BackupModels.swift Tests/CodexSessionVaultCoreTests/DurableAtomicWriterTests.swift Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift Tests/CodexSessionVaultCoreTests/BackupManifestStoreTests.swift
git commit -m "refactor: split macOS NAS content from local state"
```

---

### Task 3: Swift Crash-safe Direct NAS Backup Agent

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/BackupFileCommitter.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift`

**Interfaces:**
- `BackupTargetValidating.validateTarget() throws` is called before any remote directory or file operation.
- `BackupFileCommitter.inspectSource`, `inspectTarget`, `commitInitial`, `appendAndSynchronize`, `reconcile`, and `rebuildCompleteLines` perform bounded source inspection and remote content commits.
- `BackupAgent` accepts `targetValidator`, `fileCommitter`, and `progressHandler` dependencies.
- `BackupAgent.pendingSessionCount() throws -> Int` compares local source metadata with local committed cursors without copying conversation content.
- Local `pending-sources.json` records only source path, size, modification time, and last committed offset so deletion during an outage can be reported without caching message bytes.

Use these exact decision types:

```swift
public struct BackupSourceMetadata: Sendable {
    public let byteCount: Int64
    public let modifiedAt: TimeInterval
}

public struct BackupTargetState: Sendable {
    public let exists: Bool
    public let byteCount: Int64
}

public enum BackupReconciliation: Equatable, Sendable {
    case new
    case append(readOffset: Int64)
    case rebuild
}
```

- [ ] **Step 1: Add failing commit-order and recovery tests**

Extend `BackupAgentTests` with these named cases:

- `missingTargetRootIsNotRecreatedLocally`
- `targetValidationRunsBeforeDirectoryCreation`
- `initialSeedUsesTemporaryFileAndAtomicRename`
- `failedSynchronizeDoesNotAdvanceCursorOrManifest`
- `interruptedAppendThatMatchesSourcePrefixResumesWithoutDuplicate`
- `interruptedAppendThatDoesNotMatchSourceRebuildsAtomically`
- `sourceTruncationAndRewriteReplacesStaleBackup`
- `sourceMoveToArchivedUsesArchivedRelativePathWithoutLosingContent`
- `offlinePendingCountUsesMetadataOnly`
- `pendingSourceDeletedDuringOutageIsReportedUnrecoverable`
- `remoteStatusFailureProducesLocalErrorStatus`

The cursor-order assertion must read the local cursor database after an injected remote sync failure:

```swift
do {
    try agent.performOneShotScan()
    Issue.record("Expected injected synchronize failure")
} catch {}
let cursor = try cursorStore.cursor(sourcePath: sourceURL.path)
#expect(cursor == nil || cursor?.lastByteOffset == committedOffsetBeforeFailure)
#expect(try String(contentsOf: committedBackupURL, encoding: .utf8) == committedContentsBeforeFailure)
```

- [ ] **Step 2: Run the Swift agent tests and verify RED**

```bash
swift test --filter 'BackupAgentTests|BackupCursorStoreTests'
```

Expected: the new dependency interfaces and rewrite recovery behavior are missing.

- [ ] **Step 3: Implement target guarding and non-recursive managed-directory creation**

At the start of every scan, call `targetValidator.validateTarget()`. Require `backupRoot` to already exist as a real directory. Create each managed descendant one component at a time with `withIntermediateDirectories: false`; revalidate containment after every creation. Never call recursive directory creation on `backupRoot` or a path whose parent has not already been validated.

- [ ] **Step 4: Implement durable seed, append, reconciliation, and rewrite ordering**

For each source, use this exact decision order:

```swift
let sourceMetadata = try fileCommitter.inspectSource(sourceURL)
let targetState = try fileCommitter.inspectTarget(targetURL)
let reconciliation = try fileCommitter.reconcile(
    sourceURL: sourceURL,
    sourceMetadata: sourceMetadata,
    targetURL: targetURL,
    target: targetState,
    committedOffset: cursor?.lastByteOffset ?? 0
)
switch reconciliation {
case .new:
    let tail = try tailer.readNewCompleteLines(from: sourceURL, offset: 0)
    try fileCommitter.commitInitial(tail.lines, to: targetURL)
case let .append(readOffset):
    let tail = try tailer.readNewCompleteLines(from: sourceURL, offset: readOffset)
    try fileCommitter.appendAndSynchronize(tail.lines, to: targetURL)
case .rebuild:
    try fileCommitter.rebuildCompleteLines(from: sourceURL, at: targetURL)
}
try manifestStore.save(updatedManifest)
try cursorStore.upsert(updatedCursor)
```

`reconcile` performs full byte-prefix comparison only for anomaly paths: target length differs from the committed byte count, the source shrank, source modification precedes the cursor unexpectedly, or the stored relative backup path changed. Steady-state append validates size plus bounded first/tail fingerprints before appending. All remote data is synchronized before manifest and cursor advancement. A rewrite must create and synchronize a complete same-directory temporary target, atomically replace the destination, then update metadata.

- [ ] **Step 5: Add progress and local/remote status ordering**

Add `BackupProgress(totalFiles:completedFiles:pendingFiles:phase:)` and report `.seeding` while an empty NAS manifest is populated. Write `manifest.json`, then remote `status.json`, then local `status.json` after successful session commits. On any remote error, persist metadata-only pending source facts locally, write only the local error/disconnected status, and preserve the last remote status. If a recorded pending source disappears before reconnect, keep the corresponding manifest record, report it as unrecoverable, and do not mark the pending change complete.

- [ ] **Step 6: Run the Swift agent suite and verify GREEN**

```bash
swift test --filter 'BackupAgentTests|BackupCursorStoreTests'
```

Expected: all agent and cursor tests pass, including source rewrite and interrupted append cases.

- [ ] **Step 7: Commit the Swift direct NAS agent**

```bash
git add Sources/CodexSessionVaultCore/Backup/BackupFileCommitter.swift Sources/CodexSessionVaultCore/Backup/BackupAgent.swift Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift
git commit -m "feat: make macOS NAS backup commits crash safe"
```

---

### Task 4: Swift NAS Runtime and Direct Previous-device Recovery

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/NASBackupRuntime.swift`
- Create: `Tests/CodexSessionVaultCoreTests/NASBackupRuntimeTests.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift`
- Create: `Sources/CodexSessionVaultCore/Backup/IncrementalRecoveryRestorer.swift`
- Delete: `Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift`
- Create: `Tests/CodexSessionVaultCoreTests/IncrementalRecoveryRestorerTests.swift`
- Delete: `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`

**Interfaces:**
- `NASBackupRuntime.initialize()`, `activate(department:employee:)`, `retry()`, `stop()`, and `setupSnapshot()`.
- `NASBackupRuntime.recoverySources() throws -> [NASRecoverySource]`.
- `NASBackupRuntime.paths(for source: NASRecoverySourceIdentity) throws -> BackupPaths` re-resolves and revalidates logical identity.
- `IncrementalRecoveryRestorer.preflight(sessionIDs:currentSessionIDs:) throws -> IncrementalRecoveryPlan` validates the complete missing-only source set before a protection point.
- `IncrementalRecoveryRestorer.restore(_ plan: IncrementalRecoveryPlan, to codexRoot: URL) throws -> IncrementalRecoveryResult` revalidates the plan, writes directly to final Codex recovery destinations, and returns thread-index records.

- [ ] **Step 1: Write failing runtime and recovery-source tests**

Cover no saved configuration, saved configuration with NAS absent, saved configuration with marker mismatch, valid startup starting exactly one agent, automatic 30-second retry, manual retry after reconnect, agent stop before reconfiguration, failed reconfiguration preserving and restarting the previous valid target, old-device listing, link/junction rejection, current-device sorting, all-source preflight, direct atomic restore, existing-session non-overwrite, and zero intermediate recovery packages.

The startup gate must be asserted with a fake agent factory:

```swift
try runtime.initialize()
#expect(agentFactory.createdAgents.isEmpty)
#expect(runtime.setupSnapshot().state == .unconfigured)

let target = try runtime.activate(department: "运营部", employee: "陈超")
#expect(agentFactory.createdAgents.count == 1)
#expect(agentFactory.createdAgents[0].paths.backupRoot == target.backupRoot)
```

- [ ] **Step 2: Run runtime and recovery tests and verify RED**

```bash
swift test --filter 'NASBackupRuntimeTests|IncrementalBackupCatalogTests|IncrementalRecoveryRestorerTests'
```

Expected: `NASBackupRuntime`, device-source selection, and direct incremental restorer do not exist.

- [ ] **Step 3: Implement runtime lifecycle and typed states**

Use these UI-facing states:

```swift
public enum NASSetupState: String, Codable, Sendable {
    case unconfigured
    case disconnected
    case validating
    case seeding
    case running
    case pending
    case error
}
```

`initialize()` loads logical configuration, re-resolves the production endpoint and marker, and starts the agent only on complete success. While disconnected, schedule retry every 30 seconds through an injected clock/scheduler and also expose manual `retry()`. Every retry repeats full endpoint, path, marker, and write-capability validation. `activate()` stops the previous agent, validates and provisions the new target, persists only after success, starts a fresh empty-state scan, and never migrates old NAS data. If activation fails, retain the old stored configuration and restart the old target only after revalidating it.

- [ ] **Step 4: Implement validated old-device discovery and direct recovery**

Scan only direct children of `<employee>/devices`, validate each marker against the directory name, and expose logical `NASRecoverySourceIdentity` values. `IncrementalBackupCatalog` and `IncrementalRecoveryRestorer` receive paths resolved from that identity. `preflight` validates every selected NAS JSONL before the protection point. `restore` revalidates each source, writes a synchronized same-directory temporary file directly beside `~/.codex/sessions/recovered/<session-id>.jsonl`, atomically renames it, merges `session_index.jsonl`, and returns records for the existing live SQLite thread-index writer. It creates no package directory.

- [ ] **Step 5: Run selected tests and verify GREEN**

```bash
swift test --filter 'NASBackupRuntimeTests|IncrementalBackupCatalogTests|IncrementalRecoveryRestorerTests'
```

Expected: all selected tests pass and neither the fixture NAS root nor the local vault contains a recovery-package directory.

- [ ] **Step 6: Commit Swift runtime and multi-device recovery**

```bash
git add Sources/CodexSessionVaultCore/Backup/NASBackupRuntime.swift Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift Sources/CodexSessionVaultCore/Backup/IncrementalRecoveryRestorer.swift Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift Tests/CodexSessionVaultCoreTests/NASBackupRuntimeTests.swift Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift Tests/CodexSessionVaultCoreTests/IncrementalRecoveryRestorerTests.swift Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift
git commit -m "feat: add macOS NAS runtime and device recovery"
```

---

### Task 5: macOS First-run UI, Status, Reconfiguration, and Worker Wiring

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`

**Interfaces:**
- `VaultModel` owns `NASBackupRuntime`, published `nasSetupSnapshot`, departments, employees, selected values, and recovery sources.
- `VaultWorkerCommand` carries `NASRecoverySourceIdentity?`, never a raw incremental backup path.
- `NASSetupView` is non-dismissable while state is `.unconfigured`.

- [ ] **Step 1: Add the UI state and worker contract before changing startup**

Add published state with these initial values:

```swift
@Published private(set) var nasSetupSnapshot = NASSetupSnapshot.unconfigured
@Published var nasDepartments: [NASDirectoryOption] = []
@Published var nasEmployees: [NASDirectoryOption] = []
@Published var selectedNASDepartment = ""
@Published var selectedNASEmployee = ""
@Published var nasRecoverySources: [NASRecoverySource] = []
@Published var selectedNASRecoverySourceID: UUID?
@Published var isNASSetupPresented = false
```

Extend worker command encoding with `incrementalRecoverySource: NASRecoverySourceIdentity?`. In the worker, re-resolve this identity through `NASConfigurationService`; reject missing or mismatched device markers before creating a protection point.

- [ ] **Step 2: Replace eager local backup startup**

Remove `startLocalIncrementalBackup()` from `VaultModel.init`. Initialize the NAS runtime after normal session/snapshot refresh. Unconfigured startup presents setup and creates no `BackupAgent`. Configured-but-disconnected startup leaves the main app usable, displays the disconnected state, and offers retry without clearing configuration.

- [ ] **Step 3: Implement the setup and reconfiguration sheet**

`NASSetupView` must render these transitions:

```text
检测公司 NAS -> 未连接说明/重新检测 -> 部门选择 -> 姓名选择
-> 显示固定目标确认 -> 验证中 -> 初始备份进度 -> 完成
```

There is no text path field and no folder picker. Add `刷新列表` to rerun NAS detection and catalog loading. Disable confirmation until both values came from the current catalog response. Use `.interactiveDismissDisabled(nasSetupSnapshot.state == .unconfigured)` for first run. Reconfiguration shows old and new identity and calls runtime activation only after explicit confirmation.

- [ ] **Step 4: Wire status and recovery-device selection**

Replace “本地增量备份” copy with “公司 NAS 会话备份”. Show department, employee, device, last success, pending count, and actionable failure. In backup recovery, add a source picker populated by `nasRecoverySources`; refreshing or restoring passes only the selected logical identity to the worker.

When the local runtime reports pending or seeding work, intercept application termination through an `NSApplicationDelegate` and show `NAS 备份尚未完成，仍要退出吗？`. Continue termination only after explicit confirmation; this warning must not create a local content queue.

- [ ] **Step 5: Build and run the full Swift test suite**

```bash
swift test
swift build
```

Expected: all Swift tests pass and the executable target builds without concurrency warnings promoted to errors.

- [ ] **Step 6: Commit the macOS UI integration**

```bash
git add Sources/CodexSessionVault/main.swift
git commit -m "feat: add macOS NAS backup onboarding"
```

---

### Task 6: Electron Fixed NAS Service, Settings, and Runtime Gate

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/nas-service.js`
- Create: `windows/codex_session_manager_electron/src/backup/nas-runtime.js`
- Create: `windows/codex_session_manager_electron/src/settings.js`
- Create: `windows/codex_session_manager_electron/test/backup/nas-service.test.js`
- Create: `windows/codex_session_manager_electron/test/backup/nas-runtime.test.js`

**Interfaces:**
- `createNasService({ fs, pathImpl, endpoint, shareRootResolver })`.
- `createNasRuntime({ nasService, settingsStore, agentFactory, pathsFactory, homeDir })`.
- `settingsStore.load()` and `settingsStore.savePatch()` preserve auto-restore settings and atomically persist `nasBackup`.

- [ ] **Step 1: Write failing Node NAS service and runtime tests**

Use a local temporary tree with injected `pathImpl: require('node:path')` and `shareRootResolver`. Cover wrong endpoint identity, missing root, direct-child enumeration, symlink/junction escape through `realpath`, probe cleanup, stable device UUID, collision suffix, unconfigured startup, disconnected startup, injected 30-second automatic retry, manual retry, agent stop-before-reconfigure, and failed reconfiguration restarting the previous valid target.

The runtime gate assertions must include:

```javascript
await runtime.initialize();
assert.equal(agentFactory.created.length, 0);
assert.equal(runtime.snapshot().state, 'unconfigured');

await runtime.activate({ department: '运营部', employee: '陈超' });
assert.equal(agentFactory.created.length, 1);
assert.equal(agentFactory.created[0].started, true);
```

- [ ] **Step 2: Run the Node NAS tests and verify RED**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/nas-service.test.js test/backup/nas-runtime.test.js
```

Expected: module-not-found failures for `nas-service.js` and `nas-runtime.js`.

- [ ] **Step 3: Implement fixed UNC discovery and catalog validation**

Production defaults are:

```javascript
const COMPANY_NAS = Object.freeze({
  server: '192.168.10.99',
  share: '文件中转站',
  backupRootName: 'codex会话备份',
  uncRoot: '\\\\192.168.10.99\\文件中转站',
});
```

`detect()` must perform real directory access to the fixed UNC root and trusted child. `departments()` and `employees(department)` return only canonical direct directories. Reject any component containing NUL, dot segments, slash, backslash, drive prefix, UNC prefix, or device prefix. Compare `lstat` and `realpath` at each level so symlinks, junctions, and reparse-style redirects cannot escape or masquerade as a direct child.

- [ ] **Step 4: Implement settings and runtime activation order**

`settings.js` uses a same-directory temporary file, flush, rename, and cleanup. `nas-runtime.js` follows:

```javascript
async function activate({ department, employee }) {
  await stopAgent();
  const target = await nasService.activate({ department, employee, previous: settingsStore.load().nasBackup });
  settingsStore.savePatch({ nasBackup: target.configuration });
  await startAgent(target);
  return snapshot();
}
```

If activation fails, preserve the previous stored configuration, leave the old NAS data untouched, and restart the previous target only after revalidation. `initialize()`, automatic retry every 30 seconds, and manual `retry()` re-resolve endpoint, employee path, write capability, and marker before starting an agent.

- [ ] **Step 5: Run the Node NAS tests and verify GREEN**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/nas-service.test.js test/backup/nas-runtime.test.js
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit Electron NAS service and runtime**

```bash
git add windows/codex_session_manager_electron/src/backup/nas-service.js windows/codex_session_manager_electron/src/backup/nas-runtime.js windows/codex_session_manager_electron/src/settings.js windows/codex_session_manager_electron/test/backup/nas-service.test.js windows/codex_session_manager_electron/test/backup/nas-runtime.test.js
git commit -m "feat: add trusted Windows NAS runtime"
```

---

### Task 7: Electron Crash-safe Direct NAS Writer

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/durable-write.js`
- Create: `windows/codex_session_manager_electron/test/backup/durable-write.test.js`
- Modify: `windows/codex_session_manager_electron/src/backup/paths.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Modify: `windows/codex_session_manager_electron/src/backup/cursor-store.js`
- Modify: `windows/codex_session_manager_electron/src/backup/manifest-store.js`
- Modify: `windows/codex_session_manager_electron/src/backup/models.js`
- Modify: `windows/codex_session_manager_electron/test/backup/paths.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`

**Interfaces:**
- `backupPaths({ homeDir, codexRoot, backupRoot, stateRoot, pathImpl })`.
- `writeFileDurably(filePath, data)` and `replaceFileDurably(filePath, data)`.
- `BackupAgent({ paths, validateTarget, fileCommitter, onProgress })`.
- `BackupAgent.pendingSessionCount()`.

- [ ] **Step 1: Write failing path split, durable write, and agent recovery tests**

Mirror the Swift cases and explicitly assert:

```javascript
assert.ok(paths.cursorDatabasePath.startsWith(localStateRoot));
assert.ok(paths.localStatusPath.startsWith(localStateRoot));
assert.ok(paths.manifestPath.startsWith(nasBackupRoot));
assert.ok(paths.remoteStatusPath.startsWith(nasBackupRoot));
assert.equal(
  paths.backupFilePath(activeSource),
  path.join(nasBackupRoot, 'sessions', '2026', '07', 'active.jsonl'),
);
```

Add agent tests for missing mount-root non-creation, guard-before-write, failed `FileHandle.sync()` preserving cursor, matching partial append adoption, mismatched partial append rebuild, source truncate/rewrite, archived mapping, and local-only error status.

- [ ] **Step 2: Run the selected Node tests and verify RED**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/paths.test.js test/backup/durable-write.test.js test/backup/agent.test.js
```

Expected: the new constructor and durable writer interfaces are missing.

- [ ] **Step 3: Implement split paths and synced atomic writes**

Open temporary files with `fsp.open(tempPath, 'wx')`, write the complete buffer, call `handle.sync()`, close, then rename. Clean only the unique temporary file after failure. `manifest-store.js` and remote/local status commits use this helper. Cursor-store export remains allowed because `cursorDatabasePath` is now guaranteed to be local control state, never the NAS and never live Codex SQLite.

- [ ] **Step 4: Implement guarded seed/append/rebuild ordering**

Before any remote operation, await `validateTarget()`. Require the device backup root to exist and create descendants one level at a time without `{ recursive: true }` crossing a missing parent. Use `fsp.open(target, 'a')`, write, `sync`, and close for append. Update remote manifest and then the local cursor only after the target has synchronized. On truncation or mismatch, build a full complete-line temporary target, sync, and atomically replace.

- [ ] **Step 5: Run the selected Node tests and verify GREEN**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/paths.test.js test/backup/durable-write.test.js test/backup/agent.test.js
```

Expected: all selected tests pass and no test leaves `.tmp-*` files.

- [ ] **Step 6: Commit the Electron NAS writer**

```bash
git add windows/codex_session_manager_electron/src/backup/durable-write.js windows/codex_session_manager_electron/src/backup/paths.js windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/src/backup/cursor-store.js windows/codex_session_manager_electron/src/backup/manifest-store.js windows/codex_session_manager_electron/src/backup/models.js windows/codex_session_manager_electron/test/backup/durable-write.test.js windows/codex_session_manager_electron/test/backup/paths.test.js windows/codex_session_manager_electron/test/backup/agent.test.js
git commit -m "feat: make Windows NAS backup commits crash safe"
```

---

### Task 8: Electron Protected IPC and Previous-device Recovery

**Files:**
- Modify: `windows/codex_session_manager_electron/src/backup/incremental-recovery.js`
- Modify: `windows/codex_session_manager_electron/src/main.js`
- Modify: `windows/codex_session_manager_electron/src/preload.js`
- Modify: `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`
- Modify: `windows/codex_session_manager_electron/test/security/electron-security.test.js`

**Interfaces:**
- New protected IPC: `get-nas-setup-state`, `detect-company-nas`, `list-nas-departments`, `list-nas-employees`, `activate-nas-backup`, `retry-nas-backup`, `list-nas-backup-devices`.
- Changed protected IPC: `load-incremental-backup-sessions(deviceId)` and `restore-incremental-backup-sessions(deviceId, sessionIds, protectionMode)`.
- Renderer/preload never sends a path.

- [ ] **Step 1: Write failing IPC contract and direct-recovery tests**

Assert that every new preload channel has a `handleTrustedIpc` registration, `main.js` contains no direct `ipcMain.handle`, removed local-agent identifiers are absent, raw path parameters are absent, unknown device IDs are rejected before protection-point creation, every selected NAS source is preflighted before the protection point, and no intermediate recovery package is created.

- [ ] **Step 2: Run the selected Electron tests and verify RED**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/incremental-recovery.test.js test/security/electron-security.test.js
```

Expected: missing channels and old local backup-root assumptions fail.

- [ ] **Step 3: Replace eager agent startup with NAS runtime initialization**

Remove module-level `localBackupPaths` and `localBackupAgent`. Create one `nasRuntime` and call `await nasRuntime.initialize()` after `app.whenReady()`. `loadState()` returns `nasSetup` and runtime-produced backup status. An unconfigured or disconnected runtime creates no agent.

- [ ] **Step 4: Register setup and recovery-device IPC through the trusted registrar**

Handlers accept only catalog names or device UUID strings. Before returning a catalog, building a recovery catalog, or restoring, the main process calls the runtime/service to re-resolve and validate the fixed endpoint and device marker. Resolve the selected device to `BackupPaths` only inside the main process.

Attach a `mainWindow.on('close')` guard. If runtime state is `seeding` or `pending`, prevent the first close, show `NAS 备份尚未完成，仍要退出吗？` through the main-process dialog, and close only after explicit confirmation. Do not serialize conversation content for this check.

- [ ] **Step 5: Replace package generation with direct atomic recovery**

Replace `buildIncrementalRecoveryPackage` with `preflightIncrementalRecovery` and `restoreIncrementalSessions`. Preflight validates the complete selected source set under the resolved device root before the protection point. Restore revalidates each source, writes a synchronized temporary file directly beside the final `~/.codex/sessions/recovered/<session-id>.jsonl`, atomically renames it, merges `session_index.jsonl`, and passes recovered thread metadata to the existing native-SQLite index writer. No recovery package directory may be created on the NAS or under the local vault.

- [ ] **Step 6: Run the selected Electron tests and verify GREEN**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/incremental-recovery.test.js test/security/electron-security.test.js
```

Expected: selected tests pass; all NAS IPC handlers are guarded.

- [ ] **Step 7: Commit Electron main-process NAS integration**

```bash
git add windows/codex_session_manager_electron/src/backup/incremental-recovery.js windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/src/preload.js windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js windows/codex_session_manager_electron/test/security/electron-security.test.js
git commit -m "feat: secure Windows NAS backup IPC"
```

---

### Task 9: Electron First-run and Reconfiguration UI

**Files:**
- Create: `windows/codex_session_manager_electron/test/security/nas-ui-contract.test.js`
- Modify: `windows/codex_session_manager_electron/src/index.html`
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
- Modify: `windows/codex_session_manager_electron/src/styles.css`

**Interfaces:**
- Blocking `#nasSetupModal` for unconfigured state.
- `#nasDepartment`, `#nasEmployee`, `#nasRetryBtn`, `#nasConfirmBtn`, and `#nasReconfigureBtn`.
- Recovery source select passes `deviceId` only.

- [ ] **Step 1: Write a failing renderer contract test**

The contract test reads HTML/renderer/preload text and asserts:

```javascript
assert.match(html, /id="nasSetupModal"/);
assert.match(html, /id="nasDepartment"/);
assert.match(html, /id="nasEmployee"/);
assert.doesNotMatch(html, /type="file"/);
assert.doesNotMatch(renderer, /backupPathInput|nasPathInput|selectDirectory/);
assert.match(renderer, /activateNasBackup/);
assert.match(renderer, /selectedNasRecoveryDeviceId/);
```

- [ ] **Step 2: Run the UI contract and verify RED**

```bash
cd windows/codex_session_manager_electron
node --test test/security/nas-ui-contract.test.js
```

Expected: setup elements and renderer behavior are absent.

- [ ] **Step 3: Implement the blocking first-run flow**

Render `检测公司 NAS -> 未连接/重新检测 -> 部门 -> 姓名 -> 目标确认 -> 验证/初始备份`. The modal has no close action while unconfigured. Department changes clear employee selection and reload employees. Confirmation remains disabled until both values exist in the latest returned catalogs. Display the fixed server/share and recognized `部门 / 姓名`; never render an editable path.

- [ ] **Step 4: Implement status, retry, reconfiguration, and recovery-source UI**

Rename the sidebar status to “公司 NAS 会话备份”. Render unconfigured, disconnected, seeding progress, running, pending, and error states. Add a settings reconfiguration button that shows old/new identity and requires confirmation. Add a recovery-device picker with current device first and old devices labeled by name/last backup time.

- [ ] **Step 5: Run UI contract and syntax checks**

```bash
cd windows/codex_session_manager_electron
node --test test/security/nas-ui-contract.test.js
node --check src/main.js
node --check src/preload.js
node --check src/renderer.js
```

Expected: contract passes and all syntax checks exit 0.

- [ ] **Step 6: Commit Electron NAS UI**

```bash
git add windows/codex_session_manager_electron/src/index.html windows/codex_session_manager_electron/src/renderer.js windows/codex_session_manager_electron/src/styles.css windows/codex_session_manager_electron/test/security/nas-ui-contract.test.js
git commit -m "feat: add Windows NAS backup onboarding"
```

---

### Task 10: Documentation, Regression Verification, Packaging, and Real NAS Acceptance

**Files:**
- Modify: `README.md`
- Modify: `docs/操作手册.md`
- Modify: `windows/codex_session_manager_electron/README_WIN10_EXE.md`
- Modify: `Sources/CodexSessionVault/main.swift`
- Modify: `scripts/build_app.sh`
- Modify: `windows/codex_session_manager_electron/package.json`
- Modify: `windows/codex_session_manager_electron/package-lock.json`

**Interfaces:**
- User documentation matches the fixed endpoint, no-credential behavior, no-local-spool limitation, device layout, recovery-source selection, and shared-account security boundary.

- [ ] **Step 1: Update user and operator documentation**

Replace “本地增量备份” and “第一阶段不上传 NAS” text. Document first-run NAS connection, dynamic department/name selection, retry, reconfiguration, per-device directories, old-device recovery, local snapshots, excluded sensitive files, and the accepted risk when the NAS is offline and the source is deleted. State clearly that shared identity `171` does not isolate employee confidentiality.

- [ ] **Step 2: Run full automated verification**

Before verification, change every application/package version owned by this repository from `1.0.13` to `1.0.14`, including Swift snapshot metadata, macOS `Info.plist` generation, Electron `package.json`, and lockfile root-package metadata. Do not change dependency versions.

```bash
swift test
swift build
cd windows/codex_session_manager_electron
npm test
node --check src/main.js
node --check src/preload.js
node --check src/renderer.js
node --check src/backup/nas-service.js
node --check src/backup/nas-runtime.js
node --check src/backup/backup-agent.js
```

Expected: all Swift and Node tests pass; all syntax checks exit 0.

- [ ] **Step 3: Run static scope and safety searches**

From the repository root:

```bash
rg -n "startLocalIncrementalBackup|Local incremental backup|本地增量备份|第一阶段只保存到本机" Sources windows README.md docs/操作手册.md
rg -n "ipcMain\.handle" windows/codex_session_manager_electron/src/main.js
rg -n "auth\.json|config\.toml|state_5\.sqlite" Sources/CodexSessionVaultCore/Backup windows/codex_session_manager_electron/src/backup/nas-*.js
git diff --check
```

Expected: the first two searches return no production matches; sensitive filenames appear only in explicit exclusion/tests or unrelated local snapshot/restore code; `git diff --check` exits 0.

- [ ] **Step 4: Build distributable artifacts**

From the repository root:

```bash
./scripts/build_app.sh
cd windows/codex_session_manager_electron
npm run package:win
```

Expected:

- `dist/codex_会话管理.app` exists and launches on macOS 14+.
- `dist/win10-exe/codex_session_manager-win32-x64` exists.
- The Windows package contains `resources/app/src/backup/nas-service.js`, `nas-runtime.js`, `durable-write.js`, and `vendor/sqlite3.exe`.

- [ ] **Step 5: Perform real NAS acceptance on macOS**

Using the mounted share `192.168.10.99/文件中转站`, verify:

1. Fresh local settings force setup before any backup agent starts.
2. Departments and employees match direct NAS folders.
3. Choosing `运营部 / 陈超` creates only `陈超/devices/<device>/...`.
4. Initial active and archived JSONL appear on NAS; excluded files do not.
5. New complete JSONL lines append and survive app restart.
6. Disconnecting SMB produces a visible paused/disconnected state and does not create `/Volumes/文件中转站` as a local directory.
7. Reconnecting catches up without duplicate lines.
8. A source truncate/rewrite rebuilds the NAS file without stale trailing content.
9. A second device identity writes to another directory.
10. The current machine can list and restore a missing conversation from the first device.

- [ ] **Step 6: Perform Windows 10 acceptance**

Repeat the same matrix using `\\192.168.10.99\文件中转站`, including a process kill during append and Codex writing concurrently to its source JSONL. Confirm the packaged app never asks for or stores an SMB password and never accepts an arbitrary path.

- [ ] **Step 7: Commit documentation and verification adjustments**

```bash
git add README.md docs/操作手册.md windows/codex_session_manager_electron/README_WIN10_EXE.md Sources/CodexSessionVault/main.swift scripts/build_app.sh windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/package-lock.json
git commit -m "docs: document company NAS conversation backups"
```

- [ ] **Step 8: Final branch review before push**

```bash
git status --short
git log --oneline --decorate -12
git diff windows-test/codex/incremental-backup-restore...HEAD --stat
```

Expected: only the pre-existing untracked `.codegraph/` remains; commits are limited to this feature and the approved design/plan; no generated package or NAS data is staged.

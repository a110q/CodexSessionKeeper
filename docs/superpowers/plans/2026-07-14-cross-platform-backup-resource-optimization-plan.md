# Cross-Platform NAS Backup Resource Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the always-on macOS and Windows backup resource footprint while preserving 30-second incremental NAS protection, adding one staggered daily full integrity audit, and automatically repairing corrupted NAS session files from a validated local committed prefix.

**Architecture:** Keep the existing polling and NAS directory design, but make UI status reads memory-only, serialize and coalesce all backup triggers, load and write cursor rows in batches, skip unchanged files before any NAS per-file operation, and stream all large-file rebuild/audit/repair work with bounded buffers. A per-device integrity auditor runs at most once per 24 hours, yields to incremental work, and quarantines a damaged NAS copy before atomic repair.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, SwiftUI, Foundation, CryptoKit, and `/usr/bin/sqlite3` on macOS 14+; Electron 43.1.0, Node.js, `node:test`, built-in `fs`/`crypto`, and existing `sql.js` on Windows 10 x64.

## Global Constraints

- Preserve the approved NAS endpoint, department/employee/device hierarchy, first-run configuration flow, recovery flow, required manifest fields, and backup format version.
- Preserve a maximum normal detection interval of 30 seconds and issue immediate scans after startup, first activation, wake, and validated NAS reconnection.
- Do not add filesystem watchers, dependencies, Electron upgrades, snapshot changes, restore changes, IPC shape changes, or unrelated security work.
- UI and exit-protection status reads must be O(1) in-memory reads. They must not enumerate sessions, read `status.json`, query SQLite, inspect NAS files, or launch work.
- Incremental, audit, and repair mutation for one device must be serialized. Multiple triggers coalesce into at most one queued rescan.
- A no-change scan must perform no JSONL body read, source hash, per-target NAS stat, manifest write, cursor write, or Windows `db.export()`.
- Durability order remains: NAS bytes and `fsync` -> manifest commit -> cursor batch commit. Never advance a cursor first.
- All large JSONL work must use bounded streaming buffers; memory use must not scale with the largest session file.
- After range-only append verification, clear the optional manifest `contentHash`. Initial seed, rebuild, daily audit, and successful repair set a complete current hash.
- Audit and repair operate only through existing trusted source/target path boundaries. Symlinks, junctions, non-regular files, or escaped canonical paths fail closed.
- Automatic repair may use only the validated local prefix through the committed complete-line offset. An unsafe, missing, unreadable, or structurally invalid local source never overwrites NAS.
- Quarantine is app-owned, retained for 30 days, and capped at the three newest copies per session. Cleanup must not touch formal backups or unrelated NAS content.
- Keep `.codegraph/` untracked and out of every commit.
- Before accepting macOS work, repair the current machine's Swift compiler/SDK mismatch and obtain a fresh passing `swift test`; a historical passing run is insufficient.

---

## Task 0: Establish Reproducible Baselines

**Files:**
- No repository changes.

**Interfaces:**
- None.

- [ ] **Step 1: Verify branch and working tree**

Run:

```bash
git status --short --branch
git log -3 --oneline
```

Expected: branch `codex/nas-direct-backup`, only intentional plan/spec commits ahead of its private upstream, and no unrelated tracked changes.

- [ ] **Step 2: Verify the macOS toolchain before writing Swift tests**

Run:

```bash
xcrun swift --version
xcrun --show-sdk-path
swift test
```

Expected: compiler and SDK module versions agree and all current Swift tests pass. If the existing `Swift 6.3.1` compiler versus `Swift 6.3` SDK error remains, repair/update Xcode Command Line Tools outside this repository, rerun these commands, and stop macOS implementation until the baseline is green.

- [ ] **Step 3: Record the Windows baseline**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: `116` tests pass before implementation.

---

## Task 1: Batch macOS Cursor Reads and Writes

**Files:**
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift`

**Interfaces:**

```swift
public func loadAll() throws -> [String: BackupCursor]
public func upsertMany(_ cursors: [BackupCursor]) throws
```

Keep `cursor(sourcePath:)` and `upsert(_:)` only as thin compatibility wrappers. `upsert(_:)` delegates to `upsertMany([cursor])`; production scans use only bulk APIs.

- [ ] **Step 1: Add failing bulk-read and bulk-write tests**

Add tests that create three cursors containing quotes, spaces, and Unicode paths, then assert one materialized dictionary and atomic replacement of matching rows:

```swift
@Test func bulkLoadAndUpsertRoundTrip() throws {
    let fixture = try CursorStoreFixture()
    let original = fixture.cursor(sourcePath: "/tmp/会话 one.jsonl", offset: 10)
    let second = fixture.cursor(sourcePath: "/tmp/o'ne.jsonl", offset: 20)

    try fixture.store.upsertMany([original, second])
    let rows = try fixture.store.loadAll()

    #expect(rows.count == 2)
    #expect(rows[original.sourcePath]?.lastByteOffset == 10)
    #expect(rows[second.sourcePath]?.lastByteOffset == 20)
}
```

Add an injected SQLite-runner spy and assert `loadAll()` invokes SQLite once and `upsertMany()` invokes it once regardless of row count. Add a failing transaction test whose second statement violates a constraint and assert neither cursor changes.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
swift test --filter BackupCursorStoreTests
```

Expected: FAIL because `loadAll()` and `upsertMany(_:)` do not exist.

- [ ] **Step 3: Implement one-process bulk loading**

Have `loadAll()` execute one deterministic `SELECT` through `sqlite3 -json`, decode every row, and key the result by canonical `sourcePath`. Preserve the existing column schema and decoding behavior. Reject duplicate paths rather than silently selecting an arbitrary row.

- [ ] **Step 4: Implement one-transaction bulk upsert**

Generate one stdin script containing `.bail on`, `.timeout 5000`, `BEGIN IMMEDIATE`, all escaped fixed-shape upserts, and `COMMIT`. An empty array returns without launching SQLite. On any error, SQLite rolls back on connection close and the method throws.

- [ ] **Step 5: Run focused and full Swift tests**

Run:

```bash
swift test --filter BackupCursorStoreTests
swift test
```

Expected: PASS, with the bulk spy proving one read process and one write process.

- [ ] **Step 6: Commit the cursor-store change**

```bash
git add Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift
git commit -m "perf: batch macOS backup cursors"
```

---

## Task 2: Stream macOS Session Writes and Add the No-Change Fast Path

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/SessionBackupStreamer.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/DurableAtomicWriter.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupFileCommitter.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
- Create: `Tests/CodexSessionVaultCoreTests/SessionBackupStreamerTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentNASTests.swift`

**Interfaces:**

```swift
public struct StreamedBackupResult: Equatable, Sendable {
    public let committedByteCount: Int64
    public let lineCount: Int
    public let contentHash: String
}

public struct SessionBackupStreamer: Sendable {
    public func rebuildCompleteLines(
        source: URL,
        through maximumOffset: Int64?,
        destination: URL
    ) throws -> StreamedBackupResult

    public func rangesMatch(
        source: URL, sourceOffset: Int64,
        target: URL, targetOffset: Int64,
        length: Int64
    ) throws -> Bool
}

public func replace(
    at destination: URL,
    createParentDirectories: Bool = false,
    writer: (FileHandle) throws -> Void
) throws
```

- [ ] **Step 1: Write failing bounded-streaming tests**

Use an injected 1 MiB chunk size in tests. Cover a file larger than three chunks, a 32 MiB legal line crossing chunks, a partial final line, an empty file, and an injected mid-write failure. Assert only complete newline-terminated records reach the destination, the result hash covers exactly committed bytes, and the old destination survives a failed replacement.

```swift
@Test func rebuildStreamsOnlyCompleteLines() throws {
    let fixture = try StreamerFixture(source: Data("one\ntwo\npartial".utf8))
    let result = try fixture.streamer.rebuildCompleteLines(
        source: fixture.source, through: nil, destination: fixture.target
    )

    #expect(try Data(contentsOf: fixture.target) == Data("one\ntwo\n".utf8))
    #expect(result.committedByteCount == 8)
    #expect(result.lineCount == 2)
}
```

- [ ] **Step 2: Write failing scan-classification tests**

Extend the backup-agent fixture with spies for source body reads, target stats, hashes, manifest writes, cursor reads/writes, and SQLite runner invocations. Add these assertions:

```swift
@Test func unchangedScanStopsBeforeTargetAccess() throws {
    let fixture = try BackupAgentFixture.seededSession()
    fixture.resetSpies()

    try fixture.agent.performOneShotScan()

    #expect(fixture.sourceBodyReadCount == 0)
    #expect(fixture.targetStatCount == 0)
    #expect(fixture.fullHashCount == 0)
    #expect(fixture.manifestWriteCount == 0)
    #expect(fixture.cursorWriteBatchCount == 0)
}
```

Also test: appending one complete record reads/verifies only that byte range; a same-size new-mtime rewrite streams a rebuild; truncation rebuilds; missing target rebuilds; partial trailing lines do not advance; and a range-only append clears `manifestEntry.contentHash`.

- [ ] **Step 3: Run focused tests and confirm failure**

Run:

```bash
swift test --filter SessionBackupStreamerTests
swift test --filter BackupAgentTests
swift test --filter BackupAgentNASTests
```

Expected: FAIL because streaming writer and bulk-map scan behavior are absent.

- [ ] **Step 4: Add the atomic streaming writer**

Implement `DurableAtomicWriter.replace(at:permissions:writer:)` with a unique same-directory temporary file, explicit `FileHandle.synchronize()`, close, atomic replacement, parent-directory synchronization where supported, and guaranteed temporary cleanup. Keep the existing `Data` overload by delegating to this writer.

- [ ] **Step 5: Implement bounded rebuild and range comparison**

`SessionBackupStreamer` reads at most 1 MiB per operation, carries at most one incomplete line up to the existing 32 MiB limit, writes complete records directly to the temporary handle, and updates SHA-256 and line count in the same pass. `rangesMatch` compares equal-sized chunks and never calls `Data(contentsOf:)` for the entire file.

- [ ] **Step 6: Refactor the scan to use one cursor map**

At scan start call `cursorStore.loadAll()` once. Pass the map entry into `processSessionFile`; do not let that method query the store. Collect changed cursors in memory and call `upsertMany()` exactly once after the manifest is durable. Remove the post-loop cursor reread.

- [ ] **Step 7: Implement the strict unchanged fast path**

Classify a file unchanged only when canonical source path, source size, source mtime, cursor committed offset, pending-partial state, backup relative path, and manifest size/path metadata agree. Return before target stat or any body read. For appends, verify only `[oldOffset, newOffset)` source/target ranges. For rewrite, truncation, missing target, or unprovable interrupted state, use the streaming rebuild.

- [ ] **Step 8: Remove the error-path rescan**

Change `writeErrorStatus()` so it reports the last known in-memory pending count. It must not call `pendingSessionCount()` or launch a second discovery/cursor pass after failure.

- [ ] **Step 9: Run focused and full Swift tests**

Run:

```bash
swift test --filter SessionBackupStreamerTests
swift test --filter BackupAgentTests
swift test --filter BackupAgentNASTests
swift test
```

Expected: PASS. A 500-session no-change fixture reports one cursor bulk read, zero target calls, and zero cursor writes.

- [ ] **Step 10: Commit the macOS scan change**

```bash
git add Sources/CodexSessionVaultCore/Backup Tests/CodexSessionVaultCoreTests/SessionBackupStreamerTests.swift Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift Tests/CodexSessionVaultCoreTests/BackupAgentNASTests.swift
git commit -m "perf: stream macOS backup scans"
```

---

## Task 3: Add the macOS Daily Integrity Auditor and Safe Repair

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/BackupIntegrityAuditor.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupModels.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupPaths.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
- Create: `Tests/CodexSessionVaultCoreTests/BackupIntegrityAuditorTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentNASTests.swift`

**Interfaces:**

```swift
public struct IntegrityAuditState: Codable, Equatable, Sendable {
    public var lastCompletedAt: Date?
    public var lastResult: String?
    public var repairedCount: Int
}

public enum IntegrityAuditOutcome: Equatable, Sendable {
    case notDue
    case completed(checked: Int, repaired: Int)
    case interrupted
}

public struct BackupIntegrityAuditor: Sendable {
    public static func dailyOffsetSeconds(deviceID: UUID) -> TimeInterval
    public static func overdueWakeDelaySeconds(deviceID: UUID) -> TimeInterval
    public func runIfDue(
        now: Date,
        deviceID: UUID,
        cursors: [String: BackupCursor],
        interruptionRequested: @Sendable () -> Bool
    ) throws -> IntegrityAuditOutcome
}
```

Add `BackupPaths.auditStateURL` under local state and `BackupPaths.repairQuarantineRoot` under the validated device backup root.
Extend `BackupStatus` with backward-compatible optional `lastAuditAt`, `lastAuditResult`, `lastRepairAt`, and `repairCount` fields; do not increment `BackupManifest.version`.

- [ ] **Step 1: Write failing schedule tests**

Assert SHA-256-derived scheduling is stable across process launches, stays in `0..<86400`, the overdue wake delay stays in `0...1800`, an audit completed less than 24 hours ago returns `.notDue`, and first seed initialization prevents an immediate redundant audit. Do not use Swift's randomized `Hasher`. The cross-platform fixture UUID `00000000-0000-0000-0000-000000000001` must produce daily offset `38733` seconds and overdue delay `676` seconds.

- [ ] **Step 2: Write failing streaming audit and interruption tests**

Create multi-chunk local/NAS fixtures. Assert comparison stops at `cursor.lastByteOffset`, ignores a partial local tail, detects corruption in any chunk, and checks `interruptionRequested` at each chunk boundary. If interrupted, assert no manifest hash or audit-state timestamp changes and the next run restarts that file at byte zero.

- [ ] **Step 3: Write failing repair and quarantine tests**

Cover success plus failure injection before temp flush, before quarantine copy, before replace, after replace verification, and during metadata commit. The success contract is:

```swift
let outcome = try fixture.auditor.runIfDue(
    now: fixture.dueDate,
    deviceID: fixture.deviceID,
    cursors: fixture.cursors,
    interruptionRequested: { false }
)

#expect(outcome == .completed(checked: 1, repaired: 1))
#expect(try fixture.nasTargetData() == fixture.committedLocalPrefix)
#expect(try fixture.quarantineCopies().count == 1)
#expect(try fixture.quarantineCopies().first?.data == fixture.corruptedNASData)
```

Also assert missing, symlinked, escaped, non-regular, unreadable, and structurally invalid local sources never replace the formal NAS file.

- [ ] **Step 4: Write failing retention tests**

Create five application-owned copies plus unrelated files. Assert cleanup removes copies older than 30 days, retains at most the newest three per session, refuses link entries, and leaves formal backups and unrelated NAS paths untouched.

- [ ] **Step 5: Run focused tests and confirm failure**

Run:

```bash
swift test --filter BackupIntegrityAuditorTests
swift test --filter BackupPathsTests
```

Expected: FAIL because the auditor, audit state, and quarantine paths do not exist.

- [ ] **Step 6: Implement deterministic scheduling and local state**

Hash the lowercased UUID string with SHA-256. Convert the first eight digest bytes using fixed big-endian order; modulo `86400` selects the daily offset and a separate digest slice modulo `1801` selects overdue wake delay. Persist audit state atomically below local device state. A successful initial full seed writes `lastCompletedAt`; cancelled, unavailable, and failed audits do not.

- [ ] **Step 7: Implement one-file-at-a-time streaming verification**

Reuse the same 1 MiB range reader. Validate the local and NAS canonical paths before opening. Compare exactly the committed prefix and calculate the complete hash only after equality is proved. Buffer equal-file hash changes in memory and save them once only after the whole audit completes; cancellation discards the buffer. A completed automatic repair is its own durable operation and commits only that session's repaired metadata immediately, without falsely advancing `lastCompletedAt` for the interrupted overall audit.

- [ ] **Step 8: Implement quarantine-before-repair**

Stream the validated local committed prefix to a same-directory repair temp while hashing, flush it, then durably copy the current NAS target to a trusted quarantine filename containing session ID, timestamp, and random suffix. Atomically replace, reopen, stream-verify, then update manifest/cursor/audit/runtime state in durability order. On failed post-replace verification, restore from the already-verified quarantine copy before reporting failure.

- [ ] **Step 9: Integrate audit priority with the agent**

Run auditing only after incremental catch-up. When any scan trigger is queued, set the auditor's interruption flag; the auditor exits at the next chunk boundary, the agent runs the incremental scan, and a later audit restarts the interrupted file. No audit and incremental writer may run concurrently.

- [ ] **Step 10: Run focused and full Swift tests**

```bash
swift test --filter BackupIntegrityAuditorTests
swift test --filter BackupAgentNASTests
swift test
```

Expected: PASS, including all injected failure invariants and bounded-read assertions.

- [ ] **Step 11: Commit the macOS auditor**

```bash
git add Sources/CodexSessionVaultCore/Backup Tests/CodexSessionVaultCoreTests/BackupIntegrityAuditorTests.swift Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift Tests/CodexSessionVaultCoreTests/BackupAgentNASTests.swift
git commit -m "feat: audit and repair macOS NAS backups"
```

---

## Task 4: Make macOS Runtime Status Memory-Only and Add Lifecycle Triggers

**Files:**
- Modify: `Sources/CodexSessionVaultCore/Backup/NASBackupRuntime.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
- Modify: `Sources/CodexSessionVault/main.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/NASBackupRuntimeTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift`

**Interfaces:**

```swift
public enum BackupScanTrigger: String, Sendable {
    case startup, activation, timer, wake, reconnect, queued
}

public protocol NASBackupAgentControlling: AnyObject {
    func startPolling(intervalSeconds: UInt64)
    func requestImmediateScan(_ trigger: BackupScanTrigger)
    func stop()
}
```

`BackupAgent` gains a sendable status callback that publishes the persisted backup status after every background state transition. `NASBackupRuntime.setupSnapshot()` returns only the runtime's cached immutable value.
Extend `NASSetupSnapshot` with optional `lastAuditAt`, `lastAuditResult`, `lastRepairAt`, and `repairCount` values copied from cached agent status. Preserve existing initializer call sites with defaults.

- [ ] **Step 1: Replace status-I/O expectations with zero-I/O tests**

Change existing runtime tests that expect `pendingSessionCount()` or local status reads. Inject spies and assert 100 repeated `setupSnapshot()` calls make zero agent, filesystem, SQLite, JSONL, and NAS calls.

```swift
@Test @MainActor func setupSnapshotIsPureCachedRead() async throws {
    let fixture = try RuntimeFixture()
    for _ in 0..<100 { _ = fixture.runtime.setupSnapshot() }
    #expect(fixture.agent.pendingCallCount == 0)
    #expect(fixture.statusReadCount == 0)
}
```

- [ ] **Step 2: Add failing serialization and coalescing tests**

Use a controlled scan barrier. Fire timer, wake, and reconnect triggers while one scan is active. Assert maximum concurrent scans is one and exactly one follow-up scan occurs. Assert `stop()` prevents new timer/audit work and does not wait indefinitely.

- [ ] **Step 3: Add failing lifecycle contract tests**

Assert the production interval is `30`, application startup and first activation request immediate scans, `NSWorkspace.didWakeNotification` requests `.wake`, and a transition from unavailable to validated NAS requests `.reconnect`.

- [ ] **Step 4: Run focused tests and confirm failure**

```bash
swift test --filter NASBackupRuntimeTests
swift test --filter BackupAgentTests
swift test --filter MacNASWiringContractTests
```

Expected: FAIL because status still performs work, polling defaults to 10 seconds, and wake/immediate trigger interfaces are absent.

- [ ] **Step 5: Implement a detached serialized worker**

Replace actor-inheriting `Task {}` scan execution with `Task.detached` or a dedicated serial executor owned by `BackupAgent`. Protect `isScanning`, `rescanQueued`, audit cancellation, and stop state under one synchronization strategy. A trigger during work sets one Boolean queue flag; completion drains at most one extra scan before returning to the 30-second timer.

- [ ] **Step 6: Make runtime snapshots pure memory reads**

Load persisted status once during runtime/agent initialization. Thereafter update cache only from agent status callbacks, setup state transitions, and background errors. Remove `pendingSessionCount()` and repeated status-file reads from `setupSnapshot()` and the UI refresh path.

- [ ] **Step 7: Wire startup, activation, wake, and reconnect**

Use `NSWorkspace.shared.notificationCenter`'s `didWakeNotification` in the app layer, forwarding only `.wake` to the runtime. Keep lifecycle observer ownership explicit and remove observers on teardown. Detect reconnect only after the NAS target validator succeeds following an unavailable state.

- [ ] **Step 8: Run focused and full Swift verification**

```bash
swift test --filter NASBackupRuntimeTests
swift test --filter BackupAgentTests
swift test --filter MacNASWiringContractTests
swift test
./scripts/build_app.sh
```

Expected: PASS. The app build contains no status-triggered SQLite path, interval is 30 seconds, and lifecycle triggers coalesce.

- [ ] **Step 9: Commit the macOS runtime change**

```bash
git add Sources/CodexSessionVaultCore/Backup/NASBackupRuntime.swift Sources/CodexSessionVaultCore/Backup/BackupAgent.swift Sources/CodexSessionVault/main.swift Tests/CodexSessionVaultCoreTests/NASBackupRuntimeTests.swift Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift
git commit -m "perf: make macOS backup runtime idle"
```

---

## Task 5: Batch Windows Cursor Updates into One Export

**Files:**
- Modify: `windows/codex_session_manager_electron/src/backup/cursor-store.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`

**Interfaces:**

```js
all() // returns Map<string, BackupCursor>
async upsertMany(cursors) // one transaction, at most one flush/export
```

Keep `get()` for non-scan compatibility. `upsert(cursor)` delegates to `upsertMany([cursor])`; production scans call `all()` once and `upsertMany()` at most once.

- [ ] **Step 1: Add failing cursor-map and export-count tests**

Instrument `db.export` directly instead of using only `fs.writeFile` counts:

```js
test('many changed cursors produce one export', async () => {
  const fixture = await createCursorFixture();
  const exportSpy = fixture.spyOnExport();
  await fixture.store.upsertMany([
    fixture.cursor('/tmp/one.jsonl', 10),
    fixture.cursor('/tmp/two.jsonl', 20),
  ]);
  assert.equal(exportSpy.calls, 1);
  assert.equal(fixture.store.all().size, 2);
});
```

Add no-change `upsertMany([])` -> zero export, SQL failure -> rollback and zero durable replacement, durable replacement failure -> previous DB remains readable, and full-agent scans with many changed files -> one export.

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/agent.test.js
```

Expected: FAIL because `all()`/`upsertMany()` do not exist and current `upsert()` exports once per row.

- [ ] **Step 3: Implement map loading and transactional batching**

Materialize all fixed cursor columns into a `Map` at scan start. Wrap all prepared upserts in one `BEGIN IMMEDIATE`/`COMMIT`; rollback on any exception. Export once only after commit, and make an empty collection a true no-op.

- [ ] **Step 4: Change the agent to use the map**

Pass `cursorMap.get(sourcePath)` into per-session processing, collect changed cursors, update the in-memory map as results arrive, and call one `upsertMany(changedCursors)` after durable manifest commit. Remove per-file `get()` and post-loop rereads.

- [ ] **Step 5: Run focused and full Windows tests**

```bash
node --test test/backup/agent.test.js
npm test
```

Expected: PASS; no-change scan exports zero times, any changed scan exports at most once.

- [ ] **Step 6: Commit Windows cursor batching**

```bash
git add windows/codex_session_manager_electron/src/backup/cursor-store.js windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/test/backup/agent.test.js
git commit -m "perf: batch Windows backup cursors"
```

---

## Task 6: Bound Windows JSONL Memory and Add the No-Change Fast Path

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/session-backup-streamer.js`
- Modify: `windows/codex_session_manager_electron/src/backup/durable-write.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Create: `windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`

**Interfaces:**

```js
async function durableReplaceWithWriter(targetPath, writer)
async function rebuildCompleteLines({ sourcePath, targetPath, maximumOffset, chunkSize })
async function rangesMatch({ sourcePath, sourceOffset, targetPath, targetOffset, length, chunkSize })
```

`rebuildCompleteLines` returns `{ committedByteCount, lineCount, contentHash }`.

- [ ] **Step 1: Add failing large-file streaming tests**

Use a small injected chunk size to force boundary behavior. Assert complete lines only, a legal long line spanning chunks, partial final line exclusion, bounded maximum read request, stable SHA-256, and atomic preservation of the old target on injected failure.

- [ ] **Step 2: Add failing no-whole-file-read tests**

Patch `fs.promises.readFile` to throw for session JSONL paths. Cover target prefix reconciliation, `stats`, append, rewrite, and a file larger than several chunks. The optimized code must pass using file handles/streams, never `readFile(target)`.

- [ ] **Step 3: Add failing unchanged/append classification tests**

Assert a no-change scan stops before target `stat`, body read, hash, manifest write, cursor write, and export. Assert one appended record reads/verifies only its range and clears optional `contentHash`; same-size changed-mtime rewrite and truncation stream a complete rebuild.

- [ ] **Step 4: Run focused tests and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/session-backup-streamer.test.js test/backup/agent.test.js
```

Expected: FAIL because current target comparison/stats use `readFile`, and unchanged scans still perform full-prefix work.

- [ ] **Step 5: Implement streaming durable replacement**

Open a unique same-directory temp with exclusive creation, pass its `FileHandle` to the writer, `sync`, close, and atomically rename/replace. Clean up on every error. Keep the existing buffer API by delegating to the writer form.

- [ ] **Step 6: Implement streaming rebuild, stats, and range checks**

Use fixed 1 MiB reads. Carry only the current incomplete line up to the existing 32 MiB limit. Count newlines and hash while writing; do not reread the completed target to obtain stats. Replace `targetIsCompletePrefix` and target `stats` whole-file reads with streaming comparisons/counters.

- [ ] **Step 7: Implement the same strict fast path as macOS**

Use local canonical path/size/mtime plus cursor and manifest metadata to skip unchanged sessions before any per-file NAS target call. Append only the committed new range. Rebuild only the affected session when required. Preserve identical classification semantics between platforms.

- [ ] **Step 8: Run focused and full Windows tests**

```bash
node --test test/backup/session-backup-streamer.test.js test/backup/agent.test.js
npm test
node --check src/backup/session-backup-streamer.js
node --check src/backup/durable-write.js
node --check src/backup/backup-agent.js
```

Expected: PASS, with no whole-file target reads and bounded memory independent of JSONL size.

- [ ] **Step 9: Commit the Windows streaming change**

```bash
git add windows/codex_session_manager_electron/src/backup/session-backup-streamer.js windows/codex_session_manager_electron/src/backup/durable-write.js windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/test/backup/session-backup-streamer.test.js windows/codex_session_manager_electron/test/backup/agent.test.js
git commit -m "perf: stream Windows backup scans"
```

---

## Task 7: Add the Windows Daily Integrity Auditor and Safe Repair

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/integrity-auditor.js`
- Modify: `windows/codex_session_manager_electron/src/backup/models.js`
- Modify: `windows/codex_session_manager_electron/src/backup/paths.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Create: `windows/codex_session_manager_electron/test/backup/integrity-auditor.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/paths.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`

**Interfaces:**

```js
function dailyOffsetSeconds(deviceId)
function overdueWakeDelaySeconds(deviceId)

class BackupIntegrityAuditor {
  async runIfDue({ now, deviceId, cursors, interruptionRequested })
  // { outcome: 'not-due' | 'completed' | 'interrupted', checked, repaired }
}
```

Add `auditStatePath` below local state and `repairQuarantineRoot` below the validated device backup root.
Persist optional `lastAuditAt`, `lastAuditResult`, `lastRepairAt`, and `repairCount` status properties without changing `MANIFEST_VERSION`.

- [ ] **Step 1: Add failing deterministic schedule tests**

Use Node `crypto.createHash('sha256')` over the lowercase UUID and fixed big-endian digest slices. Assert the same range and 24-hour rules as macOS. The shared fixture UUID `00000000-0000-0000-0000-000000000001` must produce daily offset `38733` seconds and overdue delay `676` seconds.

- [ ] **Step 2: Add failing audit/interruption tests**

Cover multi-chunk equality, committed-offset limit, partial-tail exclusion, corruption detection, interruption at a chunk boundary, no partial state update, and restart of the interrupted file from byte zero.

- [ ] **Step 3: Add failing repair/quarantine/retention tests**

Mirror the macOS failure matrix. Explicitly cover Windows junction/symlink escape, UNC/device/ADS rejection through existing path guards, non-regular files, quarantine-before-replace ordering, rollback after failed installed-target verification, 30-day expiration, newest-three cap, and unrelated-file preservation.

- [ ] **Step 4: Run focused tests and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/integrity-auditor.test.js test/backup/paths.test.js
```

Expected: FAIL because the auditor and paths are absent.

- [ ] **Step 5: Implement scheduling and atomic local audit state**

Use the same digest algorithm and modulo rules as Swift. Initialize `lastCompletedAt` after initial full seed. Persist local audit state through the existing durable writer. Failed, cancelled, and NAS-unavailable runs do not advance it.

- [ ] **Step 6: Implement streaming verification and repair**

Reuse `session-backup-streamer.js`. Validate all canonical paths before opening. Compare exactly through the cursor's committed offset. On mismatch, stream local prefix to repair temp, flush/hash, durably copy the old target into trusted quarantine, replace, reopen/verify, then commit metadata. Restore from quarantine if post-replace verification fails.

- [ ] **Step 7: Integrate auditor priority and retention**

The existing scan coalescer sets an audit interruption flag for any incremental trigger. Run the catch-up scan first; never overlap mutations. Clean only trusted regular files in `repair-quarantine`, older than 30 days or beyond the newest three for that session.

- [ ] **Step 8: Run focused and full Windows verification**

```bash
node --test test/backup/integrity-auditor.test.js test/backup/paths.test.js test/backup/agent.test.js
npm test
node --check src/backup/integrity-auditor.js
node --check src/backup/paths.js
node --check src/backup/backup-agent.js
```

Expected: PASS, including bounded chunk reads, interruption, rollback, and retention boundaries.

- [ ] **Step 9: Commit the Windows auditor**

```bash
git add windows/codex_session_manager_electron/src/backup/integrity-auditor.js windows/codex_session_manager_electron/src/backup/models.js windows/codex_session_manager_electron/src/backup/paths.js windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/test/backup/integrity-auditor.test.js windows/codex_session_manager_electron/test/backup/paths.test.js windows/codex_session_manager_electron/test/backup/agent.test.js
git commit -m "feat: audit and repair Windows NAS backups"
```

---

## Task 8: Make Windows Status Memory-Only and Add Lifecycle Triggers

**Files:**
- Modify: `windows/codex_session_manager_electron/src/backup/nas-runtime.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Modify: `windows/codex_session_manager_electron/src/main.js`
- Modify: `windows/codex_session_manager_electron/test/backup/nas-runtime.test.js`
- Modify: `windows/codex_session_manager_electron/test/backup/agent.test.js`
- Modify: `windows/codex_session_manager_electron/test/security/nas-ui-contract.test.js`

**Interfaces:**

```js
nasRuntime.requestImmediateScan(trigger)
// trigger: 'startup' | 'activation' | 'timer' | 'wake' | 'reconnect' | 'queued'
```

Renderer-facing status continues to use the existing response shape, now backed entirely by cached runtime state.

- [ ] **Step 1: Add failing zero-I/O status tests**

Call the main/runtime status getter 100 times and assert zero reads of `status.json`, zero cursor calls, zero session enumeration, and zero NAS operations. Seed the cache once during initialization and assert later agent status events update it.

- [ ] **Step 2: Add failing lifecycle and coalescing tests**

Assert production polling interval is 30,000 ms; startup and first activation request immediate scans; Electron `powerMonitor` `resume` requests `wake`; validated reconnection requests `reconnect`; and concurrent timer/wake/reconnect triggers cause one active scan plus at most one queued scan.

- [ ] **Step 3: Add failing shutdown tests**

Assert `before-quit` stops future polling and cancels audit at the next chunk boundary. The app may finish the current atomic file operation but cannot hang indefinitely waiting for a full scan/audit.

- [ ] **Step 4: Run focused tests and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/backup/nas-runtime.test.js test/backup/agent.test.js test/security/nas-ui-contract.test.js
```

Expected: FAIL because main still rereads status JSON, polling is 10 seconds, and resume wiring is absent.

- [ ] **Step 5: Make status reads pure cache reads**

Load persisted agent status once during NAS runtime initialization. Update the cache from background agent events. Remove per-renderer-poll `status.json` reads from `readBackupStatus()` and do not compute pending counts in the request path.

- [ ] **Step 6: Expose immediate scan and use the existing coalescer**

Keep the existing `scanPromise`/`scanQueued` single-writer mechanism. Add trigger metadata for logging and audit cancellation, set periodic interval to 30,000 ms, and ensure a no-work queued trigger collapses into one follow-up scan.

- [ ] **Step 7: Wire Electron resume, reconnect, and shutdown**

Import `powerMonitor` only after Electron readiness, register one `resume` listener, and remove it during teardown. Request reconnect scans only after the target guard changes from unavailable to valid. Stop polling/auditing during `before-quit` without weakening the existing exit guard.

- [ ] **Step 8: Run focused and full Windows verification**

```bash
node --test test/backup/nas-runtime.test.js test/backup/agent.test.js test/security/nas-ui-contract.test.js
npm test
node --check src/backup/nas-runtime.js
node --check src/backup/backup-agent.js
node --check src/main.js
```

Expected: PASS. Repeated renderer polling has no filesystem side effects and all triggers remain serialized.

- [ ] **Step 9: Commit the Windows runtime change**

```bash
git add windows/codex_session_manager_electron/src/backup/nas-runtime.js windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/test/backup/nas-runtime.test.js windows/codex_session_manager_electron/test/backup/agent.test.js windows/codex_session_manager_electron/test/security/nas-ui-contract.test.js
git commit -m "perf: make Windows backup runtime idle"
```

---

## Task 9: Document Behavior and Complete Automated Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/操作手册.md`
- Modify: `windows/codex_session_manager_electron/README_WIN10_EXE.md`
- Modify only if required by existing package contents: `windows/codex_session_manager_electron/package.json`

**Interfaces:**
- No new public API.

- [ ] **Step 1: Update user-facing behavior**

Document:

- incremental detection normally within 30 seconds;
- immediate catch-up after startup, activation, wake, and NAS reconnection;
- one per-device staggered complete audit per 24 hours;
- validated local conversation content automatically repairs a mismatched NAS file;
- previous NAS content is retained in app-owned quarantine for 30 days, maximum three copies per session;
- no credentials, snapshots, account state, or live Codex database are uploaded;
- status can report auditing, repair, interruption, NAS unavailable, and last successful audit.

- [ ] **Step 2: Run all automated verification from a clean process state**

```bash
swift test
./scripts/build_app.sh
cd windows/codex_session_manager_electron
npm test
node --check src/backup/cursor-store.js
node --check src/backup/session-backup-streamer.js
node --check src/backup/integrity-auditor.js
node --check src/backup/nas-runtime.js
node --check src/backup/backup-agent.js
node --check src/backup/paths.js
node --check src/backup/durable-write.js
node --check src/main.js
cd ../..
git diff --check
```

Expected: every command succeeds. Do not report macOS completion while the compiler/SDK mismatch remains.

- [ ] **Step 3: Perform static regression searches**

```bash
rg -n "startPolling\(|10000|10_000" Sources windows/codex_session_manager_electron/src
rg -n "pendingSessionCount\(|status\.json|localStatus" Sources/CodexSessionVaultCore/Backup Sources/CodexSessionVault/main.swift windows/codex_session_manager_electron/src
rg -n "readFile\(.*jsonl|Data\(contentsOf:.*jsonl|db\.export\(\)" Sources windows/codex_session_manager_electron/src
```

Expected: no production 10-second NAS polling; no UI status path invokes pending/session/SQLite work; no whole-session read remains in scan/audit/repair; `db.export()` appears only in the Windows cursor store's single batch flush.

- [ ] **Step 4: Package Windows and verify required modules**

Run the repository's existing Windows packaging command:

```bash
cd windows/codex_session_manager_electron
npm run package:win
```

Inspect the unpacked app/asar using the existing package verification method and confirm it contains `cursor-store.js`, `session-backup-streamer.js`, `integrity-auditor.js`, `nas-runtime.js`, and the packaged SQLite/read dependencies already required by the app.

- [ ] **Step 5: Commit documentation and any packaging metadata**

```bash
git add README.md docs/操作手册.md windows/codex_session_manager_electron/README_WIN10_EXE.md windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/package-lock.json
git commit -m "docs: explain resilient low-resource NAS backup"
```

If package metadata did not change, omit those files from `git add`.

---

## Task 10: Run Live Resident and Corruption Validation Before Rollout

**Files:**
- Do not commit generated logs, test NAS data, `.codegraph/`, packages, or resource captures.

**Interfaces:**
- No code interface; this is the release acceptance gate.

- [ ] **Step 1: Prepare isolated pilot data**

Use an isolated test employee/device directory and a source dataset comparable to the current machine: approximately 502 JSONL files, 1.50 GiB total, and one file around 274 MiB. Never corrupt a production employee backup to test repair.

- [ ] **Step 2: Validate normal backup behavior on macOS and Windows 10**

For each platform verify:

- initial catch-up completes and sets audit state;
- a complete appended record reaches NAS within 35 seconds;
- partial trailing JSONL does not advance until newline completion;
- sleep/wake performs immediate catch-up;
- NAS disconnect performs no remote mutation and validated reconnect catches up;
- exit completes without leaving a live polling/audit worker.

- [ ] **Step 3: Validate audit interruption and automatic repair**

Start an audit, append a new complete local record, and confirm the audit yields at a chunk boundary, incremental backup completes, and audit later restarts the interrupted file. Corrupt one isolated NAS JSONL, run the due audit, and confirm:

- old corrupt bytes exist in quarantine before formal replacement;
- formal target equals the committed local prefix after repair;
- manifest/hash/audit/runtime state agree;
- cleanup keeps at most three copies and respects 30 days;
- unrelated NAS files remain unchanged.

- [ ] **Step 4: Measure the 24-hour resident budgets**

Record process-group RSS/working set, CPU, file descriptors/handles, child processes, scan duration, cursor export/process counts, and backup latency after warm-up.

Acceptance targets:

| Platform | Preferred steady memory | Accepted peak | 24-hour growth |
|---|---:|---:|---:|
| macOS | 250-450 MiB | about 600 MiB | no monotonic growth |
| Windows process group | 300-500 MiB | at most 700 MiB | under 50 MiB after warm-up |

Shared targets: idle average CPU below 2%; zero SQLite child processes from status refresh; no-change scan has zero JSONL body reads and zero cursor writes; Windows no-change scan has zero exports and any changed scan has at most one export.

- [ ] **Step 5: Stop or roll back if acceptance fails**

Do not widen rollout if files are missed/duplicated, cursor durability ordering is violated, repair lacks a usable quarantine copy, memory grows monotonically, or the platform exceeds its accepted ceiling without an explained temporary operation. Capture the exact reproduction and return to the responsible task rather than tuning unrelated UI code.

- [ ] **Step 6: Final branch verification**

```bash
git status --short --branch
git log --oneline --decorate -12
git diff --check "$(git merge-base HEAD @{upstream})"..HEAD
```

Expected: only intended commits, clean tracked working tree, no `.codegraph/` or generated artifacts staged, and all release gates recorded before merge/push decisions.

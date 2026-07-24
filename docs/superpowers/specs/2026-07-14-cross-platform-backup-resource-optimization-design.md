# Cross-Platform NAS Backup Resource Optimization Design

## Status

Approved in conversation on 2026-07-14.

This design extends the approved NAS direct incremental backup design. It does not replace the NAS directory, identity, trust-boundary, or recovery decisions in `2026-07-11-nas-direct-incremental-backup-design.md`.

## Context

The macOS and Windows applications share the same NAS incremental-backup behavior but use different runtimes:

- macOS is a native SwiftUI application. Its current NAS status refresh calls `NASBackupRuntime.setupSnapshot()`, which may call `BackupAgent.pendingSessionCount()`. That method discovers every session and launches `/usr/bin/sqlite3` once per cursor lookup. Each subprocess also creates stdout and stderr drain threads. With roughly 500 sessions, a UI status refresh can therefore create hundreds of subprocesses and roughly twice as many temporary reader threads.
- Windows is an Electron application. Its status snapshot is already held in memory and its cursor store uses in-process `sql.js`, so it does not have the same subprocess/thread explosion. However, the current cursor store exports and durably rewrites its complete database after every changed cursor, and the backup agent still performs expensive per-session verification during recurring scans.
- Both platforms currently recalculate complete prefix hashes in paths that should be cheap when a session has not changed. A large active session can also be rehashed in full after a small append.

The current machine has 502 active and archived JSONL files totaling about 1.50 GiB. The largest single session is about 274 MiB. The product is expected to remain running continuously and to serve approximately 130 employees writing to a shared company NAS.

The selected approach is a targeted optimization of the existing polling architecture. It avoids a new filesystem-event subsystem while separating UI status reads from backup work, batching cursor operations, adding an unchanged-file fast path, and performing integrity verification as a low-frequency background task.

## Goals

- Keep every complete Codex JSONL record backed up to the configured NAS device directory.
- Detect new content within approximately 30 seconds during normal operation.
- Trigger an immediate scan after startup, first activation, wake, and NAS reconnection.
- Keep the application suitable for continuous operation without monotonically growing memory or repeated idle CPU spikes.
- Remove filesystem, SQLite, JSONL, and NAS work from UI status reads.
- Avoid reading or hashing complete unchanged session files during normal scans.
- Detect silent backup corruption through one staggered complete integrity audit per day.
- Automatically repair a damaged NAS backup from a validated local source while retaining the previous NAS file for recovery.
- Preserve the current UI, NAS directory hierarchy, recovery flow, JSONL backup files, and existing required manifest fields.

## Non-Goals

- No FSEvents, `fs.watch`, ReadDirectoryChangesW, or other event-watcher architecture.
- No Electron upgrade, native Windows rewrite, or Tauri migration.
- No change to the company NAS endpoint, department/employee selection, device identity, or trust boundary.
- No upload of full local snapshots, account state, credentials, or live Codex databases.
- No new local queue containing conversation bodies.
- No redesign of the session list or status UI.
- No attempt to defend against a privileged local attacker preserving file size and modification time. The daily audit covers accidental silent corruption and normal storage failures.

## Chosen Approach

The application retains periodic polling but splits the work into three layers:

1. An in-memory runtime snapshot used by the UI and exit protection.
2. A single serialized incremental backup agent triggered every 30 seconds and by lifecycle events.
3. A low-priority integrity auditor that verifies complete committed content once per day and yields to incremental work.

Triggers are coalesced. If a trigger arrives while a scan is active, the runtime records one pending rescan rather than starting a second writer. When the current scan finishes, the agent performs at most one immediate follow-up scan.

This approach was selected over:

1. A macOS-only subprocess fix, which would leave shared hashing and Windows write-amplification problems unresolved.
2. Platform filesystem watchers, which would require missed-event recovery, sleep/wake reconciliation, and different macOS and Windows implementations before they could be trusted as a backup boundary.

## Runtime And Status Architecture

### In-memory status snapshot

The runtime owns a small immutable status value containing at least:

- configuration and connection state;
- current operation and phase;
- total, changed, pending, and completed file counts;
- last successful incremental backup time;
- last complete audit time and result;
- last automatic repair time and count;
- last actionable error.

Reading this snapshot must be an O(1) in-memory operation. It must not enumerate directories, query a cursor store, read JSONL, inspect NAS files, or start a scan.

On macOS, `NASBackupRuntime.setupSnapshot()` stops calling `pendingSessionCount()` and stops rereading local status files on every UI refresh. The runtime loads persisted status during initialization and thereafter updates the cached snapshot from agent events and background error handling. `VaultModel` may keep its current display refresh loop because the refreshed value is now memory-only. No `sqlite3` process may be launched by a status refresh.

On Windows, the existing in-memory `nasRuntime.snapshot()` behavior remains the model. The main process combines it with the most recently cached agent status. Renderer polling reads that cached combined value; it does not reread `status.json` or invoke a session scan. Persisted status is loaded once during agent initialization and updated after background operations.

### Serialized background work

Only the backup agent may mutate backup files, manifest state, cursor state, and repair metadata. It accepts the following triggers:

- application startup;
- successful first-time NAS activation;
- a 30-second periodic timer;
- system wake;
- successful NAS reconnection;
- a queued rescan after an active scan.

There is one writer per device identity. Periodic scans, catch-up work, and integrity auditing never mutate the same device backup concurrently.

## Normal Incremental Scan

Each scan follows this sequence:

1. Revalidate the configured NAS root and device identity once.
2. Discover trusted regular `.jsonl` files below the active and archived source roots.
3. Load all local cursor rows in one bulk operation and index them by canonical source path.
4. Read local size and modification time for each discovered source.
5. Classify unchanged, new, appended, rewritten, truncated, missing-target, and invalid sources.
6. Process only sources that require work.
7. Durably save changed manifest data.
8. Commit changed cursor rows in one batch transaction/export.
9. Publish the final in-memory runtime snapshot.

### Unchanged fast path

A source is skipped when its trusted path, size, modification time, committed offset, and required backup metadata agree with the current cursor and manifest.

The skip path performs no JSONL body read, source hash, target-file stat, per-file NAS request, manifest write, or cursor write. A normal scan validates the NAS root once, but it does not contact every unchanged NAS target.

### Append path

For a growing session, the agent reads only bytes after the committed cursor offset. It commits only complete newline-terminated JSONL records and retains an incomplete trailing line in local operational state for the next scan.

The new range is written and flushed before metadata advances. The agent verifies the newly committed source and target ranges without rereading the previously committed prefix.

The manifest's optional complete `contentHash` represents a full audit result. After an append that was verified only by range, the complete hash is cleared or marked unavailable using existing optional semantics. The next daily audit restores a current complete hash. No new required manifest field or backup-format version is introduced.

### Rewrite, truncation, and interrupted writes

A source is rebuilt when its size is below the committed offset, when its size is unchanged but its modification time changed, when the target is absent or inconsistent, or when interrupted-write reconciliation cannot prove that the NAS suffix matches the source.

Rebuilds stream the trusted complete JSONL prefix into a same-directory temporary target while computing its complete hash. The temporary target is flushed, verified, and atomically installed. Only the affected session is rebuilt.

A modification that deliberately preserves both size and modification time is detected by the daily complete audit rather than by the 30-second fast path.

## Cursor Batching

### macOS

`BackupCursorStore` gains bulk behavior equivalent to:

- load all cursor rows through one `sqlite3 -json` invocation;
- convert the rows into an in-memory dictionary keyed by source path;
- upsert all changed rows in one `BEGIN IMMEDIATE` transaction through one subprocess invocation.

The agent no longer calls `cursor(sourcePath:)` inside the per-file loop and no longer rereads a cursor before upserting it. A no-change scan performs no cursor write transaction.

The same bulk cursor map is used for pending classification. UI status code never invokes pending classification.

### Windows

The `sql.js` cursor database remains local and app-owned. The store exposes behavior equivalent to:

- materialize all rows as a `Map` at scan start;
- apply changed rows inside one in-memory transaction;
- call `db.export()` and durable replacement at most once per changed scan;
- perform no export for a no-change scan.

The current NAS cursor database for about 500 sessions is approximately 224 KiB, so the cursor map itself is not a material memory cost. The optimization primarily removes repeated allocation, durable-write, `fsync`, rename, and garbage-collection pressure during seeding and multi-session updates.

## Daily Complete Integrity Audit

### Scheduling

Each device derives a stable daily audit time from its device UUID so approximately 130 devices spread their work across the day. The runtime persists the last successful audit time locally.

- A complete audit runs at most once in any 24-hour period.
- Startup does not repeat an audit completed within the previous 24 hours.
- If an audit is overdue, initial incremental catch-up finishes first.
- If the computer slept through its scheduled time, wake performs incremental catch-up before scheduling the overdue audit. A stable device-derived delay within the next 30 minutes prevents many office computers from auditing simultaneously after a common wake time.
- An unavailable NAS pauses the audit without marking it successful.

### Verification

The auditor processes one session at a time using a bounded streaming buffer. It compares the trusted local source prefix through the committed complete-line offset with the corresponding NAS backup. A partial local trailing line is excluded.

The auditor checks for pending incremental work at every streaming chunk boundary. Incremental work has priority. When a trigger arrives, the auditor cancels the current file verification at the next chunk boundary, discards that incomplete hash result, runs the incremental scan, and later restarts the interrupted file from byte zero. A cancelled partial audit never updates audit or manifest state.

The audit does not load a complete session into memory. With the current roughly 1.50 GiB source set, a full audit reads up to roughly 3 GiB across local and NAS storage but keeps memory bounded.

## Automatic Repair And Quarantine

When a full audit finds a mismatch, the local committed JSONL prefix is authoritative only if the source is a trusted regular file and its committed portion passes the existing structural and path checks.

Repair follows this order:

1. Revalidate the local source, NAS target, device root, and path boundaries.
2. Stream the local committed prefix into a same-directory temporary repair target while hashing it.
3. Flush and verify the temporary target.
4. Durably copy the existing NAS target into the application-owned `repair-quarantine/` tree.
5. Atomically replace the formal target with the verified repair target.
6. Reopen and verify the installed target.
7. Update manifest, cursor, audit, repair, and runtime status.

Before the atomic replacement, any failure leaves the formal NAS target unchanged. If the local source is missing, unsafe, unreadable, or structurally invalid, the application must not overwrite the NAS target.

Quarantine retention is:

- 30 days;
- at most the three newest repair copies per session;
- cleanup limited to trusted regular files below the application-created `repair-quarantine/` root;
- no cleanup of formal backups, snapshots, other devices, or unrelated NAS content.

## Commit Ordering And Failure Handling

The durability invariant is:

```text
NAS conversation bytes
→ successful flush
→ manifest commit
→ cursor batch commit
```

The cursor never advances before NAS bytes and manifest state are durable. A cursor transaction/export failure leaves old cursors in place so the next scan safely reconciles already-written NAS bytes. A single-session failure is recorded while independent sessions continue where safe.

Additional behavior:

- NAS disconnection stops remote mutation, preserves local non-content pending state, and triggers immediate catch-up after validated reconnection.
- Audit cancellation does not alter formal backups.
- Automatic repair failure preserves the formal target and any successfully written quarantine copy.
- Shutdown cancels auditing immediately. Incremental work completes only its current atomic file step and must not block application exit indefinitely.
- Logs contain paths, counts, durations, phases, and errors, never conversation content.

## Resource Budgets

These are acceptance targets, not guarantees before live measurement.

### macOS

- Preferred steady footprint: 250-450 MiB.
- Expected upper bound during normal and audit work: about 600 MiB.
- Zero `sqlite3` launches from status refresh.
- At most one bulk cursor read subprocess and one bulk cursor write subprocess per changed scan.
- No monotonic memory growth during a 24-hour resident run.

### Windows

- Preferred complete Electron process-group working set: 300-500 MiB.
- Accepted upper bound: 700 MiB.
- No-change scan: zero `db.export()` calls.
- Changed scan: at most one `db.export()` call.
- After warm-up, less than approximately 50 MiB growth across a 24-hour resident run.

### Shared

- Idle average CPU below 2% on representative company hardware.
- A complete JSONL record normally reaches NAS within 35 seconds.
- A no-change scan performs no JSONL body read and no cursor database write.
- Audit memory remains bounded independently of session size.
- Incremental work remains responsive while auditing.

## Testing And Verification

Implementation follows test-driven development. Tests are added before production changes.

### macOS automated tests

- Status snapshot reads invoke no pending scan, cursor query, directory enumeration, JSONL read, or NAS operation.
- A 500-session pending or backup scan performs one bulk cursor read rather than one query per session.
- Bulk upserts use one transaction and roll back completely on failure.
- No-change scans perform no body read, hash, manifest write, or cursor write.
- Append scans read and verify only the new range.
- Same-size rewrites with changed modification time, truncation, partial lines, interrupted appends, and target mismatches retain current correctness.
- Timer, startup, activation, wake, reconnection, and coalesced-rescan behavior match the design.

### Windows automated tests

- Cursor rows materialize into one map.
- Multiple changed cursors produce one transaction and one export.
- No-change scans produce no export.
- Transaction and durable-write failures leave the previous cursor database usable.
- Shared no-change, append, rewrite, truncation, partial-line, interrupted-write, and trigger-coalescing behavior matches macOS.

### Audit and repair tests

- A device receives a stable staggered daily audit time and cannot audit twice within 24 hours.
- Only committed complete-line bytes participate in comparison.
- Streaming verification is bounded and does not read complete files into memory.
- A mismatch creates a verified quarantine copy before atomic repair.
- Missing or unsafe local sources never overwrite NAS.
- Failures at each repair step preserve a usable formal target.
- Retention removes only eligible application-owned quarantine files older than 30 days and keeps at most three per session.

### Regression and packaging

- `swift test`
- `./scripts/build_app.sh`
- `npm test`
- `node --check` for modified Windows files
- Windows packaging and packaged-module verification
- `git diff --check`

The current Windows baseline is 116 passing tests. The current machine's Swift Command Line Tools compiler and SDK are mismatched, so the macOS test environment must be repaired before macOS implementation can be accepted. A previous passing baseline is not a substitute for a current run.

### Live resident validation

Use a dataset comparable to the current 502 files and 1.50 GiB total:

- run macOS and Windows for 24 hours while recording process-group memory, CPU, file descriptors/handles, child processes, scan duration, export count, and backup latency;
- append complete records during idle and during a complete audit;
- sleep/wake the machine and disconnect/reconnect NAS;
- verify no duplicate data, cursor advance before durability, missed catch-up, or monotonic memory growth;
- verify automatic repair against a deliberately corrupted test backup and confirm quarantine retention without touching unrelated NAS content.

## Rollout

The implementation remains focused on backup runtime, cursor store, integrity-audit, and their tests. It does not modify unrelated restore, snapshot, security, or UI code.

Rollout order is:

1. Unit and integration verification on both platform implementations.
2. macOS live resident test on the current roughly 500-session dataset.
3. Windows 10 live resident and packaging test.
4. One or a few internal pilot devices using isolated test employee/device directories.
5. Wider company deployment only after resource budgets and repair behavior are observed on the real NAS.

## Assumptions

- The application normally remains running, but may sleep, wake, restart, or temporarily lose NAS connectivity.
- A maximum normal backup delay of approximately 30 seconds is accepted.
- Employees use the existing OS-level SMB connection; the application does not manage credentials.
- The company threat model prioritizes accidental loss and storage failure rather than a privileged local attacker manipulating timestamps.
- A validated local committed JSONL prefix is the repair source of truth. If it cannot be trusted, the NAS target is preserved and the application reports an error instead of guessing.
- The approved quarantine policy is 30 days and at most three copies per session.

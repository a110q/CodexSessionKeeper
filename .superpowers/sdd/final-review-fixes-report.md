# Final Branch Review Fixes Report

Base: `a3f6ac0`

## RED evidence

- Swift focused regression run reproduced four failures while the post-callback interruption control passed:
  - a periodic scan fired before the scheduled audit caused `.interrupted` instead of `.completed`;
  - active-to-archived migration left a stale cursor and the due audit threw `.unsafeCursor`;
  - a legacy duplicate cursor made the auditor throw `.unsafeCursor`;
  - a deleted NAS target was rejected as an unsafe path instead of repaired.
- Windows focused regression run failed all three original cases:
  - active-to-archived migration retained two cursor rows;
  - the legacy duplicate cursor was rejected as unsafe metadata;
  - a deleted target was rejected with `INVALID_SNAPSHOT_PATH`.
- Final self-review added a stricter same-destination boundary. Before the production correction:
  - Swift active-to-archived migration changed the formal NAS `backupPath`, and a cursor for another destination was silently removed;
  - Windows likewise silently removed the different-destination cursor.

## Implementation

- The macOS audit timer now captures only its timer generation while waiting and captures the current interruption epoch when the valid callback actually begins. Later incremental work still interrupts an active audit.
- Swift and Windows cursor stores now delete stale source rows and upsert the replacement cursor in one transaction; Windows performs one final export for that changed batch and none for a no-op batch.
- Migration is accepted only when session ID and backup destination both match. Swift now preserves a trusted existing NAS destination when a session moves between active and archived source trees, while invalid recorded destinations still fall back to the safe mirrored path.
- Both auditors remove only legacy rows proven to belong to the same session and same current backup destination. Different-destination or otherwise unsafe metadata remains fail-closed.
- Both auditors accept only a missing target leaf below a validated canonical parent as repairable. They rebuild exactly the committed local prefix into a synced same-directory temporary, publish it without replacing a newly-created target, sync the parent, verify installed bytes and hash, and then commit metadata. No quarantine is created when no old target exists; the existing corruption repair journal/quarantine flow is unchanged.
- Documentation now states only the status fields the current UI actually renders and identifies `status.json` as the audit-result source.

## Verification

- Focused final Swift regressions: 4 passed, 0 failed.
- Focused final Windows regressions: 4 passed, 0 failed.
- `swift test`: 205 passed, 0 failed.
- `./scripts/build_app.sh`: passed; produced `dist/codex_会话管理.app`.
- Windows `npm test`: 236 passed, 0 failed.
- `node --check` passed for:
  - `src/backup/backup-agent.js`
  - `src/backup/cursor-store.js`
  - `src/backup/durable-write.js`
  - `src/backup/integrity-auditor.js`
- `git diff --check`: passed.
- Static coverage check confirms the unchanged-scan tests still reject target/body/hash/manifest/cursor/export work, the Windows no-change scan still requires zero exports, and a changed or migrated batch still requires exactly one export.

## Self-review

- Correctness: timer baselines are taken at callback start; cursor migration is atomic and same-destination only; missing-target repair commits only verified committed bytes.
- Security: source, destination, canonical parent, session identity, relative backup path, and existing-file type checks remain fail-closed. A target that appears during repair is not replaced.
- Durability: temporary data is synchronized before publication, the parent is synchronized after publication/removal, and the existing WAL-backed replacement path is untouched.
- Performance: steady-state scans retain the target-I/O fast path; Windows retains zero-export no-op scans and at-most-one-export changed scans.
- Scope: no generated package, `.codegraph/`, Task 10 data, IPC, schema, or unrelated feature was changed.

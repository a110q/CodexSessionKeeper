# Final Review Fix Wave 2 Report

Base commit: `51e28cb`

## Scope

- Prevent unchanged 30-second timer ticks from repeatedly interrupting a long-running integrity audit on Swift/macOS and Electron/Windows.
- Remove the Windows hard-link-unsupported `lstat` plus ordinary `rename` no-replace fallback and fail closed when no atomic primitive is available.
- Preserve prompt interruption for non-timer triggers, single-writer behavior, at most one queued follow-up, bounded audit interruption, and existing WAL/recovery cleanup contracts.

## TDD red evidence

The new tests were added before production changes.

Swift focused tests initially failed with five expectations:

- both unchanged timer preflights performed zero cursor reads instead of one read each;
- the running audit returned `.interrupted` instead of `.completed`;
- the complete-append timer preflight performed zero cursor reads and did not demonstrate the required metadata gate.

Windows focused tests initially failed because:

- the first unchanged timer request remained blocked behind the audit instead of completing its preflight;
- the complete-append preflight performed zero cursor reads;
- `writeFileDurably` did not reject an unsupported hard-link primitive;
- the injected rename fallback was invoked instead of failing closed.

The injected race control that created the destination during the unsupported link attempt already proved the destination bytes could be observed independently of the failing expectations.

## Implementation

### Audit-preserving timer preflight

- Swift detects a running audit before advancing the interruption epoch. A timer tick reads the cursor table once through SQLite CLI `-readonly`, discovers trusted local session files, and compares only source path, size, modification time, committed offset, pending partial-line state, and prior cursor error state.
- Windows uses the equivalent cursor Map and trusted local source metadata preflight. The cursor store is closed without flushing, so the preflight performs no `db.export()`.
- An unchanged preflight returns immediately without epoch advancement, body work, NAS target stats, cursor writes, or queued scans.
- New or changed source metadata falls through to the existing serialized scan path, which interrupts the audit at a chunk boundary and retains the current plus at-most-one-follow-up rule.
- Concurrent Windows timer preflights are coalesced and tracked by quiescence/stop handling.
- Preflight errors fail safe by requesting the ordinary scan instead of silently skipping possible backup work.
- The superseded legacy tests were narrowed from a no-change `timer` trigger to explicit `activation`, preserving verification that explicit lifecycle work still interrupts promptly and reschedules the audit.

### Atomic no-replace publication

- Successful hard-link publication and temporary unlink behavior are unchanged.
- `ENOTSUP`, `EOPNOTSUPP`, `EPERM`, and `EINVAL` now throw `ATOMIC_NO_REPLACE_UNSUPPORTED` with the original cause.
- The racy destination check plus ordinary rename fallback was removed completely.
- Direct publication leaves the synced temporary file available to its caller/recovery contract; `writeFileDurably` continues to clean its owned temporary file on failure.
- Tests cover the clear error code, wrapper cleanup, direct temporary preservation, no rename invocation, and a target appearing during the failing link attempt remaining byte-for-byte unchanged.

## Verification

All commands ran in the wave-2 worktree.

- `swift test --filter 'BackupAgentTests|BackupCursorStoreTests|BackupIntegrityAuditorTests'`
  - PASS: 74 tests.
- `node --test test/backup/agent.test.js test/backup/cursor-store.test.js test/backup/durable-write.test.js test/backup/integrity-auditor.test.js`
  - PASS: 141 tests.
- `swift test`
  - PASS: 207 tests in 16 suites.
- `./scripts/build_app.sh`
  - PASS: production build completed; app assembled at `dist/codex_会话管理.app`.
- `npm test`
  - PASS: 240 tests.
- `node --check src/backup/backup-agent.js`
  - PASS.
- `node --check src/backup/durable-write.js`
  - PASS.
- `node --test test/backup/durable-write.test.js`
  - PASS: 7 tests after strengthening the final error-code assertions.
- `git diff --check`
  - PASS.

## Self-review

- Correctness: no-change timer ticks cannot advance the audit epoch; actual changed sources still use the existing serialized writer and restart path.
- Safety: the preflight is local metadata/cursor-only and fail-safe; it does not touch source bodies or NAS targets on the unchanged path.
- Durability: no ordinary rename remains in the no-replace publication function; existing-target and unsupported-filesystem cases fail without overwriting live bytes.
- Concurrency: Windows preflight promises are coalesced, cleared on resolve/reject without creating an unhandled rejection, and included in bounded quiescence waiting. Swift retains its condition-locked worker queue and scan cap.
- Scope: no UI, package, generated data, database schema, backup format, or unrelated source files changed.
- Findings after review: no remaining blocker, critical, or important issue found in the scoped diff.

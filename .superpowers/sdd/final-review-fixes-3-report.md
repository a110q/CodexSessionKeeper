# Final Review Fix Wave 3 Report

Base commit: `376084f`

## Scope

- Ensure a successful atomic hard-link publication remains committed even if removal of the synced temporary file later fails.
- Allow missing-target integrity recovery to finish manifest, cursor/index, audit-state, and runtime-status commits while deferring owned temporary cleanup.
- Remove the two 500 ms wall-clock races from the no-change timer/audit test.

## TDD red evidence

Tests were added before production changes for `EPERM`, `EINVAL`, and unexpected `EIO` unlink failures.

Focused RED command:

`node --test --test-name-pattern='successful publication remains committed|published missing-target repair completes metadata' test/backup/durable-write.test.js test/backup/integrity-auditor.test.js`

Result: 0 passed, 6 failed.

- All three durable publication cases observed that the injected unlink path was not used and the expected surviving temporary file was already gone.
- All three missing-target repair cases could not route the injected cleanup failure through the production publisher, so the expected owned orphan was absent and the caller contract could not be verified.
- This exposed the missing error-boundary/injection seam while the code inspection confirmed the root cause: `link` and `unlink` shared one catch, so a real unlink `EPERM` or `EINVAL` was misclassified as `ATOMIC_NO_REPLACE_UNSUPPORTED` after the destination had already been published.

The rewritten deterministic timer test passed independently during RED, proving its event barrier preserved the existing production assertion without a 500 ms deadline.

## Implementation

### Committed publication boundary

- `publishSyncedTemporaryFileIfAbsent` now catches and classifies only errors from the atomic `link` call.
- `EEXIST` and all other non-unsupported link failures retain their original error identity.
- Unsupported link errors still fail closed as `ATOMIC_NO_REPLACE_UNSUPPORTED`; no ordinary rename fallback exists.
- Once link returns successfully, destination publication is final. Temporary unlink is attempted separately and any synchronous or asynchronous cleanup error is treated as deferred cleanup, not publication failure.
- Normal successful unlink behavior and existing write/fsync ordering are unchanged.

### Recovery completion and deferred orphan cleanup

- `BackupIntegrityAuditor` accepts an internal `publishIfAbsent` dependency, defaulting to the production durable publisher.
- Missing-target repair marks installation complete after the publisher returns, performs its existing parent-directory sync and verification, then commits manifest, cursor/index, audit state, and runtime status.
- Parameterized integration tests inject unlink `EPERM`, `EINVAL`, and `EIO`, verify the destination bytes and metadata/index commits, then rerun the audit. The not-due reconciliation path removes the owned repair temp while leaving the formal target intact.

### Deterministic timer test

- Cursor-read spies now expose an event promise resolved by the requested read count.
- The test asserts the interruption signal is unchanged before and after each metadata preflight event, then awaits each tick directly.
- Both 500 ms `Promise.race` deadlines were removed, so slow Windows CI cannot produce a false failure.

## Verification

- Focused unlink GREEN:
  - PASS: 6/6.
- Deterministic no-change timer test:
  - PASS: 1/1.
- Windows backup focused suite:
  - `node --test test/backup/agent.test.js test/backup/cursor-store.test.js test/backup/durable-write.test.js test/backup/integrity-auditor.test.js`
  - PASS: 147/147.
- Full Electron suite:
  - `npm test`
  - PASS: 246/246.
- Syntax:
  - `node --check` passed for `durable-write.js`, `integrity-auditor.js`, and the three modified test files.
- Static safety check:
  - PASS: the body of `publishSyncedTemporaryFileIfAbsent` contains no ordinary rename fallback.
- `git diff --check`:
  - PASS.

## Self-review

- Publication state is now monotonic: cleanup failure cannot convert a committed destination into a reported non-publication.
- Link-unsupported and EEXIST race behavior remain fail-closed and unchanged.
- The auditor still removes a newly installed target if verification or later pre-metadata work fails; an unlink cleanup failure alone no longer enters that rollback path.
- Deferred cleanup is limited to the app-owned repair temporary naming/roots already accepted by integrity orphan cleanup.
- The production injection point defaults to the original publisher and changes no public API, schema, file format, IPC, or UI behavior.
- No generated output, package artifact, or unrelated file is included.
- No remaining blocker, critical, or important issue was found in the scoped diff.

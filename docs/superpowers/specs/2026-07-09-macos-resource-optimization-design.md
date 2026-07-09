# macOS Resource Optimization Design

## Context

The current macOS `codex_会话管理` app can consume too much CPU while sitting open. Live inspection of PID `52881` showed CPU spikes from single digits to 60%+, a physical footprint around 320 MB, and a high count of pipe file descriptors after a long run. A 5-second `sample` pointed to the main thread spending time in SwiftUI/AppKit layout, AttributeGraph, and Observation invalidation rather than in JSONL backup I/O.

The goal is to reduce resource usage without changing the visual direction of the app or weakening local incremental backup behavior.

## Goals

- Keep the current macOS UI look and layout broadly intact.
- Reduce idle CPU to a stable low baseline, targeting 2-5% after the app is idle.
- Avoid sustained 30-60% CPU after switching back to the app.
- Stop pipe file descriptors from growing over long-running sessions.
- Preserve automatic local incremental backup, restore, and SQLite repair behavior.
- Keep the change scoped to macOS unless tests expose shared-code impact.

## Non-Goals

- No visual redesign.
- No Windows UI change in this pass.
- No NAS sync, enterprise monitoring, signing, or notarization change.
- No rewrite of the backup storage format.
- No replacement of SwiftUI with AppKit.

## Design

### 1. Backup Status Refresh Gating

The bottom status bar currently refreshes local backup status every 3 seconds and updates several `@Published` properties even when the display value has not materially changed. In SwiftUI this can invalidate a wide view tree and trigger layout work across the main window.

Change the refresh behavior as follows:

- Increase the default backup status refresh interval from 3 seconds to 15 seconds.
- Keep an immediate refresh on app startup and after explicit backup-related actions.
- Introduce an equality gate before publishing status changes:
  - Compare the decoded `BackupStatus` and derived display strings with the current values.
  - If there is no visible change, do not assign `localBackupStatus`, `localBackupStatusLabel`, or `localBackupStatusDetail`.
- Do not refresh backup status while the app is in a busy operation that already reports progress unless the busy operation explicitly asks for a refresh.

Expected effect: fewer global Observation invalidations while the app is open.

### 2. Session List Computation And Rendering Lightening

The sessions pane reads `model.filteredSessions` from several SwiftUI body locations. Because this is a computed property over the full session list, status-only changes can cause repeated filtering and row reconstruction.

Change the list behavior as follows:

- Add a cached visible session array in `VaultModel`, for example `visibleSessions`.
- Recompute it only when the inputs change:
  - `sessions`
  - debounced `sessionSearch`
  - `showArchivedSessions`
- Update code paths that currently read `filteredSessions` from SwiftUI bodies to read the cached array.
- Keep session row dimensions stable:
  - Preserve current colors, title hierarchy, badges, and selected-row behavior.
  - Avoid new animations or decorative effects.
  - Keep line limits and fixed row structure so long titles do not resize the whole row unpredictably.
- Do not remove the current visual identity unless a specific row style is proven to be the CPU bottleneck after the refresh fixes.

Expected effect: less repeated computation and less row churn on unrelated status updates.

### 3. Pipe And Process Resource Hygiene

Long-running inspection showed an unusually high pipe file descriptor count. The app uses `Process` and `Pipe` in several paths for SQLite and worker calls. Those calls should release read/write handles deterministically.

Change process helpers as follows:

- Audit all `Process + Pipe` code paths in:
  - `Sources/CodexSessionVault/main.swift`
  - `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
  - `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift`
- Add `defer` cleanup for all pipe file handles:
  - close read handles after `readDataToEndOfFile`
  - close write handles after writing input
  - close handles on early errors
- Prefer temporary output files for potentially large command output paths that already use that pattern.
- Keep command behavior and errors unchanged.

Expected effect: pipe FD count should stay bounded across hours of runtime.

## Data Flow

1. Backup agent writes `status.json` as before.
2. The macOS app periodically reads `status.json`.
3. The model derives display label/detail strings.
4. The model publishes changes only when the visible status state differs.
5. Session list UI reads cached visible sessions instead of repeatedly filtering in view bodies.
6. SQLite and worker helpers close all pipe handles after each process call.

## Error Handling

- If `status.json` is missing, keep the current "starting/waiting" display behavior.
- If decoding `status.json` fails, keep the current error display behavior.
- If process execution fails, preserve current thrown error messages.
- If a pipe close fails, ignore the close error after process output has already been captured, matching existing best-effort cleanup style.

## Testing

Automated checks:

- `swift test`
- `./scripts/build_app.sh`

Resource checks:

- Start the app, leave it idle for 5-10 minutes, then check CPU with `top` or Activity Monitor.
- Switch away and back several times, confirming CPU spikes are short-lived.
- Run `sample <pid> 5` and confirm the app is not continuously dominated by SwiftUI layout during idle.
- Run `lsof -a -p <pid>` before and after several minutes; pipe FD count should not grow linearly.
- Confirm local incremental backup status remains `running` and `lastBackupAt` updates after new Codex messages.

## Rollout

This is a Mac resource optimization pass. If the checks pass, it can be included in the next Mac test build. Windows packages can remain on the current code unless shared core tests reveal an impact.

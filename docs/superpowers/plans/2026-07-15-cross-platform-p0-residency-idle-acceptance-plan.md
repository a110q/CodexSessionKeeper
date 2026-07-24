# Cross-Platform P0 Residency, Idle NAS, and Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the configured macOS and Windows applications launch at login and remain available for backup, eliminate high-frequency idle NAS mutations, and provide repeatable real-machine release acceptance.

**Architecture:** Keep the current in-process backup agents. Add small platform lifecycle adapters, gate every 30-second timer tick through a local-only source snapshot, split trusted NAS resolution from destructive write probing, and add isolated acceptance runners that call the production backup/recovery code without touching a real employee device directory.

**Tech Stack:** Swift 6/AppKit/ServiceManagement, Electron 43/Node.js, electron-builder NSIS, shell/PowerShell acceptance tooling.

## Global Constraints

- Preserve the current NAS directory layout, manifest v2, cursor database, verification sidecar, recovery flow, and 30-second backup detection target.
- macOS minimum remains 14.0; Windows remains Windows 10 x64.
- Successful first NAS configuration automatically enables launch at login.
- Windows close hides to tray; only explicit Quit terminates the process.
- Login launches are silent; manual launches show or focus the main window.
- Idle health checks are read-only every 5 minutes; remote heartbeat writes are at most once every 30 minutes.
- Full NAS write probes run only during configuration, process startup, reconnect/retry, never every timer tick.
- Keep the current daily staggered integrity audit.
- Produce unsigned internal-test installers now; signing/notarization remains a release prerequisite.
- Do not commit, push, merge, or publish generated artifacts without explicit user approval.

---

### Task 1: Native Launch-at-Login and Background Window Lifecycle

**Files:**
- Create: `Sources/CodexSessionVaultCore/Lifecycle/MacLaunchAtLoginController.swift`
- Create: `windows/codex_session_manager_electron/src/lifecycle.js`
- Modify: `Sources/CodexSessionVault/main.swift`
- Modify: `windows/codex_session_manager_electron/src/main.js`
- Modify: `windows/codex_session_manager_electron/src/preload.js`
- Modify: `windows/codex_session_manager_electron/src/index.html`
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
- Test: `Tests/CodexSessionVaultCoreTests/MacLaunchAtLoginControllerTests.swift`
- Test: `Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift`
- Test: `windows/codex_session_manager_electron/test/lifecycle.test.js`
- Test: `windows/codex_session_manager_electron/test/security.test.js`

**Interfaces:**
- Swift produces `LaunchAtLoginSnapshot { enabled, requiresApproval, message }` and `MacLaunchAtLoginController.currentState()`, `ensureEnabled()`, `openSystemSettings()`.
- Electron produces `createLoginItemController({ app, execPath, backgroundArgument })` and `createBackgroundWindowController({ app, createTray, showWindow, hideWindow, confirmQuit })`.
- `nasSetupState()` adds `launchAtLogin` without changing existing fields.
- New protected IPC channels: `retry-launch-at-login`, `open-login-item-settings`.

- [ ] **Step 1: Write failing Swift controller and app-wiring tests**

  Cover enabled, not registered, requires approval, registration success/failure, automatic registration after NAS activation, startup recheck for a saved configuration, and a visible retry action. Inject status/register/open-settings closures so tests exercise controller decisions rather than `SMAppService` itself.

- [ ] **Step 2: Run the focused Swift tests and verify RED**

  Run: `swift test --filter MacLaunchAtLoginControllerTests` and `swift test --filter MacNASWiringContractTests`

  Expected: failure because the controller and wiring do not exist.

- [ ] **Step 3: Implement the minimal macOS lifecycle adapter**

  Map `SMAppService.mainApp.status` to the frozen snapshot. `ensureEnabled()` registers only when not enabled, handles already-registered as success, reports approval-required distinctly, and never rolls back a valid NAS configuration. At app startup and after successful NAS activation, refresh the snapshot and attempt registration once. Detect a login-item launch from the open-application Apple event and hide the initial window; regular reopen/manual activation remains visible. `Command+Q` continues to use the existing busy-backup confirmation.

- [ ] **Step 4: Run focused Swift tests and verify GREEN**

  Run the two focused suites and require zero failures.

- [ ] **Step 5: Write failing Electron lifecycle tests**

  Cover login registration with stable `process.execPath` and `--background`, registration verification, failed registration status, background second-instance behavior, manual second-instance window focus, close-to-tray with zero runtime stop calls, tray Quit using the existing busy confirmation, and cleanup on real quit.

- [ ] **Step 6: Run focused Node tests and verify RED**

  Run: `node --test test/lifecycle.test.js test/security.test.js`

  Expected: failure because lifecycle module/channels do not exist.

- [ ] **Step 7: Implement the Electron lifecycle module and UI warning**

  Store strong references to `Tray` and its menu. Close hides the current window and shows one informational notification per installation; tray Open recreates/focuses the trusted BrowserWindow; tray Quit sets an explicit quit intent and then uses the busy-state prompt. `before-quit` is the only normal path that tears down listeners and stops the NAS runtime. Add renderer warning actions without exposing paths or untrusted shell targets.

- [ ] **Step 8: Run focused and full lifecycle/security tests**

  Require all new tests plus existing IPC contract tests to pass.

---

### Task 2: Local-Only Timer Preflight and Throttled NAS Maintenance

**Files:**
- Modify: `Sources/CodexSessionVaultCore/NAS/NASConfigurationService.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/NASBackupRuntime.swift`
- Modify: `windows/codex_session_manager_electron/src/backup/nas-service.js`
- Modify: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Modify: `windows/codex_session_manager_electron/src/backup/nas-runtime.js`
- Test: `Tests/CodexSessionVaultCoreTests/NASConfigurationServiceTests.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`
- Test: `windows/codex_session_manager_electron/test/backup/nas-service.test.js`
- Test: `windows/codex_session_manager_electron/test/backup/agent.test.js`

**Interfaces:**
- Swift splits `resolveActiveTarget()` into canonical read-only resolution and `verifyActiveTargetWritable()` for explicit lifecycle probes.
- Electron `nasService.resolve(configuration)` becomes read-only and adds `verifyResolvedTargetWritable(target)`.
- Backup agents maintain an in-memory settled source snapshot keyed by canonical path with byte count and modification time.
- Idle maintenance constants are fixed: local scan 30 seconds, read-only health 5 minutes, remote heartbeat 30 minutes.

- [ ] **Step 1: Write failing NAS resolution tests**

  Assert activation and explicit startup/retry perform the full create/write/sync/read/rename/delete probe, while ordinary `resolve` performs only canonical directory/marker reads. Confirm marker mismatch and symlink/junction checks remain fail-closed.

- [ ] **Step 2: Run the focused NAS service tests and verify RED**

  Run Swift `NASConfigurationServiceTests` and Node `nas-service.test.js`; expect probe-count assertions to fail.

- [ ] **Step 3: Split read-only resolution from write probing**

  Keep activation behavior unchanged. Runtime initialize/retry calls read-only resolution plus explicit writable verification before starting an agent. Per-scan validators use only read-only resolution; actual changed uploads still perform durable write/readback verification.

- [ ] **Step 4: Run NAS resolution tests and verify GREEN**

  Require all existing path, marker, and activation tests to remain green.

- [ ] **Step 5: Write failing idle timer tests**

  After one successful scan, fire repeated timer ticks and assert: local source enumeration/stat occurs; cursor database is not reopened; NAS target validator, manifest, verification, remote status, and probe receive zero calls before their deadlines. Advance the injected clock to 5 minutes and require one read-only health check; advance to 30 minutes and require exactly one remote heartbeat. A local append must bypass throttling and enter the normal scan immediately. A failed health check must publish a local error and a later successful check must recover without duplicate data.

- [ ] **Step 6: Run focused BackupAgent tests and verify RED**

  Run Swift `BackupAgentTests` and Node `agent.test.js`; expect no-change timer assertions to fail because timers currently perform full scans.

- [ ] **Step 7: Implement settled source snapshots and idle maintenance**

  Build the local snapshot from canonical active/archived JSONL winners. Publish it only after a non-interrupted scan completes its remote status, pending-state, and audit-seed commits successfully. Every timer tick compares current local metadata with that snapshot before queuing work. If unchanged, run due maintenance through the same serialized worker: health validation is read-only; heartbeat writes cached status atomically and updates local status. Errors leave the snapshot intact but never advance heartbeat deadlines as if successful.

- [ ] **Step 8: Run focused tests and then both complete suites**

  Run `swift test` and `npm test`; require 0 failures and preserve daily audit interruption semantics.

---

### Task 3: Stable Installers and Repeatable P0 Acceptance Bundle

**Files:**
- Modify: `scripts/build_app.sh`
- Create: `scripts/build_macos_dmg.sh`
- Modify: `windows/codex_session_manager_electron/package.json`
- Modify: `windows/codex_session_manager_electron/package-lock.json`
- Create: `windows/codex_session_manager_electron/electron-builder.yml`
- Create: `scripts/acceptance/run_p0_macos.sh`
- Create: `scripts/acceptance/run_p0_windows.ps1`
- Create: `scripts/acceptance/p0-windows-runner.js`
- Modify: `README.md`
- Modify: `docs/操作手册.md`

**Interfaces:**
- Windows primary artifact: per-user NSIS installer to `%LOCALAPPDATA%`, no administrator requirement.
- macOS primary artifact: DMG with the application and `/Applications` link.
- Acceptance report: versioned `p0-acceptance-report.json`, `resource-samples.csv`, and Chinese `summary.txt`; no conversation content is logged.

- [ ] **Step 1: Add packaging contract checks before build changes**

  Assert the Windows configuration has a stable app ID, per-user NSIS target, fixed executable name, uninstall cleanup for the login entry, and includes lifecycle/backup modules plus `vendor/sqlite3.exe`. Assert the macOS bundle links ServiceManagement and the DMG stages the app beside an Applications link.

- [ ] **Step 2: Run contract checks and verify RED**

  Expected: missing installer/DMG configuration.

- [ ] **Step 3: Implement unsigned internal-test installers**

  Keep `package:win` for unpacked package verification and add `dist:win` for NSIS. Create the macOS DMG from the already-built `.app`. Expose signing inputs only through environment variables; never store credentials. Mark unsigned artifacts as internal-test only in filenames and documentation.

- [ ] **Step 4: Build and inspect both artifacts**

  Run `./scripts/build_app.sh`, `./scripts/build_macos_dmg.sh`, `npm run package:win`, and `npm run dist:win`. Inspect archive contents and verify checksums. Do not publish artifacts.

- [ ] **Step 5: Write the isolated acceptance runner tests**

  The runner prompts for a direct department/employee catalog entry, creates only `devices/p0-acceptance-<UUID>`, verifies its own marker before cleanup, and refuses any pre-existing/non-owned directory. Generate valid JSONL fixtures without real conversation content. Report pass/fail for three 12.77 MiB initial uploads, readback hashes, a 287 MiB streaming restore, disconnect/reconnect, and lifecycle manual gates.

- [ ] **Step 6: Implement and dry-run the acceptance runners locally**

  Windows runs production Node backup modules through the packaged Electron runtime with `ELECTRON_RUN_AS_NODE=1`; macOS runs equivalent production Swift core tests and samples the installed app with `ps`. Quick mode completes functional and performance checks; `--soak 24h` records RSS/working set, CPU, handles/file descriptors, and process count.

- [ ] **Step 7: Apply release gates to generated reports**

  Windows three-run median throughput must be at least 5 MiB/s from scan start through NAS readback. A 287 MiB restore must keep macOS below about 600 MiB and Windows process group at or below 700 MiB, with less than 128 MiB warmed-baseline increase and recovery to within 50 MiB after 10 minutes. Idle CPU must average below 2%; Windows 24-hour post-warm-up growth must stay below 50 MiB; macOS must show no monotonic growth. Login restart, silent launch, tray/Dock reopen, explicit quit, wake catch-up, and NAS reconnect are mandatory manual confirmations recorded by the report.

- [ ] **Step 8: Run final verification**

  Run `swift test`, `swift build`, `npm test`, `node --check` on every changed JavaScript file, `git diff --check`, both package builds, and static searches proving idle timer paths do not call the write probe and recovery paths do not read whole NAS sessions. Record real Windows/macOS acceptance as pending until their reports exist; do not claim production readiness from automated tests alone.

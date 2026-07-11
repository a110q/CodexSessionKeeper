# NAS Direct Incremental Backup Design

## Status

Approved in conversation on 2026-07-11.

## Goal

Prevent employee Codex conversations from being lost by writing conversation backups directly to the company NAS. The first-run flow must prevent accidental selection of the wrong backup location without introducing NAS credentials, administrator provisioning inside the app, or a complicated setup wizard.

The company NAS endpoint is fixed:

- Server: `192.168.10.99`
- Share: `文件中转站`
- Trusted backup root: `codex会话备份`

Department and employee directories are created by an administrator before the employee configures the app. The app reads those directories dynamically, so adding a department or employee does not require an application update.

## Scope

The NAS receives only the data required to preserve and recover conversations:

- active and archived session JSONL files;
- a minimal manifest describing backed-up sessions;
- backup status and device identity metadata.

The app must not copy `auth.json`, account credentials, `config.toml`, the live Codex `state_5.sqlite`, or full snapshots to the NAS. Existing full snapshots remain on the local computer and retain their current behavior.

The app may store configuration and operational metadata locally, including the selected department and employee, the stable device UUID, file offsets, hashes, and the last displayed status. It must not create an additional local cache or pending queue containing conversation bodies. The original conversation files maintained by Codex under `~/.codex` are not considered an app-created backup cache.

## Non-goals

- Managing SMB usernames, passwords, or Keychain/Credential Manager entries.
- Automatically mounting or signing in to the NAS.
- Creating department or employee directories.
- Migrating or deleting old NAS backup data when the employee changes configuration.
- Uploading full snapshots or recreating the employee's complete Codex account state on the NAS.
- Enforcing confidentiality between employees who use the shared NAS account.
- Providing offline durability after the source conversation has been deleted while the NAS is unavailable.

## Chosen Approach

The application uses a fixed, trusted NAS endpoint and presents department and employee selectors populated from the NAS directory tree. Employees never type or browse to an arbitrary filesystem path.

This approach was selected over:

1. A Finder or File Explorer folder picker, which makes accidental selection of the wrong directory more likely.
2. Per-machine configuration files distributed by IT, which add deployment and maintenance work across approximately 130 computers.
3. A freely editable NAS server or path, which weakens validation and creates inconsistent deployments.

## Directory Model

The administrator-owned and application-owned portions are separated:

```text
192.168.10.99/
  文件中转站/
    codex会话备份/                 # fixed trusted root
      运营部/                      # administrator-created department
        陈超/                      # administrator-created employee
          devices/                 # application-managed
            Mac-mini-a13f/         # application-managed stable device directory
              device.json
              incremental-backups/
                manifest.json
                status.json
                sessions/
                archived_sessions/
```

Below `incremental-backups/`, the destination mirrors the source-relative path under separate roots:

```text
incremental-backups/sessions/<relative path below ~/.codex/sessions>
incremental-backups/archived_sessions/<relative path below ~/.codex/archived_sessions>
```

Only regular `.jsonl` files are eligible. Every relative path passes the existing backup path-boundary validation before reading or writing. Separating the two source roots prevents active and archived files with the same relative path from colliding.

The device directory name combines a sanitized, user-readable device name with a short suffix derived from a locally generated UUID. The full UUID is stored in `device.json`. A cloned or colliding display name therefore does not cause two computers to share a write location.

The app may create `devices/`, the current device directory, and their fixed children. It must never create the selected department or employee directory.

## Component Boundaries

### Company NAS locator

Resolves only the fixed company server and share. It returns a verified filesystem root or a typed unavailable/error result. It does not enumerate employees, persist credentials, or start a backup.

On macOS it inspects mounted SMB filesystems and verifies that the mount source represents `192.168.10.99/文件中转站`; it must not trust a directory merely because it is named `/Volumes/文件中转站`. On Windows it accesses the fixed UNC share `\\192.168.10.99\文件中转站` through the operating system's existing SMB session. A ping response alone is never sufficient.

### NAS directory catalog

Lists direct child directories of the trusted backup root as departments and direct child directories of the selected department as employees. It ignores files, hidden application metadata, symlinks, junctions, reparse points, and entries whose canonical location escapes the expected parent.

The catalog is read dynamically and supports an explicit refresh action. It does not create missing entries.

### NAS path validator

Resolves and validates every selected or derived path before use. It enforces the exact hierarchy:

```text
codex会话备份/<department>/<employee>
```

Both department and employee must be single existing path segments obtained from the directory catalog. The canonical employee directory must be a direct child of the canonical department directory, which must itself be a direct child of the canonical trusted root. Traversal, absolute-path injection, alternate separators, symlinks, junctions, reparse points, and local lookalike directories are rejected.

The same validator is used during first-run configuration, application startup, NAS reconnection, reconfiguration, backup writes, and recovery reads. UI validation alone is not a security boundary.

### Write capability probe

Tests the selected employee directory with a unique temporary path. It verifies directory creation, file creation, write, flush, read-back, atomic rename, and deletion. Temporary data is removed on both success and failure where possible.

Activation then creates or validates `devices/<device-name-and-suffix>`, writes `device.json` atomically, and repeats a target-local probe before saving the configuration as active. If the directory contains a different device UUID, the app must not overwrite it; it derives a non-conflicting device directory instead.

### Local configuration store

Persists only:

- a configuration format version;
- fixed endpoint identity;
- selected department and employee names;
- stable device UUID and display name;
- the last known validated target identity;
- non-content runtime state needed to resume incremental writes.

It does not store SMB credentials or conversation content. A saved configuration is not treated as proof that the NAS is currently available.

### Incremental backup agent

Accepts only a validated device backup root. It owns initial seeding, incremental append, recovery from interrupted writes, status production, and retry scheduling. It cannot silently substitute a local destination.

### Incremental recovery source

Lists valid device backups below the selected employee's `devices/` directory. The current device is shown first, while older devices remain available as read-only recovery sources. This allows a replacement computer to recover conversations written by a previous computer without reusing that computer's write identity.

Full snapshot restore remains connected to the existing local snapshot root and is independent of this component.

## First-run Experience

The backup agent must not start before configuration is valid.

1. **Detect company NAS.** The app attempts a real read of the fixed trusted backup root.
2. **Unavailable state.** If the share is not mounted or accessible, the page displays `公司 NAS 未连接`, platform-appropriate connection guidance, and a `重新检测` action. There is no skip-to-local option.
3. **Select department.** The app displays valid direct children of `codex会话备份`.
4. **Select employee.** The app displays valid direct children of the selected department.
5. **Validate.** The app resolves canonical paths and performs the write capability probe.
6. **Confirm.** The page shows the recognized department, employee, and fixed company NAS location. The employee explicitly selects `确认并开始备份`.
7. **Activate.** The app creates the stable device directory, completes its target-local probe, persists configuration, and starts the initial backup.

Manual filesystem paths are never accepted. Closing the app or encountering a validation failure leaves the app unconfigured. A fixed application-owned directory may remain only if cleanup was impossible after a failed capability probe; such a directory does not make the configuration active.

On later launches, the app revalidates the saved endpoint, employee path, and device marker before starting the agent. A temporarily unavailable NAS does not erase the saved selection; it moves the app into the disconnected state.

## Backup Data Flow

### Initial seed

The first successful activation scans the current Codex `sessions` and `archived_sessions` roots and creates a fresh NAS backup from the source files that still exist. It does not copy the previous local incremental-backup directory, its cursors, or its status.

Each new target file is written to a unique temporary file in the same NAS directory, flushed, verified, and atomically renamed into place. The manifest becomes visible only after the files it describes have been committed.

### Incremental append

For each session, the committed NAS target represents a verified byte prefix of the source JSONL. The agent writes only bytes added after the last committed source offset.

The required ordering is:

1. validate the source and destination paths;
2. verify that the NAS target still matches the expected source prefix;
3. append new bytes;
4. flush the NAS file successfully;
5. update committed offset and manifest state.

An error before step 5 must not advance the committed cursor. A process interruption may leave an uncommitted partial suffix. On restart, the agent compares the target length and content with the source prefix, safely completes a matching partial append, or reconstructs the target through a verified temporary file and atomic replacement. It must not overwrite a previously committed file with stale session content.

Authoritative recovery content is the NAS JSONL. Local operational cursor state is rebuildable from the NAS file and source prefix. The design must not place a live SQLite database on SMB solely to coordinate incremental writes.

### Metadata commits

`manifest.json` and `status.json` are written through same-directory temporary files and atomic replacement. Metadata must never claim that conversation bytes were committed before the corresponding NAS file was flushed.

### Multiple devices

Each device writes only within its own UUID-backed directory. Devices do not share a cursor store or writable session file. The employee recovery view may read every valid device directory.

## NAS Disconnection and Retry

When the NAS becomes unavailable:

- the current write fails closed;
- no committed cursor advances;
- the app does not create a local conversation spool or fallback backup;
- the main UI changes to `NAS 未连接，备份已暂停`;
- the app records only non-content diagnostic/runtime state locally;
- periodic retry and a manual `立即重试` action remain available.

After reconnection, the app revalidates the server/share identity, trusted root, employee directory, device marker, and write capability before resuming. It then catches up from the last verified committed offset.

The accepted limitation is explicit: if a conversation has not reached the NAS and the source JSONL is deleted while the NAS is unavailable, the missing content cannot be recovered. This follows from the chosen no-local-spool policy.

## Runtime Status

The main UI exposes at least these states:

- `未配置`
- `NAS 未连接`
- `正在建立初始备份`
- `备份正常`
- `存在待补传内容`
- `备份失败`

The status view includes the selected department and employee, device name, last successful backup time, current target identity, and an actionable failure reason. Initial seeding reports file-count progress. Pending status reports the number of sessions awaiting synchronization without copying their contents locally.

Permission changes, a deleted employee directory, insufficient NAS space, failed flush, failed atomic rename, marker mismatch, or path-boundary failure pauses backup and leaves committed cursors unchanged. The app must not display a healthy state after any of these failures.

If the app exits with known uncommitted source changes, it displays that NAS backup has not completed. This warning is informational and does not create a local content queue.

## Reconfiguration

The settings page provides `更换 NAS 备份身份`:

1. Pause the current backup agent.
2. Detect and revalidate the fixed company NAS.
3. Reload department and employee choices from the NAS.
4. Show the old and new identities and require explicit confirmation.
5. Validate and activate a device directory below the new employee.
6. Create a fresh initial backup from the current Codex source files.

The app does not move, merge, or delete the old employee/device backup. A failed new configuration leaves the previous saved identity intact, although its agent remains subject to normal availability validation.

## Security Boundary

The validation in this design prevents accidental wrong-path configuration and prevents the application from escaping the approved NAS hierarchy. It is not employee authentication.

All employees currently connect with the shared NAS identity `171`, so anyone with that share access may be able to browse another employee's conversation files outside the application. Confidentiality between employees requires separate NAS accounts and server-side ACLs and is intentionally outside this design.

## Acceptance Tests

### NAS discovery and catalog

- Reject an unavailable server, wrong IP, wrong share, missing trusted root, and a same-named local directory.
- Accept the real mounted SMB share on macOS and the fixed UNC share on Windows.
- Return only safe direct-child department and employee directories.
- Ignore files, hidden app metadata, symlinks, junctions, reparse points, and canonical-path escapes.
- Show newly administrator-created department or employee folders after refresh without an application update.

### Configuration validation

- Reject empty, manually injected, nested, absolute, traversal, alternate-separator, symlink, and junction selections.
- Reject selection of the NAS root, trusted backup root, or a department directory as an employee target.
- Fail activation when create, write, flush, read-back, atomic rename, or delete probing fails.
- Remove probe artifacts where possible and never mark a failed configuration active.
- Persist a validated selection and restore it only after startup revalidation.

### Device isolation

- Reuse the same stable device directory across restarts on one computer.
- Create distinct directories for two computers with the same display name.
- Never overwrite a directory whose `device.json` contains another UUID.
- List valid old-device backups as read-only recovery sources on a replacement computer.

### Backup correctness

- Initial seed includes current active and archived session JSONL files.
- Initial seed does not import old local backup cursors or stale status.
- Normal growth appends only new bytes.
- Failed or interrupted writes do not advance committed offsets.
- A matching partial append resumes safely after restart.
- A mismatched target is repaired through verified temporary output without replacing committed data with stale content.
- Manifest and status commits never precede conversation data commits.
- Concurrent backup activity from two devices cannot overwrite the other device's data.

### Disconnection and recovery

- Disconnecting the NAS changes UI state and pauses writes.
- No local conversation cache or pending-body queue appears while offline.
- Reconnecting triggers full identity/path validation before catch-up.
- Catch-up resumes from the last committed prefix.
- Deleted source data that was never uploaded is reported as unrecoverable rather than silently marked complete.

### Scope and regression

- NAS output contains no `auth.json`, `config.toml`, live `state_5.sqlite`, account credentials, or full snapshots.
- Existing local snapshot creation and restore behavior remains unchanged.
- Reconfiguration creates a new initial backup and neither moves nor deletes the old NAS backup.
- macOS and Windows both pass real-NAS tests for first run, refresh, initial seed, incremental append, process interruption, disconnect, reconnect, multi-device isolation, and recovery from a previous device.

## Success Criteria

The feature is ready when an employee can install the app, connect the already configured company NAS through the operating system, choose a dynamically discovered department and name, and receive a verifiably current NAS copy of every active and archived Codex conversation without choosing a filesystem path or creating a second local conversation backup. Wrong or unavailable destinations must fail visibly, and a replacement computer must be able to discover and recover the employee's previous device backups.

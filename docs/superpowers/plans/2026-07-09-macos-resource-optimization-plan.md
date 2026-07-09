# macOS Resource Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce macOS `codex_会话管理` idle CPU and long-running pipe file descriptor growth while preserving the current UI appearance and backup behavior.

**Architecture:** Keep the current SwiftUI app structure, but reduce unnecessary model publications and repeated list filtering. Treat process cleanup separately by tightening `Process + Pipe` helpers in the app and Swift core backup modules. Validate the result with unit tests, build checks, and live resource sampling.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Swift Package Manager, `/usr/bin/sqlite3`, macOS Activity Monitor/top/sample/lsof.

## Global Constraints

- Keep the current macOS UI look and layout broadly intact.
- Target idle CPU of 2-5% after the app is idle.
- Avoid sustained 30-60% CPU after switching back to the app.
- Stop pipe file descriptors from growing over long-running sessions.
- Preserve automatic local incremental backup, restore, and SQLite repair behavior.
- Keep the change scoped to macOS unless tests expose shared-code impact.
- No visual redesign.
- No Windows UI change in this pass.
- No NAS sync, enterprise monitoring, signing, or notarization change.
- No rewrite of the backup storage format.
- No replacement of SwiftUI with AppKit.

---

## File Structure

- Modify `Sources/CodexSessionVault/main.swift`
  - Increase backup status refresh interval.
  - Add visible-session cache in `VaultModel`.
  - Gate backup status publications when visible display state is unchanged.
  - Update session list views to read `visibleSessions`.
  - Close worker process pipe handles.
- Modify `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
  - Close sqlite process input/output/error pipe handles deterministically.
- Modify `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift`
  - Close sqlite process output/error pipe handles deterministically.
- Existing tests remain in `Tests/CodexSessionVaultCoreTests/`.
  - Reuse current `BackupCursorStoreTests` and `RecoveredThreadIndexTests` to guard behavior.
  - Resource behavior is verified with live process checks because the SwiftUI app target is not currently exposed as a testable library.

---

### Task 1: Gate macOS Backup Status Refresh Publications

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`

**Interfaces:**
- Consumes: existing `BackupStatus`, `localBackupStatusLabel(for:)`, `localBackupStatusDetail(for:)`, and `shortBackupDetail(_:)`.
- Produces: `publishLocalBackupStatus(status:label:detail:)`, used only inside `VaultModel`.

- [ ] **Step 1: Verify current behavior and establish baseline**

Run:

```bash
swift test
```

Expected: PASS with the existing full Swift test suite.

Run:

```bash
./scripts/build_app.sh
```

Expected: PASS and print:

```text
/Users/mqzj/Documents/CodexConversation/CodexSessionKeeper/dist/codex_会话管理.app
```

- [ ] **Step 2: Increase backup status refresh interval**

In `Sources/CodexSessionVault/main.swift`, change:

```swift
private static let localBackupStatusRefreshInterval: UInt64 = 3_000_000_000
```

to:

```swift
private static let localBackupStatusRefreshInterval: UInt64 = 15_000_000_000
```

- [ ] **Step 3: Add a gated publisher helper**

Inside `VaultModel`, near `refreshLocalBackupStatus()`, add:

```swift
private func publishLocalBackupStatus(status nextStatus: BackupStatus?, label nextLabel: String, detail nextDetail: String) {
    let currentIsError = localBackupStatus?.status == .error || localBackupStatusLabel.contains("错误")
    let nextIsError = nextStatus?.status == .error || nextLabel.contains("错误")
    guard localBackupStatusLabel != nextLabel
        || localBackupStatusDetail != nextDetail
        || currentIsError != nextIsError
    else {
        return
    }

    localBackupStatus = nextStatus
    localBackupStatusLabel = nextLabel
    localBackupStatusDetail = nextDetail
}
```

This compares visible display state instead of the whole `BackupStatus`, so heartbeat-only changes do not invalidate the SwiftUI tree.

- [ ] **Step 4: Route all backup status assignments through the helper**

Replace `refreshLocalBackupStatus()` with:

```swift
private func refreshLocalBackupStatus() {
    guard let paths = localBackupPaths else {
        publishLocalBackupStatus(
            status: nil,
            label: "备份：未启动",
            detail: "等待启动"
        )
        return
    }

    guard fileManager.fileExists(atPath: paths.statusURL.path) else {
        publishLocalBackupStatus(
            status: nil,
            label: "备份：启动中",
            detail: "等待状态"
        )
        return
    }

    do {
        let status = try loadLocalBackupStatus(from: paths.statusURL)
        publishLocalBackupStatus(
            status: status,
            label: Self.localBackupStatusLabel(for: status.status),
            detail: Self.localBackupStatusDetail(for: status)
        )
    } catch {
        publishLocalBackupStatus(
            status: nil,
            label: "备份：错误",
            detail: Self.shortBackupDetail(error.localizedDescription)
        )
    }
}
```

In `startLocalIncrementalBackup()`, replace:

```swift
localBackupStatusLabel = "备份：启动中"
localBackupStatusDetail = "准备扫描"
```

with:

```swift
publishLocalBackupStatus(
    status: nil,
    label: "备份：启动中",
    detail: "准备扫描"
)
```

- [ ] **Step 5: Run targeted verification**

Run:

```bash
swift test
```

Expected: PASS.

Run:

```bash
./scripts/build_app.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexSessionVault/main.swift
git commit -m "perf: gate macos backup status refresh"
```

---

### Task 2: Cache Visible Sessions And Keep List Rendering Stable

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`

**Interfaces:**
- Consumes: existing `CodexSession`, `sessions`, `sessionSearch`, and `showArchivedSessions`.
- Produces: `@Published private(set) var visibleSessions: [CodexSession]`, `recomputeVisibleSessions()`, and `sessionMatchesVisibleFilter(_:query:)`.

- [ ] **Step 1: Add a cached visible sessions property**

In `VaultModel`, replace:

```swift
@Published var sessions: [CodexSession] = []
```

with:

```swift
@Published var sessions: [CodexSession] = [] {
    didSet {
        recomputeVisibleSessions()
    }
}
@Published private(set) var visibleSessions: [CodexSession] = []
```

Replace:

```swift
@Published var sessionSearch = ""
@Published var showArchivedSessions = true
```

with:

```swift
@Published var sessionSearch = "" {
    didSet {
        recomputeVisibleSessions()
    }
}
@Published var showArchivedSessions = true {
    didSet {
        recomputeVisibleSessions()
    }
}
```

- [ ] **Step 2: Replace repeated filtering with cached filtering**

Replace the existing `filteredSessions` computed property:

```swift
var filteredSessions: [CodexSession] {
    let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return sessions.filter { session in
        guard showArchivedSessions || !session.archived else { return false }
        guard !query.isEmpty else { return true }
        return [
            session.id,
            session.title,
            session.cwd,
            session.modelProvider,
            session.model,
            session.source,
            session.rolloutPath
        ].contains { $0.lowercased().contains(query) }
    }
}
```

with:

```swift
var filteredSessions: [CodexSession] {
    visibleSessions
}

private func recomputeVisibleSessions() {
    let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let nextSessions = sessions.filter { session in
        sessionMatchesVisibleFilter(session, query: query)
    }
    guard nextSessions != visibleSessions else { return }
    visibleSessions = nextSessions
}

private func sessionMatchesVisibleFilter(_ session: CodexSession, query: String) -> Bool {
    guard showArchivedSessions || !session.archived else { return false }
    guard !query.isEmpty else { return true }
    return [
        session.id,
        session.title,
        session.cwd,
        session.modelProvider,
        session.model,
        session.source,
        session.rolloutPath
    ].contains { $0.lowercased().contains(query) }
}
```

Keeping `filteredSessions` as an alias avoids a risky broad rename while making body reads cheap.

- [ ] **Step 3: Update model operations to use the cached array explicitly**

Replace:

```swift
if let selectedSessionID, filteredSessions.contains(where: { $0.id == selectedSessionID }) {
    return
}
selectedSessionID = filteredSessions.first?.id
```

with:

```swift
if let selectedSessionID, visibleSessions.contains(where: { $0.id == selectedSessionID }) {
    return
}
selectedSessionID = visibleSessions.first?.id
```

Replace:

```swift
checkedSessionIDs.formUnion(filteredSessions.map(\.id))
```

with:

```swift
checkedSessionIDs.formUnion(visibleSessions.map(\.id))
```

In `refresh()`, replace both occurrences of:

```swift
selectedSessionID = filteredSessions.first?.id ?? sessions.first?.id
```

with:

```swift
selectedSessionID = visibleSessions.first?.id ?? sessions.first?.id
```

- [ ] **Step 4: Update the sessions pane to read cached sessions**

In `SessionsPane`, replace:

```swift
CountBadge(value: "\(model.filteredSessions.count) / \(model.sessions.count)")
```

with:

```swift
CountBadge(value: "\(model.visibleSessions.count) / \(model.sessions.count)")
```

Replace:

```swift
.disabled(model.filteredSessions.isEmpty)
```

with:

```swift
.disabled(model.visibleSessions.isEmpty)
```

Replace:

```swift
if model.filteredSessions.isEmpty {
```

with:

```swift
if model.visibleSessions.isEmpty {
```

Replace:

```swift
ForEach(model.filteredSessions) { session in
```

with:

```swift
ForEach(model.visibleSessions) { session in
```

Do not change `SessionRow` colors, typography, badges, or selected-row behavior in this task.

- [ ] **Step 5: Run targeted verification**

Run:

```bash
swift test
```

Expected: PASS.

Run:

```bash
./scripts/build_app.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexSessionVault/main.swift
git commit -m "perf: cache macos visible sessions"
```

---

### Task 3: Close Process Pipe Handles Deterministically

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
- Modify: `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift`

**Interfaces:**
- Consumes: existing `Process`, `Pipe`, `runSQLite`, `drain`, and worker process helpers.
- Produces: same command behavior with deterministic pipe handle cleanup.

- [ ] **Step 1: Harden `BackupCursorStore.runSQLite` pipe cleanup**

In `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`, replace the pipe setup in `runSQLite(arguments:input:)`:

```swift
let inputPipe = Pipe()
let outputPipe = Pipe()
let errorPipe = Pipe()
process.standardInput = inputPipe
process.standardOutput = outputPipe
process.standardError = errorPipe
```

with:

```swift
let inputPipe = Pipe()
let outputPipe = Pipe()
let errorPipe = Pipe()
let inputWriter = inputPipe.fileHandleForWriting
process.standardInput = inputPipe
process.standardOutput = outputPipe
process.standardError = errorPipe
defer {
    try? inputWriter.close()
}
```

Replace:

```swift
inputPipe.fileHandleForWriting.write(Data(input.utf8))
try? inputPipe.fileHandleForWriting.close()
```

with:

```swift
inputWriter.write(Data(input.utf8))
try? inputWriter.close()
```

Replace `drain(_:,into:,group:)` with:

```swift
private static func drain(_ pipe: Pipe, into collector: PipeDataCollector, group: DispatchGroup) {
    group.enter()
    let reader = pipe.fileHandleForReading
    DispatchQueue.global(qos: .utility).async {
        let data = reader.readDataToEndOfFile()
        try? reader.close()
        collector.append(data)
        group.leave()
    }
}
```

- [ ] **Step 2: Harden `RecoveredThreadIndexWriter.runSQLite` pipe cleanup**

In `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift`, replace:

```swift
let outputPipe = Pipe()
let errorPipe = Pipe()
process.standardOutput = outputPipe
process.standardError = errorPipe
try process.run()
process.waitUntilExit()
let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
```

with:

```swift
let outputPipe = Pipe()
let errorPipe = Pipe()
let outputReader = outputPipe.fileHandleForReading
let errorReader = errorPipe.fileHandleForReading
defer {
    try? outputReader.close()
    try? errorReader.close()
}
process.standardOutput = outputPipe
process.standardError = errorPipe
try process.run()
process.waitUntilExit()
let output = String(data: outputReader.readDataToEndOfFile(), encoding: .utf8) ?? ""
let error = String(data: errorReader.readDataToEndOfFile(), encoding: .utf8) ?? ""
```

- [ ] **Step 3: Harden worker process pipe cleanup**

In `Sources/CodexSessionVault/main.swift`, inside the worker process path that creates:

```swift
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
process.standardOutput = stdoutPipe
process.standardError = stderrPipe
```

replace that setup with:

```swift
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
let stdoutReader = stdoutPipe.fileHandleForReading
let stderrReader = stderrPipe.fileHandleForReading
defer {
    try? stdoutReader.close()
    try? stderrReader.close()
}
process.standardOutput = stdoutPipe
process.standardError = stderrPipe
```

Replace:

```swift
let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
_ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
```

with:

```swift
let stderr = String(decoding: stderrReader.readDataToEndOfFile(), as: UTF8.self)
_ = stdoutReader.readDataToEndOfFile()
```

- [ ] **Step 4: Run behavior-preserving tests**

Run:

```bash
swift test --filter BackupCursorStoreTests
```

Expected: PASS.

Run:

```bash
swift test --filter RecoveredThreadIndexTests
```

Expected: PASS.

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexSessionVault/main.swift Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift
git commit -m "perf: close macos process pipe handles"
```

---

### Task 4: Build And Resource Verification

**Files:**
- No source files expected unless verification exposes a bug.

**Interfaces:**
- Consumes: app artifact at `dist/codex_会话管理.app`.
- Produces: evidence for CPU, memory, and pipe FD behavior.

- [ ] **Step 1: Run full automated verification**

Run:

```bash
swift test
```

Expected: PASS.

Run:

```bash
./scripts/build_app.sh
```

Expected: PASS and print:

```text
/Users/mqzj/Documents/CodexConversation/CodexSessionKeeper/dist/codex_会话管理.app
```

- [ ] **Step 2: Restart the app from the fresh build**

If an old app process is running, stop only that process:

```bash
pkill -f 'dist/codex_会话管理.app/Contents/MacOS/CodexSessionVault' || true
```

Start the fresh app:

```bash
open /Users/mqzj/Documents/CodexConversation/CodexSessionKeeper/dist/codex_会话管理.app
```

Find its PID:

```bash
pgrep -fl CodexSessionVault
```

Expected: one fresh `CodexSessionVault` process for the app.

- [ ] **Step 3: Capture initial resource baseline**

Replace `<pid>` with the fresh app PID:

```bash
ps -p <pid> -o pid,etime,time,%cpu,%mem,rss,command
lsof -a -p <pid> | awk 'NR>1{print $5}' | sort | uniq -c | sort -nr
```

Expected:

- CPU may spike briefly during startup.
- Pipe count is bounded and not already in the hundreds immediately after startup.
- RSS is recorded for comparison.

- [ ] **Step 4: Capture idle resource sample**

Leave the app open and idle for 5 minutes, then run:

```bash
top -l 5 -s 2 -pid <pid> -stats pid,command,cpu,mem,threads,ports,rsize,time -n 1
lsof -a -p <pid> | awk 'NR>1{print $5}' | sort | uniq -c | sort -nr
sample <pid> 5 -file /tmp/codex-session-manager-resource.sample.txt
```

Expected:

- CPU is usually in the 2-5% range while idle.
- Short spikes are acceptable; sustained 30-60% is not acceptable.
- Pipe count does not grow linearly from the initial baseline.
- `sample` is not continuously dominated by SwiftUI/AppKit layout during idle.

- [ ] **Step 5: Verify backup still runs**

Run:

```bash
node -e 'const fs=require("fs"); const p=process.env.HOME+"/.codex-session-vault/incremental-backups/status.json"; const s=JSON.parse(fs.readFileSync(p,"utf8")); console.log(JSON.stringify({status:s.status,sessionCount:s.sessionCount,lineCount:s.lineCount,bytesBackedUp:s.bytesBackedUp,lastBackupAt:s.lastBackupAt,lastHeartbeatAt:s.lastHeartbeatAt,lastError:s.lastError ?? null}, null, 2));'
```

Expected:

```json
{
  "status": "running"
}
```

The printed object will include more fields, but `status` must be `running` and `lastError` should be `null` or absent.

- [ ] **Step 6: Commit verification docs only if needed**

If no source changes are needed, do not create a commit. If verification reveals a documentation correction, commit it with:

```bash
git add <changed-doc-file>
git commit -m "docs: record macos resource verification"
```

---

## Final Verification Checklist

Run all commands from `/Users/mqzj/Documents/CodexConversation/CodexSessionKeeper`.

```bash
swift test
./scripts/build_app.sh
git status --short --branch
```

Expected:

- Swift tests pass.
- macOS app builds.
- Working tree has only intentional tracked changes and the existing untracked `.codegraph/` local index.

## Risk Notes

- The `VaultModel` lives in the executable target, so this plan avoids a broad target split just to test UI model internals.
- The visible sessions cache keeps `filteredSessions` as a compatibility alias to minimize churn.
- The first implementation should not change row colors, gradients, typography, or overall layout. If resource sampling still shows heavy layout after Task 1 and Task 2, row styling can be revisited in a separate design.

# Incremental Backup Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manual “备份恢复” flow that restores only Codex sessions missing from the current local Codex data directory by using the existing local incremental backup files.

**Architecture:** Build a small catalog layer that reads the incremental backup manifest and classifies each backed-up session as missing, existing, or invalid. For restore, generate a virtual recovery package containing only selected missing sessions, then reuse the existing conversation-only restore path so `.jsonl` and `session_index.jsonl` merge semantics stay consistent. macOS and Windows get platform-specific UI/IPC integration but share the same manifest, classification, and recovery package behavior.

**Tech Stack:** Swift 6 / SwiftPM / SwiftUI / Foundation for macOS; Electron 30 / Node.js / `node:test` / `sql.js` for Windows; existing snapshot restore and protection-point code paths.

## Global Constraints

- Restore is manual only; no silent automatic restore from incremental backups.
- Default restore set is missing sessions only.
- Existing sessions are never overwritten by the backup-restore UI.
- Restore must create a restore-before protection point before writing into `~/.codex`.
- Restore writes recovered sessions under `~/.codex/sessions/recovered/<session-id>.jsonl`.
- `auth.json`, `config.toml`, credentials, and login state are not restored.
- First version uses local backup root `~/.codex-session-vault/incremental-backups`; NAS restore is outside this plan.
- Existing automatic incremental backup, manual snapshot, and snapshot restore behavior must remain compatible.
- Do not revive the discarded macOS stage-manager performance style changes.

---

## File Structure

### macOS

- Create: `Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift`
  - Reads `manifest.json`, validates backup files, scans current Codex session files, and returns restore candidates.
- Modify: `Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift`
  - Keep the existing package writer and verify selected-only package output with a regression test.
- Create: `Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift`
  - Covers missing/existing/invalid backup classification and path traversal rejection.
- Modify: `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`
  - Add selected-only package assertions for incremental backup restore.
- Modify: `Sources/CodexSessionVault/main.swift`
  - Add backup-restore UI state, backup-restore source switch, worker operation, protection point, and restore action.
- Modify: `docs/操作手册.md`
  - Document “快照恢复 -> 备份恢复” usage and restart expectation.

### Windows

- Create: `windows/codex_session_manager_electron/src/backup/incremental-recovery.js`
  - Reads manifest, classifies candidates, validates backup paths, and builds a virtual recovery package.
- Create: `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`
  - Covers classification, path safety, package generation, and selected-only restore data.
- Modify: `windows/codex_session_manager_electron/src/main.js`
  - Add IPC handlers and restore orchestration using existing `restoreConversationsOnly`.
- Modify: `windows/codex_session_manager_electron/src/preload.js`
  - Expose `loadIncrementalBackupSessions` and `restoreIncrementalBackupSessions`.
- Modify: `windows/codex_session_manager_electron/src/index.html`
  - Add backup-restore controls inside the snapshots section.
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
  - Render the backup-restore list and call new IPC APIs.
- Modify: `windows/codex_session_manager_electron/src/styles.css`
  - Add compact list/status styles that preserve existing visual rhythm.
- Modify: `docs/操作手册.md`
  - Document Windows use path.

---

### Task 1: Swift Incremental Backup Catalog

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift`
- Create: `Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift`

**Interfaces:**
- Consumes: `BackupPaths`, `BackupManifestStore`, `BackupSessionRecord`
- Produces:
  - `public enum IncrementalRestoreStatus: String, Codable, Sendable`
  - `public struct IncrementalRestoreCandidate: Codable, Equatable, Identifiable, Sendable`
  - `public struct IncrementalBackupCatalogResult: Codable, Equatable, Sendable`
  - `public final class IncrementalBackupCatalog`
  - `public func load(currentSessionIDs: Set<String>) throws -> IncrementalBackupCatalogResult`

- [ ] **Step 1: Write the failing Swift catalog tests**

Create `Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift`:

```swift
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct IncrementalBackupCatalogTests {
    @Test
    func classifiesMissingAndExistingSessions() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        try fixture.writeBackup(relativePath: "sessions/2026/07/08/missing.jsonl", contents: #"{"role":"user","content":"restore me"}"# + "\n")
        try fixture.writeBackup(relativePath: "sessions/2026/07/08/existing.jsonl", contents: #"{"role":"user","content":"already here"}"# + "\n")
        try fixture.saveManifest(records: [
            fixture.makeRecord(sessionID: "missing", backupPath: "sessions/2026/07/08/missing.jsonl", title: "restore me"),
            fixture.makeRecord(sessionID: "existing", backupPath: "sessions/2026/07/08/existing.jsonl", title: "already here")
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: ["existing"])

        #expect(result.totalCount == 2)
        #expect(result.missingCount == 1)
        #expect(result.existingCount == 1)
        #expect(result.candidates.first { $0.sessionId == "missing" }?.status == .missing)
        #expect(result.candidates.first { $0.sessionId == "existing" }?.status == .existing)
    }

    @Test
    func invalidBackupPathDoesNotEscapeBackupRoot() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        try fixture.saveManifest(records: [
            fixture.makeRecord(sessionID: "bad", backupPath: "../outside.jsonl", title: "bad")
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: [])

        let bad = try #require(result.candidates.first)
        #expect(bad.status == .invalidBackup)
        #expect(bad.error?.contains("escapes backup root") == true)
        #expect(result.errorCount == 1)
    }

    @Test
    func missingBackupFileIsVisibleButNotRestorable() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        try fixture.saveManifest(records: [
            fixture.makeRecord(sessionID: "missing-file", backupPath: "sessions/2026/07/08/missing-file.jsonl", title: "missing file")
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: [])

        let candidate = try #require(result.candidates.first)
        #expect(candidate.status == .backupFileMissing)
        #expect(candidate.isRestorable == false)
        #expect(result.errorCount == 1)
    }
}

private final class IncrementalCatalogFixture {
    let tempDirectory: URL
    let paths: BackupPaths
    let now: Date

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalCatalogFixture-\(UUID().uuidString)", isDirectory: true)
        paths = BackupPaths(
            homeDirectory: tempDirectory,
            codexRoot: tempDirectory.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: tempDirectory.appendingPathComponent("incremental-backups", isDirectory: true)
        )
        now = try #require(ISO8601DateFormatter().date(from: "2026-07-08T12:00:00Z"))
        try FileManager.default.createDirectory(at: paths.codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func writeBackup(relativePath: String, contents: String) throws {
        let url = paths.backupRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func saveManifest(records: [BackupSessionRecord]) throws {
        let manifest = BackupManifest(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            createdAt: now,
            updatedAt: now,
            sessions: Dictionary(uniqueKeysWithValues: records.map { ($0.sessionId, $0) })
        )
        let store = BackupManifestStore(manifestURL: paths.manifestURL)
        try store.save(manifest)
    }

    func makeRecord(sessionID: String, backupPath: String, title: String?) -> BackupSessionRecord {
        BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: paths.codexRoot.appendingPathComponent("sessions/\(sessionID).jsonl").path,
            backupPath: backupPath,
            title: title,
            firstSeenAt: now,
            lastBackedUpAt: now,
            lineCount: 1,
            bytesBackedUp: 32,
            status: "active"
        )
    }
}
```

- [ ] **Step 2: Run the failing Swift test**

Run:

```bash
swift test --filter IncrementalBackupCatalogTests
```

Expected: FAIL because `IncrementalBackupCatalog` and related types do not exist.

- [ ] **Step 3: Implement the catalog types and safe path validation**

Create `Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift` with:

```swift
import Foundation

public enum IncrementalRestoreStatus: String, Codable, Sendable {
    case missing
    case existing
    case invalidBackup
    case backupFileMissing
}

public struct IncrementalRestoreCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    public let title: String
    public let sourcePath: String
    public let backupPath: String
    public let backupFilePath: String
    public let firstSeenAt: Date
    public let lastBackedUpAt: Date?
    public let lineCount: Int
    public let bytesBackedUp: Int64
    public let status: IncrementalRestoreStatus
    public let error: String?

    public var isRestorable: Bool {
        status == .missing
    }
}

public struct IncrementalBackupCatalogResult: Codable, Equatable, Sendable {
    public let backupRoot: String
    public let updatedAt: Date?
    public let totalCount: Int
    public let missingCount: Int
    public let existingCount: Int
    public let errorCount: Int
    public let candidates: [IncrementalRestoreCandidate]
}

public final class IncrementalBackupCatalog {
    private let paths: BackupPaths
    private let fileManager: FileManager

    public init(paths: BackupPaths = BackupPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load(currentSessionIDs: Set<String>) throws -> IncrementalBackupCatalogResult {
        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path
        )
        let candidates = manifest.sessions.values
            .sorted { ($0.lastBackedUpAt ?? $0.firstSeenAt) > ($1.lastBackedUpAt ?? $1.firstSeenAt) }
            .map { candidate(for: $0, currentSessionIDs: currentSessionIDs) }

        return IncrementalBackupCatalogResult(
            backupRoot: paths.backupRoot.path,
            updatedAt: manifest.updatedAt,
            totalCount: candidates.count,
            missingCount: candidates.filter { $0.status == .missing }.count,
            existingCount: candidates.filter { $0.status == .existing }.count,
            errorCount: candidates.filter { $0.status == .invalidBackup || $0.status == .backupFileMissing }.count,
            candidates: candidates
        )
    }

    private func candidate(for record: BackupSessionRecord, currentSessionIDs: Set<String>) -> IncrementalRestoreCandidate {
        do {
            let backupFile = try validatedBackupFileURL(for: record)
            let status: IncrementalRestoreStatus = currentSessionIDs.contains(record.sessionId) ? .existing : .missing
            return makeCandidate(record: record, backupFile: backupFile, status: status, error: nil)
        } catch let error as LocalizedError {
            let description = error.errorDescription ?? String(describing: error)
            let status: IncrementalRestoreStatus = description.contains("missing") ? .backupFileMissing : .invalidBackup
            return makeCandidate(record: record, backupFile: nil, status: status, error: description)
        } catch {
            return makeCandidate(record: record, backupFile: nil, status: .invalidBackup, error: String(describing: error))
        }
    }

    private func makeCandidate(
        record: BackupSessionRecord,
        backupFile: URL?,
        status: IncrementalRestoreStatus,
        error: String?
    ) -> IncrementalRestoreCandidate {
        IncrementalRestoreCandidate(
            sessionId: record.sessionId,
            title: (record.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? record.title : nil) ?? record.sessionId,
            sourcePath: record.sourcePath,
            backupPath: record.backupPath,
            backupFilePath: backupFile?.path ?? "",
            firstSeenAt: record.firstSeenAt,
            lastBackedUpAt: record.lastBackedUpAt,
            lineCount: record.lineCount,
            bytesBackedUp: record.bytesBackedUp,
            status: status,
            error: error
        )
    }

    private func validatedBackupFileURL(for record: BackupSessionRecord) throws -> URL {
        guard !record.backupPath.isEmpty else {
            throw CatalogError.invalidBackupPath(sessionID: record.sessionId, backupPath: record.backupPath, reason: "is empty")
        }
        guard !record.backupPath.hasPrefix("/") else {
            throw CatalogError.invalidBackupPath(sessionID: record.sessionId, backupPath: record.backupPath, reason: "is absolute")
        }
        let components = record.backupPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." }) else {
            throw CatalogError.invalidBackupPath(sessionID: record.sessionId, backupPath: record.backupPath, reason: "is not normalized")
        }
        guard !components.contains("..") else {
            throw CatalogError.backupPathEscapesRoot(sessionID: record.sessionId, backupPath: record.backupPath)
        }
        var fileURL = paths.backupRoot
        for (index, component) in components.enumerated() {
            fileURL = fileURL.appendingPathComponent(component, isDirectory: index < components.count - 1)
        }
        let root = paths.backupRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root + "/") else {
            throw CatalogError.backupPathEscapesRoot(sessionID: record.sessionId, backupPath: record.backupPath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CatalogError.backupFileMissing(sessionID: record.sessionId, filePath: fileURL.path)
        }
        return fileURL
    }
}

private enum CatalogError: LocalizedError {
    case invalidBackupPath(sessionID: String, backupPath: String, reason: String)
    case backupPathEscapesRoot(sessionID: String, backupPath: String)
    case backupFileMissing(sessionID: String, filePath: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBackupPath(sessionID, backupPath, reason):
            return "Backup path for session \(sessionID) \(reason): \(backupPath)"
        case let .backupPathEscapesRoot(sessionID, backupPath):
            return "Backup path for session \(sessionID) escapes backup root: \(backupPath)"
        case let .backupFileMissing(sessionID, filePath):
            return "Backup file is missing for session \(sessionID): \(filePath)"
        }
    }
}
```

- [ ] **Step 4: Run the Swift catalog tests**

Run:

```bash
swift test --filter IncrementalBackupCatalogTests
```

Expected: PASS.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift
git commit -m "feat: add incremental backup restore catalog"
```

---

### Task 2: macOS Restore Operation and Model State

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`

**Interfaces:**
- Consumes: `IncrementalBackupCatalog`, `BackupRecoveryBuilder.buildRecoveryPackage(sessionIDs:)`
- Produces:
  - `SnapshotRestoreSource` helper inside `main.swift`
  - `VaultWorkerCommand.Operation.restoreIncrementalBackupSessions`
  - `VaultModel.loadIncrementalBackupCandidates()`
  - `VaultModel.restoreSelectedIncrementalBackupSessions()`

- [ ] **Step 1: Add a focused builder regression test**

Append to `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`:

```swift
@Test
func recoveryPackageOnlyContainsRequestedSessionFiles() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    try fixture.writeBackup(relativePath: "sessions/2026/07/08/a.jsonl", contents: #"{"role":"user","content":"A"}"# + "\n")
    try fixture.writeBackup(relativePath: "sessions/2026/07/08/b.jsonl", contents: #"{"role":"user","content":"B"}"# + "\n")
    try fixture.saveManifest(records: [
        fixture.makeRecord(sessionID: "a", backupPath: "sessions/2026/07/08/a.jsonl", title: "A"),
        fixture.makeRecord(sessionID: "b", backupPath: "sessions/2026/07/08/b.jsonl", title: "B")
    ])

    let package = try BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now }).buildRecoveryPackage(sessionIDs: ["b"])

    let recoveredRoot = package.dataURL.appendingPathComponent("sessions/recovered", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent("b.jsonl").path))
    #expect(!FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent("a.jsonl").path))
    let entries = try readSessionIndex(at: package.sessionIndexURL)
    #expect(entries.map(\.id) == ["b"])
}
```

- [ ] **Step 2: Run the builder regression test**

Run:

```bash
swift test --filter BackupRecoveryBuilderTests/recoveryPackageOnlyContainsRequestedSessionFiles
```

Expected: PASS. The assertion locks `BackupRecoveryBuilder.buildRecoveryPackage(sessionIDs:)` to selected-only package output.

- [ ] **Step 3: Add macOS model state**

Modify `Sources/CodexSessionVault/main.swift`:

```swift
enum SnapshotRestoreSource: String, CaseIterable, Identifiable {
    case snapshots = "快照"
    case incrementalBackups = "备份恢复"

    var id: String { rawValue }
}
```

Add to `VaultModel` published state:

```swift
@Published var snapshotRestoreSource: SnapshotRestoreSource = .snapshots
@Published var incrementalBackupCandidates: [IncrementalRestoreCandidate] = []
@Published var selectedIncrementalBackupID: IncrementalRestoreCandidate.ID?
@Published var checkedIncrementalBackupIDs: Set<IncrementalRestoreCandidate.ID> = []
@Published var incrementalBackupSearch = ""
@Published var showExistingIncrementalBackups = false
@Published var incrementalBackupCatalogSummary: IncrementalBackupCatalogResult?
```

Add computed properties:

```swift
var filteredIncrementalBackupCandidates: [IncrementalRestoreCandidate] {
    let query = incrementalBackupSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return incrementalBackupCandidates.filter { candidate in
        guard showExistingIncrementalBackups || candidate.status == .missing || candidate.status == .backupFileMissing || candidate.status == .invalidBackup else {
            return false
        }
        guard !query.isEmpty else { return true }
        return [
            candidate.sessionId,
            candidate.title,
            candidate.sourcePath,
            candidate.backupPath,
            candidate.error ?? ""
        ].contains { $0.lowercased().contains(query) }
    }
}

var checkedRestorableIncrementalBackups: [IncrementalRestoreCandidate] {
    incrementalBackupCandidates.filter { checkedIncrementalBackupIDs.contains($0.id) && $0.isRestorable }
}
```

- [ ] **Step 4: Add macOS catalog loading methods**

Add to `VaultModel`:

```swift
func refreshIncrementalBackupCandidates() {
    do {
        let paths = localBackupPaths ?? BackupPaths(
            codexRoot: URL(fileURLWithPath: codexRoot, isDirectory: true),
            backupRoot: URL(fileURLWithPath: vaultRoot, isDirectory: true)
                .appendingPathComponent("incremental-backups", isDirectory: true)
        )
        let currentIDs = Set((try loadSessions()).map(\.id))
        let result = try IncrementalBackupCatalog(paths: paths).load(currentSessionIDs: currentIDs)
        incrementalBackupCatalogSummary = result
        incrementalBackupCandidates = result.candidates
        checkedIncrementalBackupIDs = checkedIncrementalBackupIDs.intersection(Set(result.candidates.map(\.id)))
        if let selectedIncrementalBackupID,
           filteredIncrementalBackupCandidates.contains(where: { $0.id == selectedIncrementalBackupID }) {
            return
        }
        selectedIncrementalBackupID = filteredIncrementalBackupCandidates.first?.id
    } catch {
        incrementalBackupCatalogSummary = nil
        incrementalBackupCandidates = []
        selectedIncrementalBackupID = nil
        checkedIncrementalBackupIDs.removeAll()
        lastError = "读取增量备份失败：\(error.localizedDescription)"
    }
}

func toggleCheckedIncrementalBackup(_ candidate: IncrementalRestoreCandidate) {
    if checkedIncrementalBackupIDs.contains(candidate.id) {
        checkedIncrementalBackupIDs.remove(candidate.id)
    } else if candidate.isRestorable {
        checkedIncrementalBackupIDs.insert(candidate.id)
        selectedIncrementalBackupID = candidate.id
    }
}

func checkAllVisibleIncrementalBackups() {
    checkedIncrementalBackupIDs.formUnion(filteredIncrementalBackupCandidates.filter(\.isRestorable).map(\.id))
}

func clearCheckedIncrementalBackups() {
    checkedIncrementalBackupIDs.removeAll()
}
```

- [ ] **Step 5: Add the worker operation**

Modify `VaultWorkerCommand.Operation`:

```swift
case restoreIncrementalBackupSessions
```

Add a switch case inside `performWorkerCommand`:

```swift
case .restoreIncrementalBackupSessions:
    let selectedIDs = Set(command.sessions.map(\.id))
    guard !selectedIDs.isEmpty else {
        throw VaultError.commandFailed("没有选择要从备份恢复的会话。")
    }
    let backupRoot = URL(fileURLWithPath: command.vaultRoot, isDirectory: true)
        .appendingPathComponent("incremental-backups", isDirectory: true)
    let paths = BackupPaths(
        codexRoot: URL(fileURLWithPath: command.codexRoot, isDirectory: true),
        backupRoot: backupRoot
    )
    let currentIDs = Set((try? loadSessions().map(\.id)) ?? [])
    let catalog = try IncrementalBackupCatalog(paths: paths).load(currentSessionIDs: currentIDs)
    let restorableIDs = catalog.candidates
        .filter { selectedIDs.contains($0.sessionId) && $0.status == .missing }
        .map(\.sessionId)
    guard !restorableIDs.isEmpty else {
        throw VaultError.commandFailed("选中的备份会话都已存在或不可恢复。")
    }

    try report(0.08, "正在创建备份恢复前保护点...", "正在保护当前 Codex 会话状态。")
    _ = try createSystemSnapshot(
        name: "Pre-Incremental-Backup-Restore Backup",
        reason: "pre-incremental-backup-restore",
        candidatePaths: autoProtectionCandidates
    )

    try report(0.36, "正在生成增量备份恢复包...", "只打包当前缺失且被选中的会话。")
    let package = try BackupRecoveryBuilder(paths: paths).buildRecoveryPackage(sessionIDs: restorableIDs)

    try report(0.62, "正在恢复缺失会话...", "正在复制 recovered 会话文件并合并 session_index.jsonl。")
    let root = URL(fileURLWithPath: command.codexRoot, isDirectory: true)
    try restoreConversationsOnly(
        from: package.dataURL,
        to: root,
        includedPaths: ["session_index.jsonl", "sessions"],
        snapshotCodexRoot: command.codexRoot
    )
    try report(1.0, "备份恢复完成", "已恢复 \(restorableIDs.count) 个缺失会话。SQLite 索引缺失时，Codex 重启后会重新读取文件和索引。")
    return .ok(message: "已从本地增量备份恢复 \(restorableIDs.count) 个缺失会话。请重启 Codex 后查看。")
```

- [ ] **Step 6: Add macOS restore action**

Add to `VaultModel`:

```swift
func restoreSelectedIncrementalBackupSessions() {
    let candidates = checkedRestorableIncrementalBackups.isEmpty
        ? incrementalBackupCandidates.filter { $0.id == selectedIncrementalBackupID && $0.isRestorable }
        : checkedRestorableIncrementalBackups
    guard !candidates.isEmpty else {
        lastError = "没有可恢复的缺失会话。"
        return
    }
    let preview = candidates.prefix(8).map(\.title).joined(separator: "\n")
    guard confirm(
        title: "从本地备份恢复缺失会话？",
        message: "将恢复 \(candidates.count) 个当前 Codex 中缺失的会话，不覆盖已存在会话。\n\n\(preview)"
    ) else {
        return
    }
    let sessions = candidates.map {
        CodexSession(
            id: $0.sessionId,
            title: $0.title,
            rolloutPath: $0.sourcePath,
            cwd: "",
            modelProvider: "unknown",
            model: "unknown",
            source: "incremental-backup",
            createdAt: $0.firstSeenAt,
            updatedAt: $0.lastBackedUpAt ?? $0.firstSeenAt,
            archived: false,
            sizeBytes: $0.bytesBackedUp,
            existsOnDisk: false
        )
    }
    let command = VaultWorkerCommand(
        operation: .restoreIncrementalBackupSessions,
        codexRoot: codexRoot,
        vaultRoot: vaultRoot,
        sessions: sessions
    )
    Task {
        await runWorker("正在从本地备份恢复缺失会话...", command: command) { response in
            self.checkedIncrementalBackupIDs.removeAll()
            self.refresh()
            self.refreshIncrementalBackupCandidates()
            self.selectedSection = .snapshots
            self.status = response.message
            self.inform(title: "备份恢复完成", message: "\(response.message)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。")
        }
    }
}
```

- [ ] **Step 7: Run targeted Swift checks**

Run:

```bash
swift test --filter IncrementalBackupCatalogTests
swift test --filter BackupRecoveryBuilderTests
```

Expected: PASS.

- [ ] **Step 8: Commit Task 2**

Run:

```bash
git add Sources/CodexSessionVault/main.swift Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift
git commit -m "feat: restore missing sessions from incremental backups on macos"
```

---

### Task 3: macOS Backup Restore UI

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`

**Interfaces:**
- Consumes: `VaultModel.filteredIncrementalBackupCandidates`, `VaultModel.restoreSelectedIncrementalBackupSessions()`
- Produces:
  - `IncrementalBackupRestoreCard`
  - Backup source segmented picker in `SnapshotPane`

- [ ] **Step 1: Add the source picker to `SnapshotPane`**

In `SnapshotPane.body`, above the current snapshot list controls, add:

```swift
Picker("恢复来源", selection: $model.snapshotRestoreSource) {
    ForEach(SnapshotRestoreSource.allCases) { source in
        Text(source.rawValue).tag(source)
    }
}
.pickerStyle(.segmented)
.frame(width: 220)
.onChange(of: model.snapshotRestoreSource) { _, source in
    if source == .incrementalBackups {
        model.refreshIncrementalBackupCandidates()
    }
}
```

- [ ] **Step 2: Split snapshot and backup body rendering**

In `SnapshotPane`, branch the leading and trailing content:

```swift
if model.snapshotRestoreSource == .snapshots {
    snapshotListContent
} else {
    IncrementalBackupRestoreCard()
}
```

Keep existing snapshot UI inside `snapshotListContent` so snapshot behavior does not change.

- [ ] **Step 3: Add `IncrementalBackupRestoreCard`**

Add a new SwiftUI view in `main.swift` near `SnapshotSessionRestoreCard`:

```swift
struct IncrementalBackupRestoreCard: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("备份恢复")
                        .font(.title2.bold())
                    Text("只恢复当前 Codex 中缺失的会话，已存在会话不会覆盖。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CountBadge(value: "\(model.incrementalBackupCatalogSummary?.missingCount ?? 0) 缺失")
            }

            HStack(spacing: 10) {
                TextField("搜索标题、路径、ID", text: $model.incrementalBackupSearch)
                    .textFieldStyle(.roundedBorder)
                Toggle("显示已存在", isOn: $model.showExistingIncrementalBackups)
                    .toggleStyle(.checkbox)
                Button("刷新备份") { model.refreshIncrementalBackupCandidates() }
                Button("全选缺失") { model.checkAllVisibleIncrementalBackups() }
                    .disabled(model.filteredIncrementalBackupCandidates.filter(\.isRestorable).isEmpty)
                if !model.checkedIncrementalBackupIDs.isEmpty {
                    Button("清空选择") { model.clearCheckedIncrementalBackups() }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.filteredIncrementalBackupCandidates) { candidate in
                        HStack(spacing: 10) {
                            Button {
                                model.toggleCheckedIncrementalBackup(candidate)
                            } label: {
                                Image(systemName: model.checkedIncrementalBackupIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(!candidate.isRestorable)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text("\(candidate.sessionId) · \(candidate.backupPath)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(incrementalStatusLabel(candidate.status))
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(candidate.isRestorable ? .green.opacity(0.14) : .gray.opacity(0.14), in: Capsule())
                        }
                        .padding(10)
                        .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture {
                            model.selectedIncrementalBackupID = candidate.id
                        }
                    }
                }
            }

            HStack {
                Text("已选 \(model.checkedRestorableIncrementalBackups.count) 个可恢复会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.checkedRestorableIncrementalBackups.isEmpty ? "恢复高亮缺失会话" : "恢复选中缺失会话") {
                    model.restoreSelectedIncrementalBackupSessions()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || (model.checkedRestorableIncrementalBackups.isEmpty && model.selectedIncrementalBackupID == nil))
            }
        }
        .onAppear {
            model.refreshIncrementalBackupCandidates()
        }
    }

    private func incrementalStatusLabel(_ status: IncrementalRestoreStatus) -> String {
        switch status {
        case .missing: return "可恢复"
        case .existing: return "已存在"
        case .invalidBackup: return "备份异常"
        case .backupFileMissing: return "文件缺失"
        }
    }
}
```

- [ ] **Step 4: Run macOS build**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add Sources/CodexSessionVault/main.swift
git commit -m "feat: add macos backup restore UI"
```

---

### Task 4: Windows Incremental Recovery Module

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/incremental-recovery.js`
- Create: `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`

**Interfaces:**
- Consumes: `backupPaths`, `manifest.json`
- Produces:
  - `loadIncrementalBackupCatalog({ paths, currentSessionIds })`
  - `buildIncrementalRecoveryPackage({ paths, sessionIds, now })`

- [ ] **Step 1: Write the failing Node tests**

Create `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`:

```javascript
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  buildIncrementalRecoveryPackage,
  loadIncrementalBackupCatalog,
} = require('../../src/backup/incremental-recovery');

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'incremental-recovery-'));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  const paths = {
    codexRoot: path.join(root, '.codex'),
    backupRoot: path.join(root, 'vault', 'incremental-backups'),
    manifestPath: path.join(root, 'vault', 'incremental-backups', 'manifest.json'),
  };
  await fs.mkdir(paths.backupRoot, { recursive: true });
  return { root, paths };
}

async function writeManifest(paths, sessions) {
  await fs.writeFile(paths.manifestPath, JSON.stringify({
    version: 1,
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    createdAt: '2026-07-08T12:00:00.000Z',
    updatedAt: '2026-07-08T12:05:00.000Z',
    sessions,
  }, null, 2), 'utf8');
}

function record(sessionId, backupPath, title = sessionId) {
  return {
    sessionId,
    sourcePath: `C:\\Users\\Ada\\.codex\\sessions\\${sessionId}.jsonl`,
    backupPath,
    title,
    firstSeenAt: '2026-07-08T12:00:00.000Z',
    lastBackedUpAt: '2026-07-08T12:05:00.000Z',
    lineCount: 1,
    bytesBackedUp: 32,
    status: 'active',
  };
}

test('catalog classifies missing and existing backup sessions', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'missing.jsonl'), '{"role":"user"}\n');
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'existing.jsonl'), '{"role":"user"}\n');
  await writeManifest(paths, {
    missing: record('missing', path.join('sessions', '2026', '07', '08', 'missing.jsonl'), 'missing title'),
    existing: record('existing', path.join('sessions', '2026', '07', '08', 'existing.jsonl'), 'existing title'),
  });

  const result = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set(['existing']) });

  assert.equal(result.totalCount, 2);
  assert.equal(result.missingCount, 1);
  assert.equal(result.existingCount, 1);
  assert.equal(result.candidates.find((item) => item.sessionId === 'missing').status, 'missing');
  assert.equal(result.candidates.find((item) => item.sessionId === 'existing').status, 'existing');
});

test('catalog rejects path traversal and package only copies selected sessions', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'selected.jsonl'), '{"role":"user","content":"selected"}\n');
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'other.jsonl'), '{"role":"user","content":"other"}\n');
  await writeManifest(paths, {
    selected: record('selected', path.join('sessions', '2026', '07', '08', 'selected.jsonl'), 'selected'),
    other: record('other', path.join('sessions', '2026', '07', '08', 'other.jsonl'), 'other'),
    bad: record('bad', '..\\outside.jsonl', 'bad'),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });
  assert.equal(catalog.candidates.find((item) => item.sessionId === 'bad').status, 'invalidBackup');

  const recovery = await buildIncrementalRecoveryPackage({
    paths,
    sessionIds: ['selected'],
    now: () => new Date('2026-07-08T12:30:00.000Z'),
  });

  assert.equal(await fs.readFile(path.join(recovery.dataPath, 'sessions', 'recovered', 'selected.jsonl'), 'utf8'), '{"role":"user","content":"selected"}\n');
  await assert.rejects(
    fs.access(path.join(recovery.dataPath, 'sessions', 'recovered', 'other.jsonl')),
    /ENOENT/
  );
  const indexText = await fs.readFile(path.join(recovery.dataPath, 'session_index.jsonl'), 'utf8');
  assert.match(indexText, /"id":"selected"/);
  assert.doesNotMatch(indexText, /"id":"other"/);
});
```

- [ ] **Step 2: Run the failing Node tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test -- --test-name-pattern=incremental
```

Expected: FAIL because `src/backup/incremental-recovery.js` does not exist.

- [ ] **Step 3: Implement `incremental-recovery.js`**

Create `windows/codex_session_manager_electron/src/backup/incremental-recovery.js` with exports:

```javascript
const fs = require('fs/promises');
const path = require('path');

function safePathComponent(value) {
  const safe = String(value || '').replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
  return safe || 'session';
}

async function exists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function resolveBackupFile(paths, record) {
  const backupPath = String(record.backupPath || '');
  if (!backupPath) throw new Error(`Backup path for session ${record.sessionId} is empty`);
  if (path.isAbsolute(backupPath)) throw new Error(`Backup path for session ${record.sessionId} is absolute: ${backupPath}`);
  const parts = backupPath.split(/[\\/]+/);
  if (parts.some((part) => !part || part === '.')) throw new Error(`Backup path for session ${record.sessionId} is not normalized: ${backupPath}`);
  if (parts.includes('..')) throw new Error(`Backup path for session ${record.sessionId} escapes backup root: ${backupPath}`);
  const filePath = path.join(paths.backupRoot, ...parts);
  const root = path.resolve(paths.backupRoot);
  const resolved = path.resolve(filePath);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    throw new Error(`Backup path for session ${record.sessionId} escapes backup root: ${backupPath}`);
  }
  return filePath;
}

async function readManifest(paths) {
  const text = await fs.readFile(paths.manifestPath, 'utf8');
  return JSON.parse(text);
}

async function loadIncrementalBackupCatalog({ paths, currentSessionIds }) {
  const manifest = await readManifest(paths);
  const current = currentSessionIds || new Set();
  const candidates = [];
  for (const record of Object.values(manifest.sessions || {})) {
    let backupFilePath = '';
    let status = current.has(record.sessionId) ? 'existing' : 'missing';
    let error = null;
    try {
      backupFilePath = resolveBackupFile(paths, record);
      if (!await exists(backupFilePath)) {
        status = 'backupFileMissing';
        error = `Backup file is missing for session ${record.sessionId}: ${backupFilePath}`;
      }
    } catch (caught) {
      status = 'invalidBackup';
      error = caught.message || String(caught);
    }
    candidates.push({
      id: record.sessionId,
      sessionId: record.sessionId,
      title: String(record.title || record.sessionId),
      sourcePath: String(record.sourcePath || ''),
      backupPath: String(record.backupPath || ''),
      backupFilePath,
      firstSeenAt: record.firstSeenAt,
      lastBackedUpAt: record.lastBackedUpAt,
      lineCount: Number(record.lineCount || 0),
      bytesBackedUp: Number(record.bytesBackedUp || 0),
      status,
      isRestorable: status === 'missing',
      error,
    });
  }
  candidates.sort((a, b) => new Date(b.lastBackedUpAt || b.firstSeenAt) - new Date(a.lastBackedUpAt || a.firstSeenAt));
  return {
    backupRoot: paths.backupRoot,
    updatedAt: manifest.updatedAt || null,
    totalCount: candidates.length,
    missingCount: candidates.filter((item) => item.status === 'missing').length,
    existingCount: candidates.filter((item) => item.status === 'existing').length,
    errorCount: candidates.filter((item) => item.status === 'invalidBackup' || item.status === 'backupFileMissing').length,
    candidates,
  };
}

async function buildIncrementalRecoveryPackage({ paths, sessionIds, now = () => new Date() }) {
  const manifest = await readManifest(paths);
  const selected = new Set((sessionIds || []).map(String));
  const records = Object.values(manifest.sessions || {})
    .filter((record) => selected.has(record.sessionId))
    .sort((a, b) => String(a.sessionId).localeCompare(String(b.sessionId)));
  if (!records.length) throw new Error('No requested sessions were found in the backup manifest.');

  const stamp = now().toISOString().replace(/[:.]/g, '-');
  const packagePath = path.join(paths.backupRoot, 'recovery-packages', `incremental-recovery-${stamp}`);
  const dataPath = path.join(packagePath, 'data');
  const recoveredRoot = path.join(dataPath, 'sessions', 'recovered');
  await fs.mkdir(recoveredRoot, { recursive: true });

  const includedPaths = ['session_index.jsonl', 'sessions'];
  const indexLines = [];
  for (const record of records) {
    const backupFilePath = resolveBackupFile(paths, record);
    const filename = `${safePathComponent(record.sessionId)}.jsonl`;
    const relativePath = path.join('sessions', 'recovered', filename);
    await fs.copyFile(backupFilePath, path.join(recoveredRoot, filename));
    includedPaths.push(relativePath.split(path.sep).join('/'));
    indexLines.push(JSON.stringify({
      id: record.sessionId,
      title: record.title || record.sessionId,
      thread_name: record.title || record.sessionId,
      rollout_path: path.join(paths.codexRoot, 'sessions', 'recovered', filename),
      source_path: record.sourcePath || '',
      backup_path: record.backupPath || '',
      updated_at: record.lastBackedUpAt || record.firstSeenAt,
      line_count: record.lineCount || 0,
      bytes_backed_up: record.bytesBackedUp || 0,
    }));
  }
  await fs.writeFile(path.join(dataPath, 'session_index.jsonl'), `${indexLines.join('\n')}\n`, 'utf8');
  const snapshot = {
    id: path.basename(packagePath),
    name: `Incremental Recovery ${now().toISOString()}`,
    createdAt: now().toISOString(),
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    reason: 'incremental-recovery',
    kind: 'system',
    modelProvider: 'unknown',
    model: 'unknown',
    accountFingerprint: 'none',
    sessionCount: records.length,
    archivedSessionCount: 0,
    sizeBytes: records.reduce((sum, record) => sum + Number(record.bytesBackedUp || 0), 0),
    includedPaths: includedPaths.sort(),
    appVersion: '1.0.13',
  };
  await fs.writeFile(path.join(packagePath, 'snapshot.json'), JSON.stringify(snapshot, null, 2), 'utf8');
  return { path: packagePath, dataPath, ...snapshot };
}

module.exports = {
  buildIncrementalRecoveryPackage,
  loadIncrementalBackupCatalog,
  resolveBackupFile,
};
```

- [ ] **Step 4: Run Node incremental tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test -- --test-name-pattern=incremental
```

Expected: PASS.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add windows/codex_session_manager_electron/src/backup/incremental-recovery.js windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js
git commit -m "feat: add windows incremental backup recovery module"
```

---

### Task 5: Windows IPC and Renderer UI

**Files:**
- Modify: `windows/codex_session_manager_electron/src/main.js`
- Modify: `windows/codex_session_manager_electron/src/preload.js`
- Modify: `windows/codex_session_manager_electron/src/index.html`
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
- Modify: `windows/codex_session_manager_electron/src/styles.css`

**Interfaces:**
- Consumes: `loadIncrementalBackupCatalog`, `buildIncrementalRecoveryPackage`
- Produces:
  - IPC `load-incremental-backup-sessions`
  - IPC `restore-incremental-backup-sessions`
  - Renderer state for `backupRestoreCandidates`

- [ ] **Step 1: Wire IPC in `preload.js`**

Add:

```javascript
loadIncrementalBackupSessions: () => ipcRenderer.invoke('load-incremental-backup-sessions'),
restoreIncrementalBackupSessions: (sessionIds, protectionMode) => ipcRenderer.invoke('restore-incremental-backup-sessions', sessionIds, protectionMode),
```

- [ ] **Step 2: Add main-process imports and handlers**

In `src/main.js`, add:

```javascript
const {
  buildIncrementalRecoveryPackage,
  loadIncrementalBackupCatalog,
} = require('./backup/incremental-recovery');
```

Add helper:

```javascript
async function currentSessionIds() {
  return new Set((await loadSessions()).map((session) => session.id));
}
```

Add IPC handlers:

```javascript
ipcMain.handle('load-incremental-backup-sessions', async () => {
  return loadIncrementalBackupCatalog({
    paths: localBackupPaths,
    currentSessionIds: await currentSessionIds(),
  });
});

ipcMain.handle('restore-incremental-backup-sessions', async (_event, sessionIds, protectionMode = 'lightweight') => {
  const selectedIds = new Set(Array.isArray(sessionIds) ? sessionIds.map(String) : []);
  if (!selectedIds.size) throw new Error('没有选择要从备份恢复的会话。');
  const catalog = await loadIncrementalBackupCatalog({
    paths: localBackupPaths,
    currentSessionIds: await currentSessionIds(),
  });
  const restorableIds = catalog.candidates
    .filter((candidate) => selectedIds.has(candidate.sessionId) && candidate.status === 'missing')
    .map((candidate) => candidate.sessionId);
  if (!restorableIds.length) throw new Error('选中的备份会话都已存在或不可恢复。');

  await createRestoreProtectionSnapshot(
    normalizeRestoreProtectionMode(protectionMode) === 'lightweight'
      ? 'Pre-Incremental-Backup-Restore Lightweight Backup'
      : 'Pre-Incremental-Backup-Restore Backup',
    normalizeRestoreProtectionMode(protectionMode) === 'lightweight'
      ? 'pre-incremental-backup-restore-lightweight'
      : 'pre-incremental-backup-restore',
    protectionMode,
    await loadSessions(),
    conversationBackupCandidates
  );

  const recovery = await buildIncrementalRecoveryPackage({
    paths: localBackupPaths,
    sessionIds: restorableIds,
  });
  const sqliteMessage = await restoreConversationsOnly({
    ...recovery,
    includedPaths: ['session_index.jsonl', 'sessions'],
  });
  return {
    ok: true,
    restoredCount: restorableIds.length,
    message: `已从本地增量备份恢复 ${restorableIds.length} 个缺失会话。${sqliteMessage} 请重启 Codex 后查看。`,
  };
});
```

- [ ] **Step 3: Add renderer state**

In `renderer.js` state:

```javascript
snapshotSource: 'snapshots',
backupRestoreCatalog: null,
backupRestoreCandidates: [],
backupRestoreSearch: '',
showExistingBackupRestore: false,
checkedBackupRestoreIds: new Set(),
selectedBackupRestoreId: null,
backupRestoreLoading: false,
```

Add helpers:

```javascript
function filteredBackupRestoreCandidates() {
  const query = state.backupRestoreSearch.trim().toLowerCase();
  return state.backupRestoreCandidates.filter((candidate) => {
    if (!state.showExistingBackupRestore && candidate.status === 'existing') return false;
    if (!query) return true;
    return [
      candidate.sessionId,
      candidate.title,
      candidate.sourcePath,
      candidate.backupPath,
      candidate.error || ''
    ].join(' ').toLowerCase().includes(query);
  });
}

function checkedRestorableBackupRestoreCandidates() {
  return state.backupRestoreCandidates.filter((candidate) => state.checkedBackupRestoreIds.has(candidate.sessionId) && candidate.isRestorable);
}
```

- [ ] **Step 4: Add renderer load and restore actions**

Add:

```javascript
async function loadBackupRestoreCatalog() {
  state.backupRestoreLoading = true;
  renderSnapshots();
  try {
    const catalog = await window.codexManager.loadIncrementalBackupSessions();
    state.backupRestoreCatalog = catalog;
    state.backupRestoreCandidates = catalog.candidates || [];
    state.checkedBackupRestoreIds = new Set([...state.checkedBackupRestoreIds].filter((id) => state.backupRestoreCandidates.some((item) => item.sessionId === id)));
    state.selectedBackupRestoreId = filteredBackupRestoreCandidates()[0]?.sessionId || null;
  } catch (error) {
    showToast(error.message || String(error), true);
    state.backupRestoreCatalog = null;
    state.backupRestoreCandidates = [];
    state.checkedBackupRestoreIds.clear();
    state.selectedBackupRestoreId = null;
  } finally {
    state.backupRestoreLoading = false;
    renderSnapshots();
  }
}

async function restoreBackupRestoreCandidates() {
  const checked = checkedRestorableBackupRestoreCandidates();
  const selected = state.backupRestoreCandidates.find((candidate) => candidate.sessionId === state.selectedBackupRestoreId && candidate.isRestorable);
  const candidates = checked.length ? checked : (selected ? [selected] : []);
  if (!candidates.length) {
    showToast('没有可恢复的缺失会话。', true);
    return;
  }
  const preview = candidates.slice(0, 8).map((candidate) => candidate.title || candidate.sessionId).join('\n');
  const suffix = candidates.length > 8 ? `\n等 ${candidates.length} 个会话` : '';
  const protectionMode = await chooseRestoreProtectionMode(
    '从本地备份恢复缺失会话？',
    `将恢复 ${candidates.length} 个当前 Codex 中缺失的会话，不覆盖已存在会话。\n\n${preview}${suffix}`,
    'lightweight'
  );
  if (!protectionMode) return;
  const result = await withBusy('正在从本地备份恢复缺失会话...', () => window.codexManager.restoreIncrementalBackupSessions(candidates.map((candidate) => candidate.sessionId), protectionMode));
  if (busyWasCancelled(result)) return;
  state.checkedBackupRestoreIds.clear();
  showRestoreComplete(result.message || '备份恢复完成');
  await refresh({ skipAutoRestore: true });
  await loadBackupRestoreCatalog();
  setSection('snapshots');
}
```

- [ ] **Step 5: Render the Windows backup restore UI**

In `renderSnapshots()`, if `state.snapshotSource === 'backupRestore'`, render a backup restore list instead of `state.snapshots`. Add a source control in `index.html`:

```html
<select id="snapshotSource" class="search-input compact-select">
  <option value="snapshots">快照</option>
  <option value="backupRestore">备份恢复</option>
</select>
```

Add to `els`:

```javascript
snapshotSource: $('#snapshotSource'),
```

Render rows:

```javascript
function backupRestoreStatusLabel(status) {
  if (status === 'missing') return '可恢复';
  if (status === 'existing') return '已存在';
  if (status === 'backupFileMissing') return '文件缺失';
  return '备份异常';
}
```

Use row markup:

```javascript
const rows = filteredBackupRestoreCandidates().map((candidate) => `
  <article class="snapshot-row backup-restore-row ${candidate.sessionId === state.selectedBackupRestoreId ? 'selected' : ''}" data-backup-restore-id="${escapeHtml(candidate.sessionId)}">
    <button class="row-check ${state.checkedBackupRestoreIds.has(candidate.sessionId) ? 'checked' : ''}" data-check-backup-restore="${escapeHtml(candidate.sessionId)}" ${candidate.isRestorable ? '' : 'disabled'}>✓</button>
    <div class="row-content">
      <div class="row-title">${escapeHtml(candidate.title || candidate.sessionId)} <span class="tag ${candidate.isRestorable ? 'manual' : 'archive'}">${backupRestoreStatusLabel(candidate.status)}</span></div>
      <div class="row-meta">${escapeHtml(candidate.sessionId)} · ${formatBytes(candidate.bytesBackedUp)}</div>
      <div class="row-time">${formatDate(candidate.lastBackedUpAt || candidate.firstSeenAt)}</div>
    </div>
  </article>
`).join('');
```

Render the detail panel with:

```javascript
function renderBackupRestoreDetail(candidate) {
  if (!candidate) {
    els.snapshotDetail.className = 'detail-empty';
    els.snapshotDetail.innerHTML = '<div class="empty-icon">↺</div><h3>没有选中备份会话</h3><p>选择一个缺失会话后可从本地增量备份恢复。</p>';
    return;
  }
  const checked = checkedRestorableBackupRestoreCandidates();
  els.snapshotDetail.className = '';
  els.snapshotDetail.innerHTML = `
    <div class="detail-card">
      <div class="detail-title-row">
        <div class="detail-title-copy">
          <h2 class="detail-title">${escapeHtml(candidate.title || candidate.sessionId)}</h2>
          <p class="mono">${escapeHtml(candidate.sessionId)}</p>
        </div>
        <span class="count-pill">${backupRestoreStatusLabel(candidate.status)}</span>
      </div>
    </div>
    <div class="primary-action-card">
      <div class="action-row wrap">
        <button class="primary-button" data-backup-restore-action="restoreSelected" ${candidate.isRestorable || checked.length ? '' : 'disabled'}>${checked.length ? `恢复选中 ${checked.length}` : '恢复这个缺失会话'}</button>
        <button class="ghost-button" data-backup-restore-action="refresh">刷新备份</button>
      </div>
      <p>只恢复当前 Codex 中缺失的会话，已存在会话不会覆盖。恢复完成后请重启 Codex。</p>
    </div>
    <div class="detail-card">
      <h3 style="margin-bottom: 12px;">备份信息</h3>
      <div class="info-lines">
        <div class="info-line"><span>备份文件</span><strong class="mono">${escapeHtml(candidate.backupPath || '-')}</strong></div>
        <div class="info-line"><span>原始路径</span><strong class="mono">${escapeHtml(candidate.sourcePath || '-')}</strong></div>
        <div class="info-line"><span>最近备份</span><strong>${formatDate(candidate.lastBackedUpAt || candidate.firstSeenAt)}</strong></div>
        <div class="info-line"><span>行数</span><strong>${candidate.lineCount || 0}</strong></div>
      </div>
    </div>
  `;
}
```

- [ ] **Step 6: Add event handlers**

In the document click handler:

```javascript
const backupRestoreCheck = event.target.closest('[data-check-backup-restore]');
if (backupRestoreCheck) {
  const id = backupRestoreCheck.dataset.checkBackupRestore;
  if (state.checkedBackupRestoreIds.has(id)) state.checkedBackupRestoreIds.delete(id);
  else state.checkedBackupRestoreIds.add(id);
  renderSnapshots();
  return;
}

const backupRestoreRow = event.target.closest('[data-backup-restore-id]');
if (backupRestoreRow) {
  state.selectedBackupRestoreId = backupRestoreRow.dataset.backupRestoreId;
  renderSnapshots();
}

const backupRestoreAction = event.target.closest('[data-backup-restore-action]');
if (backupRestoreAction) {
  if (backupRestoreAction.dataset.backupRestoreAction === 'refresh') await loadBackupRestoreCatalog();
  if (backupRestoreAction.dataset.backupRestoreAction === 'restoreSelected') await restoreBackupRestoreCandidates();
}
```

For source select:

```javascript
els.snapshotSource.addEventListener('change', async () => {
  state.snapshotSource = els.snapshotSource.value;
  if (state.snapshotSource === 'backupRestore') await loadBackupRestoreCatalog();
  renderSnapshots();
});
```

- [ ] **Step 7: Run Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: PASS.

- [ ] **Step 8: Commit Task 5**

Run:

```bash
git add windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/src/preload.js windows/codex_session_manager_electron/src/index.html windows/codex_session_manager_electron/src/renderer.js windows/codex_session_manager_electron/src/styles.css
git commit -m "feat: add windows backup restore UI"
```

---

### Task 6: Documentation, Full Verification, and Build Packaging

**Files:**
- Modify: `docs/操作手册.md`

**Interfaces:**
- Consumes: completed macOS and Windows restore behavior
- Produces: documented test and recovery flow

- [ ] **Step 1: Update user documentation**

Add a section to `docs/操作手册.md`:

```markdown
## 从本地增量备份恢复丢失会话

适用场景：Codex 会话列表或会话文件丢失，但本地增量备份仍存在。

操作步骤：

1. 关闭 Codex 桌面端。
2. 打开 `codex_会话管理`。
3. 进入 `快照恢复`。
4. 切换到 `备份恢复`。
5. 默认列表只显示当前 Codex 中缺失的会话。
6. 选择一个或多个 `可恢复` 会话。
7. 点击恢复。
8. 等待恢复前保护点和恢复流程完成。
9. 重启 Codex 桌面端。

恢复规则：

- 只恢复缺失会话。
- 已存在会话不会覆盖。
- 恢复内容包括 `.jsonl` 会话文件和 `session_index.jsonl` 索引。
- `state_5.sqlite` 只做尽力合并；如果没有可用 SQLite 记录，恢复仍可完成。
- 不恢复账号、登录态、配置文件和凭据。
```

- [ ] **Step 2: Run full Swift tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 3: Run full Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: PASS.

- [ ] **Step 4: Run macOS app build**

Run:

```bash
./scripts/build_app.sh
```

Expected: exits 0 and writes the macOS app bundle under the project build/dist path used by the script.

- [ ] **Step 5: Run Windows package build**

Run:

```bash
cd windows/codex_session_manager_electron
npm run package:win
```

Expected: exits 0 and updates `dist/win10-exe/codex_session_manager-win32-x64`.

- [ ] **Step 6: Manual macOS acceptance**

Run this manual flow:

```text
1. Start the app and confirm 本地增量备份 is running.
2. Create or pick a test Codex session with a known title.
3. Confirm its backup exists in ~/.codex-session-vault/incremental-backups/manifest.json.
4. Move the original ~/.codex session file out of the way.
5. Refresh codex_会话管理.
6. Open 快照恢复 -> 备份恢复.
7. Confirm the test session is listed as 可恢复.
8. Restore it.
9. Confirm ~/.codex/sessions/recovered/<session-id>.jsonl exists.
10. Restart Codex desktop and confirm the conversation is visible.
11. Return the moved original test file only if it is needed for local cleanup.
```

- [ ] **Step 7: Manual Windows acceptance**

Run this manual flow on Windows:

```text
1. Pull the updated repository.
2. Start the Electron app.
3. Confirm 本地增量备份 is running.
4. Pick a test session that has a backup in %USERPROFILE%\.codex-session-vault\incremental-backups\manifest.json.
5. Move the original session file out of %USERPROFILE%\.codex.
6. Open 快照恢复 -> 备份恢复.
7. Confirm the test session is listed as 可恢复.
8. Restore it.
9. Confirm %USERPROFILE%\.codex\sessions\recovered\<session-id>.jsonl exists.
10. Restart Codex desktop and confirm the conversation is visible.
```

- [ ] **Step 8: Commit Task 6**

Run:

```bash
git add docs/操作手册.md
git commit -m "docs: document incremental backup restore"
```

---

## Final Verification Gate

Before declaring the implementation complete, run:

```bash
swift test
cd windows/codex_session_manager_electron && npm test
./scripts/build_app.sh
cd windows/codex_session_manager_electron && npm run package:win
git status --short
```

Expected:

- Swift tests pass.
- Windows Node tests pass.
- macOS app build passes.
- Windows package build passes.
- `git status --short` contains no unintended source changes and does not include `.codegraph/`.

## Review Checklist

- A missing session can be restored from local incremental backup.
- An existing session is visible but disabled or skipped.
- Path traversal in manifest backup paths is rejected.
- Restore creates a protection point before writing.
- Restore writes recovered `.jsonl` under `sessions/recovered`.
- Restore merges `session_index.jsonl`.
- Restore does not require `state_5.sqlite`.
- Restore does not touch auth/config/credentials.
- macOS and Windows expose the same user-facing semantics.
- Existing snapshot restore and incremental backup tests still pass.

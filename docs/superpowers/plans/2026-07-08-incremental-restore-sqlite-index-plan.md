# Incremental Restore SQLite Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local incremental backup restore insert missing restored conversations into `state_5.sqlite.threads` so they appear in the newer Codex desktop conversation list.

**Architecture:** Keep the existing file restore path unchanged, then add a post-restore SQLite index repair step. The repair step is implemented as a small testable module on each platform: Swift Core for macOS, `src/backup` JS for Windows. It inserts only missing `threads` rows and never overwrites existing conversations.

**Tech Stack:** Swift 6, Swift Testing, `/usr/bin/sqlite3`, Electron main process, Node `node:test`, `sql.js`, existing CodexSessionKeeper backup/restore modules.

## Global Constraints

- Restore only sessions classified as missing by the incremental backup catalog.
- Do not overwrite existing `.jsonl`, `session_index.jsonl` rows, or `state_5.sqlite.threads` rows.
- SQLite index write failure must be visible as a warning, not silently swallowed.
- SQLite index write failure must not delete or roll back successfully restored `.jsonl` and `session_index.jsonl`.
- Do not restore `thread_spawn_edges`, `agent_jobs`, `agent_job_items`, `thread_dynamic_tools`, account state, login state, config, API keys, or credentials.
- Keep macOS and Windows semantics aligned.
- Do not restore the discarded macOS performance/style changes.
- Keep `.codegraph/` untracked and out of commits.

---

## File Structure

- Create `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift`
  - Owns Swift metadata extraction, SQLite schema probing, and missing `threads` row insertion.
  - Exposes a small public API used by the macOS executable.
- Create `Tests/CodexSessionVaultCoreTests/RecoveredThreadIndexTests.swift`
  - Covers Swift metadata extraction and SQLite insertion behavior.
- Modify `Sources/CodexSessionVault/main.swift`
  - Calls the Swift Core writer after incremental file restore.
  - Surfaces success/warning text in the user-facing restore result.
- Create `windows/codex_session_manager_electron/src/backup/recovered-thread-index.js`
  - Owns Windows metadata extraction and `sql.js` SQLite insertion.
- Create `windows/codex_session_manager_electron/test/backup/recovered-thread-index.test.js`
  - Covers Windows metadata extraction and SQLite insertion behavior.
- Modify `windows/codex_session_manager_electron/src/main.js`
  - Calls the Windows writer after incremental file restore.
  - Surfaces success/warning text in the IPC result message.
- Modify `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`
  - Verifies catalog candidates retain manifest records and recovery packages expose recovered file paths by session id.
- Modify `docs/操作手册.md`
  - Updates the restore documentation from “SQLite only best effort / may not display” to “threads index is repaired when possible; warnings are visible”.

---

### Task 1: Swift Core Recovered Thread Index Module

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift`
- Create: `Tests/CodexSessionVaultCoreTests/RecoveredThreadIndexTests.swift`

**Interfaces:**
- Consumes:
  - `BackupSessionRecord`
  - `BackupPaths`
  - recovered JSONL file at `paths.codexRoot/sessions/recovered/<session-id>.jsonl`
- Produces:
  - `public struct RecoveredThreadIndexEntry: Equatable, Sendable`
  - `public struct RecoveredThreadIndexResult: Equatable, Sendable`
  - `public final class RecoveredThreadIndexWriter`
  - `public func makeRecoveredThreadIndexEntry(record:recoveredURL:codexRoot:fileManager:) throws -> RecoveredThreadIndexEntry`
  - `public func ensureThreads(entries:databaseURL:) -> RecoveredThreadIndexResult`

- [ ] **Step 1: Write failing Swift tests for metadata extraction**

Create `Tests/CodexSessionVaultCoreTests/RecoveredThreadIndexTests.swift` with these tests:

```swift
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct RecoveredThreadIndexTests {

@Test
func metadataPrefersManifestTitleAndJsonlTimestamps() throws {
    let fixture = try RecoveredThreadIndexFixture()
    defer { fixture.cleanup() }
    let recoveredURL = fixture.recoveredURL(sessionID: "session-1")
    try fixture.writeRecovered(
        sessionID: "session-1",
        contents: """
        {"timestamp":"2026-07-08T12:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello from jsonl"}}
        {"timestamp":"2026-07-08T12:05:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"reply"}]}}

        """
    )
    let record = fixture.makeRecord(sessionID: "session-1", title: "Manifest Title")

    let entry = try makeRecoveredThreadIndexEntry(
        record: record,
        recoveredURL: recoveredURL,
        codexRoot: fixture.codexRoot
    )

    #expect(entry.id == "session-1")
    #expect(entry.rolloutPath == recoveredURL.path)
    #expect(entry.title == "Manifest Title")
    #expect(entry.firstUserMessage == "hello from jsonl")
    #expect(entry.preview == "hello from jsonl")
    #expect(entry.createdAt == 1_783_512_001)
    #expect(entry.updatedAt == 1_783_512_302)
    #expect(entry.createdAtMs == 1_783_512_001_000)
    #expect(entry.updatedAtMs == 1_783_512_302_000)
    #expect(entry.recencyAt == 1_783_512_302)
    #expect(entry.recencyAtMs == 1_783_512_302_000)
    #expect(entry.archived == 0)
    #expect(entry.hasUserEvent == 1)
}

@Test
func metadataFallsBackToRecordDatesAndSessionID() throws {
    let fixture = try RecoveredThreadIndexFixture()
    defer { fixture.cleanup() }
    let recoveredURL = fixture.recoveredURL(sessionID: "session-2")
    try fixture.writeRecovered(sessionID: "session-2", contents: #"{"role":"assistant","content":"only assistant"}"# + "\n")
    let record = fixture.makeRecord(sessionID: "session-2", title: nil)

    let entry = try makeRecoveredThreadIndexEntry(
        record: record,
        recoveredURL: recoveredURL,
        codexRoot: fixture.codexRoot
    )

    #expect(entry.id == "session-2")
    #expect(entry.title == "session-2")
    #expect(entry.firstUserMessage == "")
    #expect(entry.preview == "")
    #expect(entry.createdAt == 1_783_512_000)
    #expect(entry.updatedAt == 1_783_512_300)
    #expect(entry.hasUserEvent == 0)
}
}
```

Add fixture helpers in the same test file:

```swift
private final class RecoveredThreadIndexFixture {
    let root: URL
    let codexRoot: URL
    let backupRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveredThreadIndexTests-\(UUID().uuidString)", isDirectory: true)
        codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        backupRoot = root.appendingPathComponent("incremental-backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexRoot.appendingPathComponent("sessions/recovered", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func recoveredURL(sessionID: String) -> URL {
        codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("recovered", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    func writeRecovered(sessionID: String, contents: String) throws {
        try Data(contents.utf8).write(to: recoveredURL(sessionID: sessionID))
    }

    func makeRecord(sessionID: String, title: String?) -> BackupSessionRecord {
        BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: codexRoot.appendingPathComponent("sessions/\(sessionID).jsonl").path,
            backupPath: "sessions/2026/07/08/\(sessionID).jsonl",
            title: title,
            firstSeenAt: Date(timeIntervalSince1970: 1_783_512_000),
            lastBackedUpAt: Date(timeIntervalSince1970: 1_783_512_300),
            lineCount: 1,
            bytesBackedUp: 100,
            status: "active"
        )
    }
}
```

- [ ] **Step 2: Run metadata tests and verify they fail**

Run:

```bash
swift test --filter RecoveredThreadIndexTests
```

Expected: FAIL because `makeRecoveredThreadIndexEntry` and `RecoveredThreadIndexEntry` do not exist.

- [ ] **Step 3: Implement Swift metadata types and extractor**

Create `Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift` with:

```swift
import Foundation

public struct RecoveredThreadIndexEntry: Equatable, Sendable {
    public var id: String
    public var rolloutPath: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var source: String
    public var modelProvider: String
    public var cwd: String
    public var title: String
    public var sandboxPolicy: String
    public var approvalMode: String
    public var tokensUsed: Int64
    public var hasUserEvent: Int
    public var archived: Int
    public var archivedAt: Int64?
    public var firstUserMessage: String
    public var model: String
    public var preview: String
    public var recencyAt: Int64
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var recencyAtMs: Int64
    public var threadSource: String
    public var reasoningEffort: String?
    public var cliVersion: String
    public var memoryMode: String
    public var gitSHA: String?
    public var gitBranch: String?
    public var gitOriginURL: String?
    public var agentNickname: String?
    public var agentRole: String?
    public var agentPath: String?
}

private struct RecoveredJSONLMetadata {
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var firstUserMessage: String = ""
    var provider: String?
    var model: String?
    var cwd: String?
    var source: String?
    var sandboxPolicy: String?
    var approvalMode: String?
}

public func makeRecoveredThreadIndexEntry(
    record: BackupSessionRecord,
    recoveredURL: URL,
    codexRoot: URL,
    fileManager: FileManager = .default
) throws -> RecoveredThreadIndexEntry {
    let metadata = try extractRecoveredJSONLMetadata(from: recoveredURL)
    let createdDate = metadata.firstTimestamp ?? record.firstSeenAt
    let updatedDate = metadata.lastTimestamp ?? record.lastBackedUpAt ?? record.firstSeenAt
    let createdAt = Int64(createdDate.timeIntervalSince1970)
    let updatedAt = Int64(updatedDate.timeIntervalSince1970)
    let firstUserMessage = metadata.firstUserMessage
    let title = normalizedTitle(record.title) ?? normalizedTitle(firstUserMessage) ?? record.sessionId

    return RecoveredThreadIndexEntry(
        id: record.sessionId,
        rolloutPath: recoveredURL.path,
        createdAt: createdAt,
        updatedAt: updatedAt,
        source: normalizedTitle(metadata.source) ?? "recovered",
        modelProvider: normalizedTitle(metadata.provider) ?? "unknown",
        cwd: metadata.cwd ?? "",
        title: title,
        sandboxPolicy: metadata.sandboxPolicy ?? "",
        approvalMode: metadata.approvalMode ?? "",
        tokensUsed: 0,
        hasUserEvent: firstUserMessage.isEmpty ? 0 : 1,
        archived: 0,
        archivedAt: nil,
        firstUserMessage: firstUserMessage,
        model: normalizedTitle(metadata.model) ?? "unknown",
        preview: firstUserMessage,
        recencyAt: updatedAt,
        createdAtMs: createdAt * 1000,
        updatedAtMs: updatedAt * 1000,
        recencyAtMs: updatedAt * 1000,
        threadSource: "recovered",
        reasoningEffort: nil,
        cliVersion: "",
        memoryMode: "enabled",
        gitSHA: nil,
        gitBranch: nil,
        gitOriginURL: nil,
        agentNickname: nil,
        agentRole: nil,
        agentPath: nil
    )
}
```

Also add private helpers in the same file:

```swift
private func extractRecoveredJSONLMetadata(from url: URL) throws -> RecoveredJSONLMetadata {
    let data = try Data(contentsOf: url)
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    var metadata = RecoveredJSONLMetadata()

    for rawLine in lines.prefix(400) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any] else {
            continue
        }
        if let timestamp = parseCodexDate(object["timestamp"] as? String) {
            metadata.firstTimestamp = metadata.firstTimestamp ?? timestamp
            metadata.lastTimestamp = timestamp
        }
        let payload = object["payload"] as? [String: Any]
        metadata.provider = metadata.provider ?? stringValue(object["model_provider"]) ?? stringValue(payload?["model_provider"])
        metadata.model = metadata.model ?? stringValue(object["model"]) ?? stringValue(payload?["model"])
        metadata.cwd = metadata.cwd ?? stringValue(object["cwd"]) ?? stringValue(payload?["cwd"])
        metadata.source = metadata.source ?? stringValue(object["source"]) ?? stringValue(payload?["source"])
        metadata.sandboxPolicy = metadata.sandboxPolicy ?? stringValue(object["sandbox_policy"]) ?? stringValue(payload?["sandbox_policy"])
        metadata.approvalMode = metadata.approvalMode ?? stringValue(object["approval_mode"]) ?? stringValue(payload?["approval_mode"])
        if metadata.firstUserMessage.isEmpty, let message = firstUserMessage(from: object) {
            metadata.firstUserMessage = collapseWhitespace(message)
        }
    }
    return metadata
}

private func firstUserMessage(from object: [String: Any]) -> String? {
    if let role = object["role"] as? String, role == "user" {
        return textContent(object["content"])
    }
    guard let payload = object["payload"] as? [String: Any] else { return nil }
    if payload["type"] as? String == "user_message" {
        return textContent(payload["message"] ?? payload["content"])
    }
    if payload["role"] as? String == "user" {
        return textContent(payload["content"])
    }
    return nil
}

private func textContent(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let items = value as? [[String: Any]] {
        let texts = items.compactMap { item -> String? in
            if let text = item["text"] as? String { return text }
            if let text = item["content"] as? String { return text }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
    return nil
}

private func parseCodexDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return ISO8601DateFormatter().date(from: raw)
}

private func normalizedTitle(_ raw: String?) -> String? {
    let value = collapseWhitespace(raw ?? "")
    return value.isEmpty ? nil : String(value.prefix(180))
}

private func collapseWhitespace(_ raw: String) -> String {
    raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func stringValue(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    return value.isEmpty ? nil : value
}
```

- [ ] **Step 4: Run metadata tests and verify they pass**

Run:

```bash
swift test --filter RecoveredThreadIndexTests
```

Expected: PASS for the two metadata tests.

- [ ] **Step 5: Write failing Swift SQLite insertion tests**

Append these tests to `RecoveredThreadIndexTests`:

```swift
@Test
func ensureThreadsInsertsMissingThreadRow() throws {
    let fixture = try RecoveredThreadIndexFixture()
    defer { fixture.cleanup() }
    let database = try fixture.createStateDatabase()
    let entry = fixture.entry(sessionID: "missing-thread", title: "Recovered Thread")

    let result = try RecoveredThreadIndexWriter().ensureThreads(entries: [entry], databaseURL: database)

    #expect(result.insertedCount == 1)
    #expect(result.skippedCount == 0)
    #expect(result.warning == nil)
    let row = try fixture.threadRow(database: database, id: "missing-thread")
    #expect(row["id"] == "missing-thread")
    #expect(row["title"] == "Recovered Thread")
    #expect(row["rollout_path"] == entry.rolloutPath)
    #expect(row["archived"] == "0")
}

@Test
func ensureThreadsDoesNotOverwriteExistingThreadRow() throws {
    let fixture = try RecoveredThreadIndexFixture()
    defer { fixture.cleanup() }
    let database = try fixture.createStateDatabase()
    try fixture.insertExistingThread(database: database, id: "existing-thread", title: "Existing Title")
    let entry = fixture.entry(sessionID: "existing-thread", title: "New Title")

    let result = try RecoveredThreadIndexWriter().ensureThreads(entries: [entry], databaseURL: database)

    #expect(result.insertedCount == 0)
    #expect(result.skippedCount == 1)
    let row = try fixture.threadRow(database: database, id: "existing-thread")
    #expect(row["title"] == "Existing Title")
}

@Test
func ensureThreadsReturnsWarningWhenDatabaseIsMissing() throws {
    let fixture = try RecoveredThreadIndexFixture()
    defer { fixture.cleanup() }
    let database = fixture.root.appendingPathComponent("missing-state.sqlite")

    let result = try RecoveredThreadIndexWriter().ensureThreads(
        entries: [fixture.entry(sessionID: "a", title: "A")],
        databaseURL: database
    )

    #expect(result.insertedCount == 0)
    #expect(result.warning == "SQLite 索引未写入：state_5.sqlite 不存在")
}
```

Add these fixture helpers:

```swift
func createStateDatabase() throws -> URL {
    let database = codexRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
    let sql = """
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      model_provider TEXT NOT NULL,
      cwd TEXT NOT NULL,
      title TEXT NOT NULL,
      sandbox_policy TEXT NOT NULL,
      approval_mode TEXT NOT NULL,
      tokens_used INTEGER NOT NULL DEFAULT 0,
      has_user_event INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      archived_at INTEGER,
      cli_version TEXT NOT NULL DEFAULT '',
      first_user_message TEXT NOT NULL DEFAULT '',
      memory_mode TEXT NOT NULL DEFAULT 'enabled',
      model TEXT,
      created_at_ms INTEGER,
      updated_at_ms INTEGER,
      thread_source TEXT,
      preview TEXT NOT NULL DEFAULT '',
      recency_at INTEGER NOT NULL DEFAULT 0,
      recency_at_ms INTEGER NOT NULL DEFAULT 0
    );
    """
    try runSQLite(database: database, sql: sql)
    return database
}

func entry(sessionID: String, title: String) -> RecoveredThreadIndexEntry {
    RecoveredThreadIndexEntry(
        id: sessionID,
        rolloutPath: recoveredURL(sessionID: sessionID).path,
        createdAt: 1_783_512_000,
        updatedAt: 1_783_512_300,
        source: "recovered",
        modelProvider: "unknown",
        cwd: "",
        title: title,
        sandboxPolicy: "",
        approvalMode: "",
        tokensUsed: 0,
        hasUserEvent: 1,
        archived: 0,
        archivedAt: nil,
        firstUserMessage: title,
        model: "unknown",
        preview: title,
        recencyAt: 1_783_512_300,
        createdAtMs: 1_783_512_000_000,
        updatedAtMs: 1_783_512_300_000,
        recencyAtMs: 1_783_512_300_000,
        threadSource: "recovered",
        reasoningEffort: nil,
        cliVersion: "",
        memoryMode: "enabled",
        gitSHA: nil,
        gitBranch: nil,
        gitOriginURL: nil,
        agentNickname: nil,
        agentRole: nil,
        agentPath: nil
    )
}
```

Add `runSQLite`, `insertExistingThread`, and `threadRow` helpers using `/usr/bin/sqlite3 -json`.

- [ ] **Step 6: Run SQLite insertion tests and verify they fail**

Run:

```bash
swift test --filter RecoveredThreadIndexTests
```

Expected: FAIL because `RecoveredThreadIndexWriter` and `RecoveredThreadIndexResult` do not exist.

- [ ] **Step 7: Implement Swift SQLite writer**

Add these public types to `RecoveredThreadIndex.swift`:

```swift
public struct RecoveredThreadIndexResult: Equatable, Sendable {
    public var insertedCount: Int
    public var skippedCount: Int
    public var warning: String?

    public init(insertedCount: Int, skippedCount: Int, warning: String?) {
        self.insertedCount = insertedCount
        self.skippedCount = skippedCount
        self.warning = warning
    }

    public var message: String {
        if let warning { return warning }
        return "已补写列表索引：新增 \(insertedCount) 个，跳过 \(skippedCount) 个。"
    }
}

public final class RecoveredThreadIndexWriter {
    private let sqlitePath: String
    private let fileManager: FileManager

    public init(sqlitePath: String = "/usr/bin/sqlite3", fileManager: FileManager = .default) {
        self.sqlitePath = sqlitePath
        self.fileManager = fileManager
    }

    public func ensureThreads(
        entries: [RecoveredThreadIndexEntry],
        databaseURL: URL
    ) throws -> RecoveredThreadIndexResult {
        guard !entries.isEmpty else {
            return RecoveredThreadIndexResult(insertedCount: 0, skippedCount: 0, warning: nil)
        }
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return RecoveredThreadIndexResult(
                insertedCount: 0,
                skippedCount: 0,
                warning: "SQLite 索引未写入：state_5.sqlite 不存在"
            )
        }
        guard try tableExists(databaseURL: databaseURL, table: "threads") else {
            return RecoveredThreadIndexResult(
                insertedCount: 0,
                skippedCount: 0,
                warning: "SQLite 索引未写入：threads 表不存在"
            )
        }

        let columns = try tableColumns(databaseURL: databaseURL, table: "threads")
        var inserted = 0
        var skipped = 0
        var statements = ["BEGIN IMMEDIATE;"]
        for entry in entries {
            if try threadExists(databaseURL: databaseURL, id: entry.id) {
                skipped += 1
                continue
            }
            statements.append(insertStatement(entry: entry, columns: columns))
            inserted += 1
        }
        statements.append("COMMIT;")
        if inserted > 0 {
            try runSQLite(databaseURL: databaseURL, sql: statements.joined(separator: "\n"))
        }
        return RecoveredThreadIndexResult(insertedCount: inserted, skippedCount: skipped, warning: nil)
    }
}
```

Implement private helpers in the same file:

```swift
private struct SQLiteColumn: Decodable {
    let name: String
    let notnull: Int
    let dflt_value: String?
}

private func insertStatement(entry: RecoveredThreadIndexEntry, columns: [SQLiteColumn]) -> String {
    let values = dictionary(for: entry)
    let writable = columns.compactMap { column -> (String, String)? in
        if let value = values[column.name] { return (column.name, value) }
        if column.notnull == 1, column.dflt_value == nil {
            return (column.name, "''")
        }
        return nil
    }
    let names = writable.map { sqliteIdentifier($0.0) }.joined(separator: ", ")
    let rawValues = writable.map(\.1).joined(separator: ", ")
    return "INSERT INTO threads (\(names)) VALUES (\(rawValues));"
}
```

Map every field from `RecoveredThreadIndexEntry` to a SQL literal with `sqliteStringLiteral`, integer strings, or `NULL`. Reuse local private `sqliteIdentifier` and `sqliteStringLiteral` helpers in this file so the core module does not depend on executable-private helpers.

- [ ] **Step 8: Run Swift core tests**

Run:

```bash
swift test --filter RecoveredThreadIndexTests
swift test
```

Expected: both PASS.

- [ ] **Step 9: Commit Swift core module**

```bash
git add Sources/CodexSessionVaultCore/Backup/RecoveredThreadIndex.swift Tests/CodexSessionVaultCoreTests/RecoveredThreadIndexTests.swift
git commit -m "feat: add recovered thread sqlite index writer"
```

---

### Task 2: macOS Incremental Restore Integration

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift:3834-3890`
- Test: `Tests/CodexSessionVaultCoreTests/RecoveredThreadIndexTests.swift`

**Interfaces:**
- Consumes:
  - `BackupRecoveryPackage.dataURL`
  - `IncrementalBackupCatalog` result candidates
  - `RecoveredThreadIndexWriter.ensureThreads(entries:databaseURL:)`
- Produces:
  - User-visible restore message containing SQLite index result or warning.

- [ ] **Step 1: Add helper to build restored thread entries in macOS worker**

In `Sources/CodexSessionVault/main.swift`, near the worker restore helpers, add:

```swift
private func recoveredThreadIndexEntries(
    package: BackupRecoveryPackage,
    catalog: IncrementalBackupCatalogResult,
    sessionIDs: [String],
    codexRoot: URL
) throws -> [RecoveredThreadIndexEntry] {
    let recordsByID = Dictionary(uniqueKeysWithValues: catalog.candidates.map { candidate in
        (candidate.sessionId, candidate)
    })
    return try sessionIDs.compactMap { sessionID in
        guard let candidate = recordsByID[sessionID],
              let record = candidate.backupRecord else {
            return nil
        }
        let recoveredURL = codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("recovered", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        return try makeRecoveredThreadIndexEntry(
            record: record,
            recoveredURL: recoveredURL,
            codexRoot: codexRoot
        )
    }
}
```

If `IncrementalRestoreCandidate` does not expose `backupRecord`, add a field in `Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift`:

```swift
public var backupRecord: BackupSessionRecord?
```

Set it when constructing each candidate from manifest records. Keep it `nil` for invalid entries where no usable record exists.

- [ ] **Step 2: Update `.restoreIncrementalBackupSessions` to call the writer**

Change the incremental restore branch after `restoreConversationsOnly(...)`:

```swift
let entries = try recoveredThreadIndexEntries(
    package: package,
    catalog: catalog,
    sessionIDs: restorableIDs,
    codexRoot: root
)
let indexResult = try RecoveredThreadIndexWriter().ensureThreads(
    entries: entries,
    databaseURL: root.appendingPathComponent("state_5.sqlite", isDirectory: false)
)
try report(1.0, "备份恢复完成", "已恢复 \(restorableIDs.count) 个缺失会话。\(indexResult.message)")
return .ok(
    message: "已从本地增量备份恢复 \(restorableIDs.count) 个缺失会话。\(indexResult.message) 请重启 Codex 后查看。"
)
```

- [ ] **Step 3: Run macOS targeted verification**

Run:

```bash
swift test --filter RecoveredThreadIndexTests
swift test --filter IncrementalBackupCatalogTests
swift test --filter BackupRecoveryBuilderTests
```

Expected: all PASS.

- [ ] **Step 4: Run full Swift test**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit macOS integration**

```bash
git add Sources/CodexSessionVault/main.swift Sources/CodexSessionVaultCore/Backup/IncrementalBackupCatalog.swift Tests/CodexSessionVaultCoreTests/IncrementalBackupCatalogTests.swift
git commit -m "feat: repair macos sqlite index after incremental restore"
```

If `IncrementalBackupCatalog.swift` did not need the `backupRecord` exposure, omit it and its test file from `git add`.

---

### Task 3: Windows Recovered Thread Index Module

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/recovered-thread-index.js`
- Create: `windows/codex_session_manager_electron/test/backup/recovered-thread-index.test.js`

**Interfaces:**
- Consumes:
  - manifest record object from `incremental-recovery.js`
  - recovered JSONL path
  - `openDatabase`, `writeDatabase`, `tableExists`, `execRows` patterns from `src/main.js`
- Produces:
  - `extractRecoveredThreadMetadata(record, recoveredPath, codexRoot)`
  - `ensureRecoveredThreadsInStateDatabase(databasePath, entries)`
  - result object `{ insertedCount, skippedCount, warning, message }`

- [ ] **Step 1: Write failing Node metadata tests**

Create `windows/codex_session_manager_electron/test/backup/recovered-thread-index.test.js`:

```javascript
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
} = require('../../src/backup/recovered-thread-index');

async function makeFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'recovered-thread-index-'));
  t.after(async () => fs.rm(root, { recursive: true, force: true }));
  const codexRoot = path.join(root, '.codex');
  const recoveredRoot = path.join(codexRoot, 'sessions', 'recovered');
  await fs.mkdir(recoveredRoot, { recursive: true });
  return { root, codexRoot, recoveredRoot };
}

function record(sessionId, title = 'Manifest Title') {
  return {
    sessionId,
    sourcePath: `C:\\Users\\Ada\\.codex\\sessions\\${sessionId}.jsonl`,
    backupPath: `sessions/2026/07/08/${sessionId}.jsonl`,
    title,
    firstSeenAt: '2026-07-08T12:00:00.000Z',
    lastBackedUpAt: '2026-07-08T12:05:00.000Z',
    lineCount: 1,
    bytesBackedUp: 100,
    status: 'active',
  };
}

test('extractRecoveredThreadMetadata prefers manifest title and jsonl timestamps', async (t) => {
  const { codexRoot, recoveredRoot } = await makeFixture(t);
  const recoveredPath = path.join(recoveredRoot, 'session-1.jsonl');
  await fs.writeFile(recoveredPath, [
    '{"timestamp":"2026-07-08T12:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello from jsonl"}}',
    '{"timestamp":"2026-07-08T12:05:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"reply"}]}}',
    '',
  ].join('\n'), 'utf8');

  const entry = await extractRecoveredThreadMetadata(record('session-1'), recoveredPath, codexRoot);

  assert.equal(entry.id, 'session-1');
  assert.equal(entry.rolloutPath, recoveredPath);
  assert.equal(entry.title, 'Manifest Title');
  assert.equal(entry.firstUserMessage, 'hello from jsonl');
  assert.equal(entry.preview, 'hello from jsonl');
  assert.equal(entry.createdAt, 1783512001);
  assert.equal(entry.updatedAt, 1783512302);
  assert.equal(entry.createdAtMs, 1783512001000);
  assert.equal(entry.updatedAtMs, 1783512302000);
  assert.equal(entry.archived, 0);
  assert.equal(entry.hasUserEvent, 1);
});
```

- [ ] **Step 2: Run Node metadata test and verify it fails**

Run:

```bash
cd windows/codex_session_manager_electron
npm test -- test/backup/recovered-thread-index.test.js
```

Expected: FAIL because `src/backup/recovered-thread-index.js` does not exist.

- [ ] **Step 3: Implement Windows metadata module skeleton**

Create `windows/codex_session_manager_electron/src/backup/recovered-thread-index.js`:

```javascript
const fs = require('node:fs');

function collapseWhitespace(value) {
  return String(value || '').split(/\s+/).filter(Boolean).join(' ');
}

function normalizedTitle(value) {
  const normalized = collapseWhitespace(value);
  return normalized ? normalized.slice(0, 180) : '';
}

function parseDateMs(value) {
  const ms = Date.parse(value || '');
  return Number.isFinite(ms) ? ms : null;
}

function textContent(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map((item) => item && (item.text || item.content || '')).filter(Boolean).join(' ');
  }
  return '';
}

function firstUserMessage(object) {
  if (object.role === 'user') return textContent(object.content);
  const payload = object.payload || {};
  if (payload.type === 'user_message') return textContent(payload.message || payload.content);
  if (payload.role === 'user') return textContent(payload.content);
  return '';
}

async function extractRecoveredThreadMetadata(record, recoveredPath, codexRoot) {
  const text = await fs.promises.readFile(recoveredPath, 'utf8');
  const lines = text.split(/\n/).filter((line) => line.trim()).slice(0, 400);
  let firstTimestamp = null;
  let lastTimestamp = null;
  let userMessage = '';
  let provider = '';
  let model = '';
  let cwd = '';
  let source = '';
  let sandboxPolicy = '';
  let approvalMode = '';

  for (const line of lines) {
    let object;
    try { object = JSON.parse(line); } catch { continue; }
    const payload = object.payload || {};
    const timestamp = parseDateMs(object.timestamp);
    if (timestamp !== null) {
      if (firstTimestamp === null) firstTimestamp = timestamp;
      lastTimestamp = timestamp;
    }
    provider ||= object.model_provider || payload.model_provider || '';
    model ||= object.model || payload.model || '';
    cwd ||= object.cwd || payload.cwd || '';
    source ||= object.source || payload.source || '';
    sandboxPolicy ||= object.sandbox_policy || payload.sandbox_policy || '';
    approvalMode ||= object.approval_mode || payload.approval_mode || '';
    if (!userMessage) userMessage = collapseWhitespace(firstUserMessage(object));
  }

  const createdMs = firstTimestamp ?? Date.parse(record.firstSeenAt);
  const updatedMs = lastTimestamp ?? Date.parse(record.lastBackedUpAt || record.firstSeenAt);
  const title = normalizedTitle(record.title) || normalizedTitle(userMessage) || String(record.sessionId);

  return {
    id: String(record.sessionId),
    rolloutPath: recoveredPath,
    createdAt: Math.floor(createdMs / 1000),
    updatedAt: Math.floor(updatedMs / 1000),
    source: normalizedTitle(source) || 'recovered',
    modelProvider: normalizedTitle(provider) || 'unknown',
    cwd: cwd || '',
    title,
    sandboxPolicy,
    approvalMode,
    tokensUsed: 0,
    hasUserEvent: userMessage ? 1 : 0,
    archived: 0,
    archivedAt: null,
    firstUserMessage: userMessage,
    model: normalizedTitle(model) || 'unknown',
    preview: userMessage,
    recencyAt: Math.floor(updatedMs / 1000),
    createdAtMs: createdMs,
    updatedAtMs: updatedMs,
    recencyAtMs: updatedMs,
    threadSource: 'recovered',
    cliVersion: '',
    memoryMode: 'enabled',
  };
}

module.exports = {
  extractRecoveredThreadMetadata,
};
```

- [ ] **Step 4: Run Node metadata test and verify it passes**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/recovered-thread-index.test.js
```

Expected: PASS for the metadata test.

- [ ] **Step 5: Write failing Windows SQLite insertion tests**

Append to `recovered-thread-index.test.js`:

```javascript
const initSqlJs = require('sql.js');

async function createStateDatabase(databasePath) {
  const SQL = await initSqlJs();
  const db = new SQL.Database();
  db.run(`
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      model_provider TEXT NOT NULL,
      cwd TEXT NOT NULL,
      title TEXT NOT NULL,
      sandbox_policy TEXT NOT NULL,
      approval_mode TEXT NOT NULL,
      tokens_used INTEGER NOT NULL DEFAULT 0,
      has_user_event INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      archived_at INTEGER,
      cli_version TEXT NOT NULL DEFAULT '',
      first_user_message TEXT NOT NULL DEFAULT '',
      memory_mode TEXT NOT NULL DEFAULT 'enabled',
      model TEXT,
      created_at_ms INTEGER,
      updated_at_ms INTEGER,
      thread_source TEXT,
      preview TEXT NOT NULL DEFAULT '',
      recency_at INTEGER NOT NULL DEFAULT 0,
      recency_at_ms INTEGER NOT NULL DEFAULT 0
    );
  `);
  await fs.writeFile(databasePath, Buffer.from(db.export()));
  db.close();
}

test('ensureRecoveredThreadsInStateDatabase inserts missing row', async (t) => {
  const { root, codexRoot, recoveredRoot } = await makeFixture(t);
  const databasePath = path.join(codexRoot, 'state_5.sqlite');
  await createStateDatabase(databasePath);
  const recoveredPath = path.join(recoveredRoot, 'session-1.jsonl');
  await fs.writeFile(recoveredPath, '{"role":"user","content":"hello"}\n', 'utf8');
  const entry = await extractRecoveredThreadMetadata(record('session-1', 'Inserted Title'), recoveredPath, codexRoot);

  const result = await ensureRecoveredThreadsInStateDatabase(databasePath, [entry]);

  assert.equal(result.insertedCount, 1);
  assert.equal(result.skippedCount, 0);
  assert.equal(result.warning, null);
  const SQL = await initSqlJs();
  const db = new SQL.Database(await fs.readFile(databasePath));
  const rows = db.exec("SELECT id, title, rollout_path, archived FROM threads WHERE id = 'session-1';")[0].values;
  db.close();
  assert.deepEqual(rows[0], ['session-1', 'Inserted Title', recoveredPath, 0]);
});

test('ensureRecoveredThreadsInStateDatabase does not overwrite existing row', async (t) => {
  const { codexRoot } = await makeFixture(t);
  const databasePath = path.join(codexRoot, 'state_5.sqlite');
  await createStateDatabase(databasePath);
  const SQL = await initSqlJs();
  const db = new SQL.Database(await fs.readFile(databasePath));
  db.run("INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode, archived, first_user_message, preview, recency_at, recency_at_ms) VALUES ('existing', '/old.jsonl', 1, 1, 'vscode', 'openai', '', 'Old Title', '', '', 0, '', '', 1, 1000);");
  await fs.writeFile(databasePath, Buffer.from(db.export()));
  db.close();

  const result = await ensureRecoveredThreadsInStateDatabase(databasePath, [{
    id: 'existing',
    rolloutPath: '/new.jsonl',
    createdAt: 2,
    updatedAt: 2,
    source: 'recovered',
    modelProvider: 'unknown',
    cwd: '',
    title: 'New Title',
    sandboxPolicy: '',
    approvalMode: '',
    tokensUsed: 0,
    hasUserEvent: 1,
    archived: 0,
    archivedAt: null,
    firstUserMessage: 'New Title',
    model: 'unknown',
    preview: 'New Title',
    recencyAt: 2,
    createdAtMs: 2000,
    updatedAtMs: 2000,
    recencyAtMs: 2000,
    threadSource: 'recovered',
    cliVersion: '',
    memoryMode: 'enabled',
  }]);

  assert.equal(result.insertedCount, 0);
  assert.equal(result.skippedCount, 1);
});
```

- [ ] **Step 6: Run Windows SQLite tests and verify they fail**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/recovered-thread-index.test.js
```

Expected: FAIL because `ensureRecoveredThreadsInStateDatabase` is not exported.

- [ ] **Step 7: Implement Windows SQLite writer**

Extend `src/backup/recovered-thread-index.js`:

```javascript
const initSqlJs = require('sql.js');

function execRows(db, sql, params = []) {
  const statement = db.prepare(sql);
  try {
    statement.bind(params);
    const rows = [];
    while (statement.step()) rows.push(statement.getAsObject());
    return rows;
  } finally {
    statement.free();
  }
}

function tableExists(db, table) {
  return execRows(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;", [table]).length > 0;
}

function tableColumns(db, table) {
  return execRows(db, `PRAGMA table_info(${table});`);
}

function entryValues(entry) {
  return {
    id: entry.id,
    rollout_path: entry.rolloutPath,
    created_at: entry.createdAt,
    updated_at: entry.updatedAt,
    source: entry.source,
    model_provider: entry.modelProvider,
    cwd: entry.cwd,
    title: entry.title,
    sandbox_policy: entry.sandboxPolicy,
    approval_mode: entry.approvalMode,
    tokens_used: entry.tokensUsed,
    has_user_event: entry.hasUserEvent,
    archived: entry.archived,
    archived_at: entry.archivedAt,
    first_user_message: entry.firstUserMessage,
    model: entry.model,
    preview: entry.preview,
    recency_at: entry.recencyAt,
    created_at_ms: entry.createdAtMs,
    updated_at_ms: entry.updatedAtMs,
    recency_at_ms: entry.recencyAtMs,
    thread_source: entry.threadSource,
    cli_version: entry.cliVersion,
    memory_mode: entry.memoryMode,
  };
}

async function ensureRecoveredThreadsInStateDatabase(databasePath, entries) {
  if (!entries.length) return { insertedCount: 0, skippedCount: 0, warning: null, message: '已补写列表索引：新增 0 个，跳过 0 个。' };
  if (!fs.existsSync(databasePath)) {
    return { insertedCount: 0, skippedCount: 0, warning: 'SQLite 索引未写入：state_5.sqlite 不存在', message: 'SQLite 索引未写入：state_5.sqlite 不存在' };
  }
  const SQL = await initSqlJs();
  const db = new SQL.Database(await fs.promises.readFile(databasePath));
  try {
    if (!tableExists(db, 'threads')) {
      return { insertedCount: 0, skippedCount: 0, warning: 'SQLite 索引未写入：threads 表不存在', message: 'SQLite 索引未写入：threads 表不存在' };
    }
    const columns = tableColumns(db, 'threads');
    let insertedCount = 0;
    let skippedCount = 0;
    db.run('BEGIN IMMEDIATE;');
    for (const entry of entries) {
      if (execRows(db, 'SELECT id FROM threads WHERE id = ?;', [entry.id]).length) {
        skippedCount += 1;
        continue;
      }
      const values = entryValues(entry);
      const writable = columns
        .map((column) => column.name)
        .filter((name) => Object.prototype.hasOwnProperty.call(values, name));
      const placeholders = writable.map(() => '?').join(', ');
      db.run(
        `INSERT INTO threads (${writable.map((name) => `"${name}"`).join(', ')}) VALUES (${placeholders});`,
        writable.map((name) => values[name])
      );
      insertedCount += 1;
    }
    db.run('COMMIT;');
    await fs.promises.writeFile(databasePath, Buffer.from(db.export()));
    return {
      insertedCount,
      skippedCount,
      warning: null,
      message: `已补写列表索引：新增 ${insertedCount} 个，跳过 ${skippedCount} 个。`,
    };
  } catch (error) {
    try { db.run('ROLLBACK;'); } catch {}
    return {
      insertedCount: 0,
      skippedCount: 0,
      warning: `SQLite 索引未写入：${error.message}`,
      message: `SQLite 索引未写入：${error.message}`,
    };
  } finally {
    db.close();
  }
}

module.exports = {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
};
```

- [ ] **Step 8: Run Windows module tests**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/backup/recovered-thread-index.test.js
npm test
```

Expected: both PASS.

- [ ] **Step 9: Commit Windows module**

```bash
git add windows/codex_session_manager_electron/src/backup/recovered-thread-index.js windows/codex_session_manager_electron/test/backup/recovered-thread-index.test.js
git commit -m "feat: add windows recovered thread sqlite writer"
```

---

### Task 4: Windows Incremental Restore Integration

**Files:**
- Modify: `windows/codex_session_manager_electron/src/main.js:1-20`
- Modify: `windows/codex_session_manager_electron/src/main.js:1760-1790`
- Modify: `windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js`

**Interfaces:**
- Consumes:
  - `buildIncrementalRecoveryPackage({ paths, sessionIds })`
  - `extractRecoveredThreadMetadata(record, recoveredPath, codexRoot)`
  - `ensureRecoveredThreadsInStateDatabase(databasePath, entries)`
- Produces:
  - IPC restore message containing SQLite success or warning text.

- [ ] **Step 1: Import Windows recovered thread module**

At the top of `src/main.js`, add:

```javascript
const {
  extractRecoveredThreadMetadata,
  ensureRecoveredThreadsInStateDatabase,
} = require('./backup/recovered-thread-index');
```

- [ ] **Step 2: Add helper to build entries from catalog candidates**

Near the incremental restore handler in `src/main.js`, add:

```javascript
async function recoveredThreadEntriesFromIncrementalRecovery(catalog, recovery, sessionIds) {
  const byId = new Map((catalog.candidates || []).map((candidate) => [candidate.sessionId, candidate]));
  const entries = [];
  for (const sessionId of sessionIds) {
    const candidate = byId.get(sessionId);
    const record = candidate && candidate.backupRecord;
    if (!record) continue;
    const recoveredPath = recovery.recoveredFiles && recovery.recoveredFiles[sessionId];
    if (!recoveredPath) continue;
    entries.push(await extractRecoveredThreadMetadata(record, recoveredPath, codexRoot));
  }
  return entries;
}
```

This helper relies on `buildIncrementalRecoveryPackage` returning exact recovered paths by session id. Do not duplicate filename sanitization in `main.js`.

- [ ] **Step 3: Expose backupRecord and recoveredFiles from recovery module**

Modify `windows/codex_session_manager_electron/src/backup/incremental-recovery.js` so each candidate includes the manifest record:

```javascript
return {
  sessionId,
  title: record.title || sessionId,
  status,
  isRestorable,
  backupPath: record.backupPath || '',
  sourcePath: record.sourcePath || '',
  backupRecord: record,
  error,
};
```

Keep existing public fields unchanged.

In `buildIncrementalRecoveryPackage`, add a `recoveredFiles` object:

```javascript
const recoveredFiles = {};
```

Inside the record loop, after copying the backup file, set:

```javascript
recoveredFiles[record.sessionId] = path.join(recoveredRoot, filename);
```

Return it with the package:

```javascript
return {
  path: packagePath,
  dataPath,
  snapshotPath,
  recoveredFiles,
};
```

- [ ] **Step 4: Call SQLite repair after file restore**

In the `restore-incremental-backup-sessions` handler, replace the final message block with:

```javascript
const sqliteMessage = await restoreConversationsOnly({
  ...recovery,
  includedPaths: ['session_index.jsonl', 'sessions'],
});
const threadEntries = await recoveredThreadEntriesFromIncrementalRecovery(catalog, recovery, restorableIds);
const threadIndexResult = await ensureRecoveredThreadsInStateDatabase(
  path.join(codexRoot, 'state_5.sqlite'),
  threadEntries
);
return {
  ok: true,
  restoredCount: restorableIds.length,
  message: `已从本地增量备份恢复 ${restorableIds.length} 个缺失会话。${sqliteMessage} ${threadIndexResult.message} 请重启 Codex 后查看。`,
};
```

- [ ] **Step 5: Add Windows catalog test for backupRecord**

Append to `test/backup/incremental-recovery.test.js`:

```javascript
test('catalog candidates retain backup records for sqlite repair', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'missing.jsonl'), '{"role":"user"}\n');
  await writeManifest(paths, {
    missing: record('missing', path.join('sessions', '2026', '07', '08', 'missing.jsonl'), 'missing title'),
  });

  const catalog = await loadIncrementalBackupCatalog({ paths, currentSessionIds: new Set() });

  assert.equal(catalog.candidates[0].backupRecord.sessionId, 'missing');
  assert.equal(catalog.candidates[0].backupRecord.title, 'missing title');
});
```

Append another test to verify exact recovered file paths:

```javascript
test('recovery package exposes recovered file paths by session id', async (t) => {
  const { paths } = await makeFixture(t);
  await fs.mkdir(path.join(paths.backupRoot, 'sessions', '2026', '07', '08'), { recursive: true });
  await fs.writeFile(path.join(paths.backupRoot, 'sessions', '2026', '07', '08', 'selected.jsonl'), '{"role":"user"}\n');
  await writeManifest(paths, {
    selected: record('selected', path.join('sessions', '2026', '07', '08', 'selected.jsonl'), 'selected title'),
  });

  const recovery = await buildIncrementalRecoveryPackage({
    paths,
    sessionIds: ['selected'],
    now: () => new Date('2026-07-08T12:30:00.000Z'),
  });

  assert.equal(
    recovery.recoveredFiles.selected,
    path.join(recovery.dataPath, 'sessions', 'recovered', 'selected.jsonl')
  );
});
```

- [ ] **Step 6: Run Windows tests and syntax checks**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
node --check src/main.js
node --check src/backup/recovered-thread-index.js
```

Expected: all PASS.

- [ ] **Step 7: Commit Windows integration**

```bash
git add windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/src/backup/incremental-recovery.js windows/codex_session_manager_electron/test/backup/incremental-recovery.test.js
git commit -m "feat: repair windows sqlite index after incremental restore"
```

---

### Task 5: Documentation and Verification

**Files:**
- Modify: `docs/操作手册.md:320-345`

**Interfaces:**
- Consumes:
  - New macOS restore result message.
  - New Windows restore result message.
- Produces:
  - Updated user-facing operation manual.

- [ ] **Step 1: Update operation manual SQLite wording**

Replace the old “第一阶段恢复会生成文件型恢复包，不强行重建 `state_5.sqlite`” paragraph with:

```markdown
增量备份恢复会先恢复 `.jsonl` 和 `session_index.jsonl`，然后尽力向 `state_5.sqlite` 的 `threads` 表补写缺失会话索引。补写成功后，新版 Codex 重启后应能在会话列表看到恢复的对话。
```

Replace the old restore rule:

```markdown
- `state_5.sqlite` 只做尽力合并；增量备份恢复包没有 SQLite 时，恢复仍可完成。
```

with:

```markdown
- 恢复会尽力补写 `state_5.sqlite.threads` 列表索引；如果数据库不存在、被 Codex 占用或 schema 不兼容，文件恢复仍会保留，但界面会显示 SQLite 索引未写入的 warning。
```

- [ ] **Step 2: Run full verification**

Run:

```bash
swift test
cd windows/codex_session_manager_electron
npm test
node --check src/main.js
node --check src/preload.js
node --check src/renderer.js
node --check src/backup/recovered-thread-index.js
cd ../..
./scripts/build_app.sh
cd windows/codex_session_manager_electron
npm run package:win
```

Expected:

- Swift tests pass.
- Windows Node tests pass.
- Node syntax checks produce no output and exit 0.
- Mac app builds at `dist/codex_会话管理.app`.
- Windows portable app builds at `dist/win10-exe/codex_session_manager-win32-x64`.

- [ ] **Step 3: Run non-destructive sandbox restore smoke**

Run a one-off Windows module smoke in a temp directory:

```bash
cd /Users/mqzj/Documents/CodexConversation/CodexSessionKeeper/windows/codex_session_manager_electron
node --test test/backup/recovered-thread-index.test.js
```

Expected: PASS. This confirms SQLite insertion using a temp database, without touching real `~/.codex`.

- [ ] **Step 4: Inspect git status**

Run:

```bash
git -C /Users/mqzj/Documents/CodexConversation/CodexSessionKeeper status --branch --short
```

Expected: only intended source, test, and docs changes are present before the final commit; `.codegraph/` may remain untracked.

- [ ] **Step 5: Commit docs and verification-ready changes**

```bash
git add docs/操作手册.md
git commit -m "docs: document sqlite index repair for backup restore"
```

If Task 5 includes no documentation changes because previous tasks already updated the manual, skip this commit and record that in the final implementation summary.

---

## Final Acceptance Checklist

- [ ] macOS incremental restore writes restored JSONL to `sessions/recovered`.
- [ ] macOS incremental restore merges `session_index.jsonl`.
- [ ] macOS incremental restore inserts missing `state_5.sqlite.threads` rows.
- [ ] macOS incremental restore does not overwrite existing `threads` rows.
- [ ] Windows incremental restore writes restored JSONL to `sessions/recovered`.
- [ ] Windows incremental restore merges `session_index.jsonl`.
- [ ] Windows incremental restore inserts missing `state_5.sqlite.threads` rows.
- [ ] Windows incremental restore does not overwrite existing `threads` rows.
- [ ] SQLite warning is visible when database is missing or incompatible.
- [ ] Existing snapshot restore behavior still passes tests.
- [ ] Existing automatic incremental backup tests still pass.
- [ ] Build verification passes for macOS and Windows.

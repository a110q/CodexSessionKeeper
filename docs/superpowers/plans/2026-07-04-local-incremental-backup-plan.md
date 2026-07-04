# Local Incremental Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build first-stage local automatic incremental backup for Codex desktop conversations by tailing new `.jsonl` lines into `~/.codex-session-vault/incremental-backups`.

**Architecture:** Add a focused backup subsystem instead of extending the existing snapshot code. macOS gets a testable Swift core module plus light app integration; Windows gets testable Node modules plus Electron integration. Both platforms share the same backup directory layout, manifest fields, cursor semantics, status file, and recovery-staging format from the approved spec.

**Tech Stack:** Swift 6 / SwiftPM / Foundation / `/usr/bin/sqlite3` for macOS; Electron 30 / Node.js / `node:test` / `sql.js` for Windows; existing SwiftUI and Electron renderer UI.

---

## Scope

This plan implements the approved first-stage local backup only:

- Automatic local incremental backup of Codex session `.jsonl` files.
- Minimal manifest, cursor store, status file, logs, and diagnostics.
- macOS and Windows app integration.
- Recovery staging package generation for existing file-based restore flow.

This plan does not implement NAS upload, encryption, centralized monitoring, or full SQLite thread index reconstruction.

## File Structure

### macOS

- Modify: `Package.swift`
  - Add a testable `CodexSessionVaultCore` library target.
  - Add `CodexSessionVaultCoreTests`.
  - Keep the current executable target.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupModels.swift`
  - Shared data models for manifest, status, cursor rows, and runtime state.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupPaths.swift`
  - Resolve Codex root, backup root, logs, sessions, staging, manifest, status, and cursor paths.
- Create: `Sources/CodexSessionVaultCore/Backup/SessionIdentity.swift`
  - Extract session id, first-seen date, and title from file path/content.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift`
  - Read/write `manifest.json` atomically.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
  - Read/write `cursors.sqlite` using `/usr/bin/sqlite3`.
- Create: `Sources/CodexSessionVaultCore/Backup/SessionTailer.swift`
  - Read complete lines from a byte offset, preserve partial lines.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
  - Scan, debounce, tail, append backup files, update manifest/cursor/status.
- Create: `Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift`
  - Generate file-type recovery staging package.
- Create: `Tests/CodexSessionVaultCoreTests/*Tests.swift`
  - Unit tests for path layout, identity extraction, tailing, manifest, cursor store, agent backup, and recovery builder.
- Modify: `Sources/CodexSessionVault/main.swift`
  - Import the core target.
  - Start/stop `BackupAgent`.
  - Surface local backup status in the UI.

### Windows

- Modify: `windows/codex_session_manager_electron/package.json`
  - Add `test` script using `node --test`.
- Create: `windows/codex_session_manager_electron/src/backup/models.js`
- Create: `windows/codex_session_manager_electron/src/backup/paths.js`
- Create: `windows/codex_session_manager_electron/src/backup/session-identity.js`
- Create: `windows/codex_session_manager_electron/src/backup/manifest-store.js`
- Create: `windows/codex_session_manager_electron/src/backup/cursor-store.js`
- Create: `windows/codex_session_manager_electron/src/backup/session-tailer.js`
- Create: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Create: `windows/codex_session_manager_electron/src/backup/recovery-builder.js`
- Create: `windows/codex_session_manager_electron/test/backup/*.test.js`
- Modify: `windows/codex_session_manager_electron/src/main.js`
  - Start the backup agent and expose status IPC.
- Modify: `windows/codex_session_manager_electron/src/preload.js`
  - Expose backup status APIs.
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
  - Render local backup status.
- Modify: `windows/codex_session_manager_electron/src/index.html`
  - Add backup status UI shell.
- Modify: `windows/codex_session_manager_electron/src/styles.css`
  - Add compact backup status styles.

### Documentation

- Modify: `README.md`
  - Document first-stage local incremental backup behavior.
- Modify: `docs/操作手册.md`
  - Add install, status, diagnostics, and recovery notes.

---

### Task 1: Add Swift Core Target and Backup Path Model

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CodexSessionVaultCore/Backup/BackupModels.swift`
- Create: `Sources/CodexSessionVaultCore/Backup/BackupPaths.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift`

- [ ] **Step 1: Write the failing Swift path tests**

Create `Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class BackupPathsTests: XCTestCase {
    func testDefaultLayoutUsesVaultIncrementalBackups() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let paths = BackupPaths(homeDirectory: home)

        XCTAssertEqual(paths.codexRoot.path, "/Users/alice/.codex")
        XCTAssertEqual(paths.backupRoot.path, "/Users/alice/.codex-session-vault/incremental-backups")
        XCTAssertEqual(paths.manifestURL.path, "/Users/alice/.codex-session-vault/incremental-backups/manifest.json")
        XCTAssertEqual(paths.cursorDatabaseURL.path, "/Users/alice/.codex-session-vault/incremental-backups/cursors.sqlite")
        XCTAssertEqual(paths.statusURL.path, "/Users/alice/.codex-session-vault/incremental-backups/status.json")
        XCTAssertEqual(paths.logURL.path, "/Users/alice/.codex-session-vault/incremental-backups/logs/backup-agent.log") // reserved path; first stage does not write rolling logs
    }

    func testBackupFilePathUsesFirstSeenDateDirectoriesAndSessionIdFileName() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let paths = BackupPaths(homeDirectory: home)
        let date = ISO8601DateFormatter().date(from: "2026-07-04T10:12:00Z")!

        let url = paths.backupFileURL(sessionID: "session-123", firstSeenAt: date)

        XCTAssertEqual(
            url.path,
            "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04/session-123.jsonl"
        )
    }

    func testRelativeBackupPathIsManifestFriendly() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let paths = BackupPaths(homeDirectory: home)
        let file = URL(fileURLWithPath: "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04/session-123.jsonl")

        XCTAssertEqual(paths.relativeBackupPath(for: file), "sessions/2026/07/04/session-123.jsonl")
    }
}
```

- [ ] **Step 2: Run the failing Swift test**

Run:

```bash
swift test --filter BackupPathsTests
```

Expected: FAIL because `CodexSessionVaultCore` and `BackupPaths` do not exist.

- [ ] **Step 3: Add the SwiftPM library and test target**

Modify `Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexSessionVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSessionVault", targets: ["CodexSessionVault"]),
        .library(name: "CodexSessionVaultCore", targets: ["CodexSessionVaultCore"])
    ],
    targets: [
        .target(
            name: "CodexSessionVaultCore",
            path: "Sources/CodexSessionVaultCore"
        ),
        .executableTarget(
            name: "CodexSessionVault",
            dependencies: ["CodexSessionVaultCore"],
            path: "Sources/CodexSessionVault"
        ),
        .testTarget(
            name: "CodexSessionVaultCoreTests",
            dependencies: ["CodexSessionVaultCore"],
            path: "Tests/CodexSessionVaultCoreTests"
        )
    ]
)
```

- [ ] **Step 4: Add backup models**

Create `Sources/CodexSessionVaultCore/Backup/BackupModels.swift`:

```swift
import Foundation

public enum BackupRunMode: String, Codable, Sendable {
    case watching
    case polling
}

public enum BackupHealthStatus: String, Codable, Sendable {
    case running
    case waiting
    case error
    case paused
}

public struct BackupSessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var sourcePath: String
    public var backupPath: String
    public var title: String?
    public var firstSeenAt: Date
    public var lastBackedUpAt: Date?
    public var lineCount: Int
    public var bytesBackedUp: Int64
    public var status: String

    public init(
        sessionId: String,
        sourcePath: String,
        backupPath: String,
        title: String?,
        firstSeenAt: Date,
        lastBackedUpAt: Date?,
        lineCount: Int,
        bytesBackedUp: Int64,
        status: String
    ) {
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.backupPath = backupPath
        self.title = title
        self.firstSeenAt = firstSeenAt
        self.lastBackedUpAt = lastBackedUpAt
        self.lineCount = lineCount
        self.bytesBackedUp = bytesBackedUp
        self.status = status
    }
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var codexRoot: String
    public var backupRoot: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sessions: [String: BackupSessionRecord]

    public init(
        version: Int = 1,
        codexRoot: String,
        backupRoot: String,
        createdAt: Date,
        updatedAt: Date,
        sessions: [String: BackupSessionRecord] = [:]
    ) {
        self.version = version
        self.codexRoot = codexRoot
        self.backupRoot = backupRoot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessions = sessions
    }
}

public struct BackupStatus: Codable, Equatable, Sendable {
    public var agentVersion: String
    public var enabled: Bool
    public var status: BackupHealthStatus
    public var mode: BackupRunMode
    public var codexRoot: String
    public var backupRoot: String
    public var firstRunAt: Date
    public var lastStartedAt: Date
    public var lastHeartbeatAt: Date
    public var lastBackupAt: Date?
    public var sessionCount: Int
    public var lineCount: Int
    public var bytesBackedUp: Int64
    public var autoStartEnabled: Bool
    public var lastError: String?

    public init(
        agentVersion: String,
        enabled: Bool,
        status: BackupHealthStatus,
        mode: BackupRunMode,
        codexRoot: String,
        backupRoot: String,
        firstRunAt: Date,
        lastStartedAt: Date,
        lastHeartbeatAt: Date,
        lastBackupAt: Date?,
        sessionCount: Int,
        lineCount: Int,
        bytesBackedUp: Int64,
        autoStartEnabled: Bool,
        lastError: String?
    ) {
        self.agentVersion = agentVersion
        self.enabled = enabled
        self.status = status
        self.mode = mode
        self.codexRoot = codexRoot
        self.backupRoot = backupRoot
        self.firstRunAt = firstRunAt
        self.lastStartedAt = lastStartedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastBackupAt = lastBackupAt
        self.sessionCount = sessionCount
        self.lineCount = lineCount
        self.bytesBackedUp = bytesBackedUp
        self.autoStartEnabled = autoStartEnabled
        self.lastError = lastError
    }
}
```

- [ ] **Step 5: Add BackupPaths**

Create `Sources/CodexSessionVaultCore/Backup/BackupPaths.swift`:

```swift
import Foundation

public struct BackupPaths: Sendable {
    public let homeDirectory: URL
    public let codexRoot: URL
    public let vaultRoot: URL
    public let backupRoot: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexRoot: URL? = nil,
        vaultRoot: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.codexRoot = codexRoot ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        self.vaultRoot = vaultRoot ?? homeDirectory.appendingPathComponent(".codex-session-vault", isDirectory: true)
        self.backupRoot = self.vaultRoot.appendingPathComponent("incremental-backups", isDirectory: true)
    }

    public var manifestURL: URL {
        backupRoot.appendingPathComponent("manifest.json", isDirectory: false)
    }

    public var cursorDatabaseURL: URL {
        backupRoot.appendingPathComponent("cursors.sqlite", isDirectory: false)
    }

    public var statusURL: URL {
        backupRoot.appendingPathComponent("status.json", isDirectory: false)
    }

    public var sessionsRootURL: URL {
        backupRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    public var logsRootURL: URL {
        backupRoot.appendingPathComponent("logs", isDirectory: true)
    }

    public var logURL: URL {
        // Reserved for a future rolling log; first-stage diagnostics use status/manifest/cursor files.
        logsRootURL.appendingPathComponent("backup-agent.log", isDirectory: false)
    }

    public var restoreStagingRootURL: URL {
        vaultRoot.appendingPathComponent("incremental-restore-staging", isDirectory: true)
    }

    public func backupFileURL(sessionID: String, firstSeenAt: Date) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: firstSeenAt)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        let day = String(format: "%02d", components.day ?? 1)
        return sessionsRootURL
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    public func relativeBackupPath(for fileURL: URL) -> String {
        let root = backupRoot.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return fileURL.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }
}
```

- [ ] **Step 6: Run Swift path tests**

Run:

```bash
swift test --filter BackupPathsTests
```

Expected: PASS.

- [ ] **Step 7: Commit Swift path foundation**

Run:

```bash
git add Package.swift Sources/CodexSessionVaultCore/Backup/BackupModels.swift Sources/CodexSessionVaultCore/Backup/BackupPaths.swift Tests/CodexSessionVaultCoreTests/BackupPathsTests.swift
git commit -m "feat: add backup core path layout"
```

---

### Task 2: Implement Swift Session Identity and Manifest Store

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/SessionIdentity.swift`
- Create: `Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift`
- Test: `Tests/CodexSessionVaultCoreTests/SessionIdentityTests.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupManifestStoreTests.swift`

- [ ] **Step 1: Write failing session identity tests**

Create `Tests/CodexSessionVaultCoreTests/SessionIdentityTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class SessionIdentityTests: XCTestCase {
    func testExtractsSessionIdFromCodexJsonlFilename() throws {
        let url = URL(fileURLWithPath: "/Users/alice/.codex/sessions/2026/07/04/0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab.jsonl")

        XCTAssertEqual(SessionIdentity.sessionID(from: url), "0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab")
    }

    func testReturnsNilForNonJsonlFile() {
        let url = URL(fileURLWithPath: "/Users/alice/.codex/sessions/readme.txt")

        XCTAssertNil(SessionIdentity.sessionID(from: url))
    }

    func testExtractsTitleFromFirstUserMessage() {
        let line = #"{"type":"message","role":"user","content":[{"type":"input_text","text":"请帮我设计备份方案"}]}"#

        XCTAssertEqual(SessionIdentity.title(fromJSONLine: line), "请帮我设计备份方案")
    }
}
```

- [ ] **Step 2: Write failing manifest store tests**

Create `Tests/CodexSessionVaultCoreTests/BackupManifestStoreTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class BackupManifestStoreTests: XCTestCase {
    func testCreatesDefaultManifestWhenFileIsMissing() throws {
        let root = temporaryDirectory()
        let paths = BackupPaths(homeDirectory: root)
        let store = BackupManifestStore(manifestURL: paths.manifestURL)

        let manifest = try store.loadOrCreate(codexRoot: paths.codexRoot.path, backupRoot: paths.backupRoot.path, now: fixedDate())

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.codexRoot, paths.codexRoot.path)
        XCTAssertEqual(manifest.backupRoot, paths.backupRoot.path)
        XCTAssertTrue(manifest.sessions.isEmpty)
    }

    func testSavesAndLoadsManifestAtomically() throws {
        let root = temporaryDirectory()
        let paths = BackupPaths(homeDirectory: root)
        let store = BackupManifestStore(manifestURL: paths.manifestURL)
        let date = fixedDate()
        var manifest = BackupManifest(codexRoot: paths.codexRoot.path, backupRoot: paths.backupRoot.path, createdAt: date, updatedAt: date)
        manifest.sessions["session-1"] = BackupSessionRecord(
            sessionId: "session-1",
            sourcePath: "/source/session-1.jsonl",
            backupPath: "sessions/2026/07/04/session-1.jsonl",
            title: "Hello",
            firstSeenAt: date,
            lastBackedUpAt: date,
            lineCount: 2,
            bytesBackedUp: 42,
            status: "active"
        )

        try store.save(manifest)
        let reloaded = try store.loadOrCreate(codexRoot: paths.codexRoot.path, backupRoot: paths.backupRoot.path, now: date)

        XCTAssertEqual(reloaded.sessions["session-1"]?.title, "Hello")
        XCTAssertEqual(reloaded.sessions["session-1"]?.lineCount, 2)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2026-07-04T10:00:00Z")!
    }
}
```

- [ ] **Step 3: Run failing tests**

Run:

```bash
swift test --filter "SessionIdentityTests|BackupManifestStoreTests"
```

Expected: FAIL because `SessionIdentity` and `BackupManifestStore` do not exist.

- [ ] **Step 4: Implement SessionIdentity**

Create `Sources/CodexSessionVaultCore/Backup/SessionIdentity.swift`:

```swift
import Foundation

public enum SessionIdentity {
    public static func sessionID(from fileURL: URL) -> String? {
        guard fileURL.pathExtension.lowercased() == "jsonl" else { return nil }
        let name = fileURL.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    public static func title(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let role = object["role"] as? String,
           role == "user",
           let text = textFromContent(object["content"]) {
            return normalizedTitle(text)
        }

        if let type = object["type"] as? String,
           type == "message",
           let role = object["role"] as? String,
           role == "user",
           let text = textFromContent(object["content"]) {
            return normalizedTitle(text)
        }

        if let item = object["item"] as? [String: Any],
           let role = item["role"] as? String,
           role == "user",
           let text = textFromContent(item["content"]) {
            return normalizedTitle(text)
        }

        return nil
    }

    private static func textFromContent(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part in
                part["text"] as? String
            }.joined(separator: " ")
        }
        return nil
    }

    private static func normalizedTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }
}
```

- [ ] **Step 5: Implement BackupManifestStore**

Create `Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift`:

```swift
import Foundation

public final class BackupManifestStore {
    private let manifestURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loadOrCreate(codexRoot: String, backupRoot: String, now: Date = Date()) throws -> BackupManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return BackupManifest(codexRoot: codexRoot, backupRoot: backupRoot, createdAt: now, updatedAt: now)
        }
        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(BackupManifest.self, from: data)
    }

    public func save(_ manifest: BackupManifest) throws {
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }
}
```

- [ ] **Step 6: Run manifest and identity tests**

Run:

```bash
swift test --filter "SessionIdentityTests|BackupManifestStoreTests"
```

Expected: PASS.

- [ ] **Step 7: Commit Swift manifest and identity**

Run:

```bash
git add Sources/CodexSessionVaultCore/Backup/SessionIdentity.swift Sources/CodexSessionVaultCore/Backup/BackupManifestStore.swift Tests/CodexSessionVaultCoreTests/SessionIdentityTests.swift Tests/CodexSessionVaultCoreTests/BackupManifestStoreTests.swift
git commit -m "feat: add backup manifest and session identity"
```

---

### Task 3: Implement Swift SessionTailer and Cursor Store

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/SessionTailer.swift`
- Create: `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`
- Test: `Tests/CodexSessionVaultCoreTests/SessionTailerTests.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift`

- [ ] **Step 1: Write failing SessionTailer tests**

Create `Tests/CodexSessionVaultCoreTests/SessionTailerTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class SessionTailerTests: XCTestCase {
    func testReadsOnlyCompleteLinesFromOffset() throws {
        let file = temporaryFile(contents: #"{"a":1}"# + "\n" + #"{"b":2}"# + "\n" + #"{"partial":true}"#)
        let tailer = SessionTailer(maxReadBytes: 1024)

        let result = try tailer.readNewCompleteLines(from: file, offset: 0)

        XCTAssertEqual(result.lines.map { String(data: $0, encoding: .utf8)! }, [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(result.nextOffset, Int64(#"{"a":1}"#.utf8.count + 1 + #"{"b":2}"#.utf8.count + 1))
        XCTAssertEqual(String(data: result.pendingPartialLine, encoding: .utf8), #"{"partial":true}"#)
    }

    func testReadsFromExistingOffset() throws {
        let first = #"{"a":1}"# + "\n"
        let file = temporaryFile(contents: first + #"{"b":2}"# + "\n")
        let tailer = SessionTailer(maxReadBytes: 1024)

        let result = try tailer.readNewCompleteLines(from: file, offset: Int64(first.utf8.count))

        XCTAssertEqual(result.lines.map { String(data: $0, encoding: .utf8)! }, [#"{"b":2}"#])
    }

    private func temporaryFile(contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        try! contents.data(using: .utf8)!.write(to: url)
        return url
    }
}
```

- [ ] **Step 2: Write failing cursor store tests**

Create `Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class BackupCursorStoreTests: XCTestCase {
    func testUpsertsAndLoadsCursor() throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        let store = BackupCursorStore(databaseURL: db)
        try store.open()

        let cursor = BackupCursor(
            sessionId: "session-1",
            sourcePath: "/source/session-1.jsonl",
            backupPath: "sessions/2026/07/04/session-1.jsonl",
            lastByteOffset: 100,
            lastSourceSize: 120,
            lastSourceModifiedAt: 1_788_000_000,
            lineCount: 3,
            pendingPartialLine: Data("partial".utf8),
            status: "active",
            lastError: nil,
            updatedAt: 1_788_000_001
        )

        try store.upsert(cursor)
        let loaded = try store.cursor(sourcePath: "/source/session-1.jsonl")

        XCTAssertEqual(loaded?.sessionId, "session-1")
        XCTAssertEqual(loaded?.lastByteOffset, 100)
        XCTAssertEqual(loaded?.pendingPartialLine, Data("partial".utf8))
    }
}
```

- [ ] **Step 3: Run failing tests**

Run:

```bash
swift test --filter "SessionTailerTests|BackupCursorStoreTests"
```

Expected: FAIL because `SessionTailer`, `BackupCursor`, and `BackupCursorStore` do not exist.

- [ ] **Step 4: Implement SessionTailer**

Create `Sources/CodexSessionVaultCore/Backup/SessionTailer.swift`:

```swift
import Foundation

public struct TailReadResult: Equatable, Sendable {
    public var lines: [Data]
    public var nextOffset: Int64
    public var pendingPartialLine: Data
}

public final class SessionTailer {
    private let maxReadBytes: Int

    public init(maxReadBytes: Int = 1_048_576) {
        self.maxReadBytes = maxReadBytes
    }

    public func readNewCompleteLines(from fileURL: URL, offset: Int64) throws -> TailReadResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(max(0, offset)))
        let data = try handle.read(upToCount: maxReadBytes) ?? Data()
        guard !data.isEmpty else {
            return TailReadResult(lines: [], nextOffset: offset, pendingPartialLine: Data())
        }

        var lines: [Data] = []
        var lineStart = data.startIndex
        var consumed = 0

        for index in data.indices {
            if data[index] == 0x0A {
                let line = data[lineStart..<index]
                if !line.isEmpty {
                    lines.append(Data(line))
                }
                let next = data.index(after: index)
                consumed = data.distance(from: data.startIndex, to: next)
                lineStart = next
            }
        }

        let pending = lineStart < data.endIndex ? Data(data[lineStart..<data.endIndex]) : Data()
        return TailReadResult(lines: lines, nextOffset: offset + Int64(consumed), pendingPartialLine: pending)
    }
}
```

- [ ] **Step 5: Implement BackupCursorStore**

Create `Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift`:

```swift
import Foundation

public struct BackupCursor: Equatable, Sendable {
    public var sessionId: String
    public var sourcePath: String
    public var backupPath: String
    public var lastByteOffset: Int64
    public var lastSourceSize: Int64
    public var lastSourceModifiedAt: TimeInterval
    public var lineCount: Int
    public var pendingPartialLine: Data
    public var status: String
    public var lastError: String?
    public var updatedAt: TimeInterval

    public init(
        sessionId: String,
        sourcePath: String,
        backupPath: String,
        lastByteOffset: Int64,
        lastSourceSize: Int64,
        lastSourceModifiedAt: TimeInterval,
        lineCount: Int,
        pendingPartialLine: Data,
        status: String,
        lastError: String?,
        updatedAt: TimeInterval
    ) {
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.backupPath = backupPath
        self.lastByteOffset = lastByteOffset
        self.lastSourceSize = lastSourceSize
        self.lastSourceModifiedAt = lastSourceModifiedAt
        self.lineCount = lineCount
        self.pendingPartialLine = pendingPartialLine
        self.status = status
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public final class BackupCursorStore {
    private let databaseURL: URL
    private let sqlite = "/usr/bin/sqlite3"

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func open() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runSQL("""
        CREATE TABLE IF NOT EXISTS cursors (
          source_path TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          backup_path TEXT NOT NULL,
          last_byte_offset INTEGER NOT NULL,
          last_source_size INTEGER NOT NULL,
          last_source_modified_at REAL NOT NULL,
          line_count INTEGER NOT NULL,
          pending_partial_line TEXT NOT NULL,
          status TEXT NOT NULL,
          last_error TEXT,
          updated_at REAL NOT NULL
        );
        """)
    }

    public func cursor(sourcePath: String) throws -> BackupCursor? {
        let output = try runSQL("""
        SELECT session_id, source_path, backup_path, last_byte_offset, last_source_size,
               last_source_modified_at, line_count, pending_partial_line, status,
               COALESCE(last_error, ''), updated_at
        FROM cursors
        WHERE source_path = \(Self.sqlString(sourcePath));
        """, captureOutput: true)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: "|")
        guard parts.count == 11 else { return nil }
        return BackupCursor(
            sessionId: parts[0],
            sourcePath: parts[1],
            backupPath: parts[2],
            lastByteOffset: Int64(parts[3]) ?? 0,
            lastSourceSize: Int64(parts[4]) ?? 0,
            lastSourceModifiedAt: TimeInterval(parts[5]) ?? 0,
            lineCount: Int(parts[6]) ?? 0,
            pendingPartialLine: Data(base64Encoded: parts[7]) ?? Data(),
            status: parts[8],
            lastError: parts[9].isEmpty ? nil : parts[9],
            updatedAt: TimeInterval(parts[10]) ?? 0
        )
    }

    public func upsert(_ cursor: BackupCursor) throws {
        try runSQL("""
        INSERT INTO cursors (
          source_path, session_id, backup_path, last_byte_offset, last_source_size,
          last_source_modified_at, line_count, pending_partial_line, status, last_error, updated_at
        ) VALUES (
          \(Self.sqlString(cursor.sourcePath)),
          \(Self.sqlString(cursor.sessionId)),
          \(Self.sqlString(cursor.backupPath)),
          \(cursor.lastByteOffset),
          \(cursor.lastSourceSize),
          \(cursor.lastSourceModifiedAt),
          \(cursor.lineCount),
          \(Self.sqlString(cursor.pendingPartialLine.base64EncodedString())),
          \(Self.sqlString(cursor.status)),
          \(cursor.lastError.map(Self.sqlString) ?? "NULL"),
          \(cursor.updatedAt)
        )
        ON CONFLICT(source_path) DO UPDATE SET
          session_id=excluded.session_id,
          backup_path=excluded.backup_path,
          last_byte_offset=excluded.last_byte_offset,
          last_source_size=excluded.last_source_size,
          last_source_modified_at=excluded.last_source_modified_at,
          line_count=excluded.line_count,
          pending_partial_line=excluded.pending_partial_line,
          status=excluded.status,
          last_error=excluded.last_error,
          updated_at=excluded.updated_at;
        """)
    }

    private func runSQL(_ sql: String, captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite)
        process.arguments = [databaseURL.path, sql]
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
        }
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BackupCursorStore", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    private static func sqlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
```

- [ ] **Step 6: Run tailer and cursor tests**

Run:

```bash
swift test --filter "SessionTailerTests|BackupCursorStoreTests"
```

Expected: PASS.

- [ ] **Step 7: Commit Swift tailer and cursor store**

Run:

```bash
git add Sources/CodexSessionVaultCore/Backup/SessionTailer.swift Sources/CodexSessionVaultCore/Backup/BackupCursorStore.swift Tests/CodexSessionVaultCoreTests/SessionTailerTests.swift Tests/CodexSessionVaultCoreTests/BackupCursorStoreTests.swift
git commit -m "feat: add Swift backup tailer and cursor store"
```

---

### Task 4: Implement Swift BackupAgent Scan and Polling Loop

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`

- [ ] **Step 1: Write failing BackupAgent integration test**

Create `Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class BackupAgentTests: XCTestCase {
    func testInitialScanBacksUpExistingJsonlLinesAndUpdatesManifest() throws {
        let root = temporaryDirectory()
        let codex = root.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codex.appendingPathComponent("sessions/2026/07/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let source = sessions.appendingPathComponent("session-1.jsonl")
        try (#"{"type":"message","role":"user","content":"hello"}"# + "\n").data(using: .utf8)!.write(to: source)

        let paths = BackupPaths(homeDirectory: root)
        let agent = BackupAgent(paths: paths, now: { fixedDate() })

        try agent.performOneShotScan()

        let backup = paths.backupFileURL(sessionID: "session-1", firstSeenAt: fixedDate())
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), #"{"type":"message","role":"user","content":"hello"}"# + "\n")

        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: fixedDate()
        )
        XCTAssertEqual(manifest.sessions["session-1"]?.lineCount, 1)
        XCTAssertEqual(manifest.sessions["session-1"]?.title, "hello")
    }

    func testSecondScanOnlyAppendsNewLines() throws {
        let root = temporaryDirectory()
        let codex = root.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codex.appendingPathComponent("sessions/2026/07/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let source = sessions.appendingPathComponent("session-1.jsonl")
        try (#"{"role":"user","content":"one"}"# + "\n").data(using: .utf8)!.write(to: source)

        let paths = BackupPaths(homeDirectory: root)
        let agent = BackupAgent(paths: paths, now: { fixedDate() })
        try agent.performOneShotScan()

        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: (#"{"role":"assistant","content":"two"}"# + "\n").data(using: .utf8)!)
        try handle.close()

        try agent.performOneShotScan()

        let backup = paths.backupFileURL(sessionID: "session-1", firstSeenAt: fixedDate())
        let lines = try String(contentsOf: backup, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0]), #"{"role":"user","content":"one"}"#)
        XCTAssertEqual(String(lines[1]), #"{"role":"assistant","content":"two"}"#)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2026-07-04T10:00:00Z")!
    }
}
```

- [ ] **Step 2: Run failing BackupAgent test**

Run:

```bash
swift test --filter BackupAgentTests
```

Expected: FAIL because `BackupAgent` does not exist.

- [ ] **Step 3: Implement BackupAgent scan and polling loop**

Create `Sources/CodexSessionVaultCore/Backup/BackupAgent.swift`:

```swift
import Foundation

public final class BackupAgent {
    private let paths: BackupPaths
    private let now: () -> Date
    private let fileManager: FileManager
    private let manifestStore: BackupManifestStore
    private let cursorStore: BackupCursorStore
    private let tailer: SessionTailer
    private var pollingTask: Task<Void, Never>?

    public init(
        paths: BackupPaths = BackupPaths(),
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.now = now
        self.fileManager = fileManager
        self.manifestStore = BackupManifestStore(manifestURL: paths.manifestURL)
        self.cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        self.tailer = SessionTailer()
    }

    public func startPolling(intervalSeconds: UInt64 = 10) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try self?.performOneShotScan()
                } catch {
                    try? self?.writeErrorStatus(error)
                }
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func performOneShotScan() throws {
        try ensureDirectories()
        try cursorStore.open()
        var manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now()
        )

        for source in try discoverSessionFiles() {
            try process(sourceURL: source, manifest: &manifest)
        }

        manifest.updatedAt = now()
        try manifestStore.save(manifest)
        try writeStatus(manifest: manifest, status: .running, mode: .polling, error: nil)
    }

    private func writeErrorStatus(_ error: Error) throws {
        let manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now()
        )
        try writeStatus(manifest: manifest, status: .error, mode: .polling, error: error.localizedDescription)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sessionsRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logsRootURL, withIntermediateDirectories: true)
    }

    private func discoverSessionFiles() throws -> [URL] {
        let roots = [
            paths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
            paths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) {
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                    files.append(url)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func process(sourceURL: URL, manifest: inout BackupManifest) throws {
        guard let sessionID = SessionIdentity.sessionID(from: sourceURL) else { return }
        let sourcePath = sourceURL.path
        let existingCursor = try cursorStore.cursor(sourcePath: sourcePath)
        let firstSeen = manifest.sessions[sessionID]?.firstSeenAt ?? now()
        let backupURL = manifest.sessions[sessionID].map { paths.backupRoot.appendingPathComponent($0.backupPath) }
            ?? paths.backupFileURL(sessionID: sessionID, firstSeenAt: firstSeen)
        let relativeBackupPath = paths.relativeBackupPath(for: backupURL)
        let offset = existingCursor?.lastByteOffset ?? 0
        let read = try tailer.readNewCompleteLines(from: sourceURL, offset: offset)
        guard !read.lines.isEmpty || manifest.sessions[sessionID] == nil else { return }

        try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !read.lines.isEmpty {
            let handle: FileHandle
            if fileManager.fileExists(atPath: backupURL.path) {
                handle = try FileHandle(forWritingTo: backupURL)
                try handle.seekToEnd()
            } else {
                fileManager.createFile(atPath: backupURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: backupURL)
            }
            for line in read.lines {
                try handle.write(contentsOf: line)
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.close()
        }

        let old = manifest.sessions[sessionID]
        let title = old?.title ?? read.lines.lazy.compactMap { line in
            String(data: line, encoding: .utf8).flatMap(SessionIdentity.title(fromJSONLine:))
        }.first
        let newLineCount = (old?.lineCount ?? existingCursor?.lineCount ?? 0) + read.lines.count
        let bytesAdded = read.lines.reduce(Int64(0)) { $0 + Int64($1.count + 1) }
        let newBytes = (old?.bytesBackedUp ?? 0) + bytesAdded
        let backupDate = read.lines.isEmpty ? old?.lastBackedUpAt : now()
        manifest.sessions[sessionID] = BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            title: title,
            firstSeenAt: firstSeen,
            lastBackedUpAt: backupDate,
            lineCount: newLineCount,
            bytesBackedUp: newBytes,
            status: "active"
        )

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try cursorStore.upsert(BackupCursor(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            lastByteOffset: read.nextOffset,
            lastSourceSize: Int64(values.fileSize ?? 0),
            lastSourceModifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            lineCount: newLineCount,
            pendingPartialLine: read.pendingPartialLine,
            status: "active",
            lastError: nil,
            updatedAt: now().timeIntervalSince1970
        ))
    }

    private func writeStatus(manifest: BackupManifest, status: BackupHealthStatus, mode: BackupRunMode, error: String?) throws {
        let lineCount = manifest.sessions.values.reduce(0) { $0 + $1.lineCount }
        let bytes = manifest.sessions.values.reduce(Int64(0)) { $0 + $1.bytesBackedUp }
        let current = BackupStatus(
            agentVersion: "1.0.0",
            enabled: true,
            status: status,
            mode: mode,
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            firstRunAt: manifest.createdAt,
            lastStartedAt: now(),
            lastHeartbeatAt: now(),
            lastBackupAt: manifest.sessions.values.compactMap(\.lastBackedUpAt).max(),
            sessionCount: manifest.sessions.count,
            lineCount: lineCount,
            bytesBackedUp: bytes,
            autoStartEnabled: false,
            lastError: error
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try fileManager.createDirectory(at: paths.statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(current).write(to: paths.statusURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run BackupAgent tests**

Run:

```bash
swift test --filter BackupAgentTests
```

Expected: PASS.

- [ ] **Step 5: Run all Swift tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit Swift backup agent**

Run:

```bash
git add Sources/CodexSessionVaultCore/Backup/BackupAgent.swift Tests/CodexSessionVaultCoreTests/BackupAgentTests.swift
git commit -m "feat: add Swift local backup agent"
```

---

### Task 5: Implement Swift Recovery Builder

**Files:**
- Create: `Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift`
- Test: `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`

- [ ] **Step 1: Write failing recovery builder test**

Create `Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift`:

```swift
import XCTest
@testable import CodexSessionVaultCore

final class BackupRecoveryBuilderTests: XCTestCase {
    func testBuildsFileSnapshotFromIncrementalBackup() throws {
        let root = temporaryDirectory()
        let paths = BackupPaths(homeDirectory: root)
        let backup = paths.backupFileURL(sessionID: "session-1", firstSeenAt: fixedDate())
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"role":"user","content":"hello"}"# + "\n").data(using: .utf8)!.write(to: backup)

        let record = BackupSessionRecord(
            sessionId: "session-1",
            sourcePath: paths.codexRoot.appendingPathComponent("sessions/session-1.jsonl").path,
            backupPath: paths.relativeBackupPath(for: backup),
            title: "hello",
            firstSeenAt: fixedDate(),
            lastBackedUpAt: fixedDate(),
            lineCount: 1,
            bytesBackedUp: 34,
            status: "active"
        )
        let manifest = BackupManifest(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            createdAt: fixedDate(),
            updatedAt: fixedDate(),
            sessions: ["session-1": record]
        )
        try BackupManifestStore(manifestURL: paths.manifestURL).save(manifest)

        let builder = BackupRecoveryBuilder(paths: paths, now: { fixedDate() })
        let package = try builder.buildRecoveryPackage(sessionIDs: ["session-1"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.snapshotJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.dataURL.appendingPathComponent("sessions/recovered/session-1.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.dataURL.appendingPathComponent("session_index.jsonl").path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2026-07-04T10:00:00Z")!
    }
}
```

- [ ] **Step 2: Run failing recovery builder test**

Run:

```bash
swift test --filter BackupRecoveryBuilderTests
```

Expected: FAIL because `BackupRecoveryBuilder` does not exist.

- [ ] **Step 3: Implement BackupRecoveryBuilder**

Create `Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift`:

```swift
import Foundation

public struct BackupRecoveryPackage: Equatable, Sendable {
    public let rootURL: URL
    public let dataURL: URL
    public let snapshotJSON: URL
}

public final class BackupRecoveryBuilder {
    private let paths: BackupPaths
    private let now: () -> Date
    private let fileManager: FileManager

    public init(paths: BackupPaths = BackupPaths(), now: @escaping () -> Date = Date.init, fileManager: FileManager = .default) {
        self.paths = paths
        self.now = now
        self.fileManager = fileManager
    }

    public func buildRecoveryPackage(sessionIDs: [String]) throws -> BackupRecoveryPackage {
        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now()
        )
        let idSet = Set(sessionIDs)
        let records = manifest.sessions.values
            .filter { idSet.contains($0.sessionId) }
            .sorted { $0.sessionId < $1.sessionId }
        guard !records.isEmpty else {
            throw NSError(domain: "BackupRecoveryBuilder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No backed up sessions selected"])
        }

        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let root = paths.restoreStagingRootURL.appendingPathComponent(stamp, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let recovered = data.appendingPathComponent("sessions/recovered", isDirectory: true)
        try fileManager.createDirectory(at: recovered, withIntermediateDirectories: true)

        var indexLines: [String] = []
        for record in records {
            let src = paths.backupRoot.appendingPathComponent(record.backupPath)
            let dst = recovered.appendingPathComponent("\(record.sessionId).jsonl")
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            try fileManager.copyItem(at: src, to: dst)
            let index: [String: Any] = [
                "id": record.sessionId,
                "title": record.title ?? record.sessionId,
                "rollout_path": paths.codexRoot.appendingPathComponent("sessions/recovered/\(record.sessionId).jsonl").path,
                "updated_at": ISO8601DateFormatter().string(from: record.lastBackedUpAt ?? record.firstSeenAt)
            ]
            let line = try String(data: JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]), encoding: .utf8)!
            indexLines.append(line)
        }
        try indexLines.joined(separator: "\n").appending("\n").write(
            to: data.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot: [String: Any] = [
            "id": "incremental-\(stamp)",
            "name": "Incremental Backup Recovery \(stamp)",
            "createdAt": ISO8601DateFormatter().string(from: now()),
            "codexRoot": paths.codexRoot.path,
            "reason": "incremental-recovery",
            "kind": "system",
            "sessionCount": records.count,
            "archivedSessionCount": 0,
            "includedPaths": ["sessions", "session_index.jsonl"],
            "appVersion": "incremental-backup-v1"
        ]
        let snapshotJSON = root.appendingPathComponent("snapshot.json")
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: snapshotJSON, options: .atomic)
        return BackupRecoveryPackage(rootURL: root, dataURL: data, snapshotJSON: snapshotJSON)
    }
}
```

- [ ] **Step 4: Run recovery builder test**

Run:

```bash
swift test --filter BackupRecoveryBuilderTests
```

Expected: PASS.

- [ ] **Step 5: Commit Swift recovery builder**

Run:

```bash
git add Sources/CodexSessionVaultCore/Backup/BackupRecoveryBuilder.swift Tests/CodexSessionVaultCoreTests/BackupRecoveryBuilderTests.swift
git commit -m "feat: build recovery packages from incremental backups"
```

---

### Task 6: Integrate macOS Backup Status Into the App

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`

- [ ] **Step 1: Build before changes**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 2: Add import and model state**

Modify `Sources/CodexSessionVault/main.swift`:

```swift
import CodexSessionVaultCore
```

Inside `VaultModel`, add:

```swift
    @Published var backupStatus = "本地增量备份：未启动"
    @Published var backupStatusDetail = "等待启动"
    private var localBackupAgent: BackupAgent?
```

- [ ] **Step 3: Start the agent after initial refresh**

Inside `VaultModel.init(...)`, after `refresh()` add:

```swift
            startLocalIncrementalBackup()
```

Add method inside `VaultModel`:

```swift
    func startLocalIncrementalBackup() {
        let paths = BackupPaths(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            codexRoot: URL(fileURLWithPath: codexRoot, isDirectory: true),
            vaultRoot: URL(fileURLWithPath: vaultRoot, isDirectory: true)
        )
        let agent = BackupAgent(paths: paths)
        localBackupAgent = agent
        agent.startPolling(intervalSeconds: 10)
        Task {
            do {
                try agent.performOneShotScan()
                await MainActor.run {
                    self.backupStatus = "本地增量备份：运行中"
                    self.backupStatusDetail = "轮询模式，每 10 秒检查新增对话"
                }
            } catch {
                await MainActor.run {
                    self.backupStatus = "本地增量备份：异常"
                    self.backupStatusDetail = error.localizedDescription
                }
            }
        }
    }
```

- [ ] **Step 4: Add compact UI status in the top bar**

In `ContentView` top bar next to existing status cards, add:

```swift
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(model.backupStatus)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 0.18, green: 0.26, blue: 0.44))
                            Text(model.backupStatusDetail)
                                .font(.caption2)
                                .foregroundStyle(Color(red: 0.42, green: 0.50, blue: 0.66))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.52))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(0.82), lineWidth: 1)
                        )
```

- [ ] **Step 5: Build macOS app**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 6: Run Swift tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 7: Commit macOS app integration**

Run:

```bash
git add Sources/CodexSessionVault/main.swift
git commit -m "feat: show local incremental backup status on macOS"
```

---

### Task 7: Add Windows Backup Module Tests and Path Utilities

**Files:**
- Modify: `windows/codex_session_manager_electron/package.json`
- Create: `windows/codex_session_manager_electron/src/backup/models.js`
- Create: `windows/codex_session_manager_electron/src/backup/paths.js`
- Create: `windows/codex_session_manager_electron/src/backup/session-identity.js`
- Test: `windows/codex_session_manager_electron/test/backup/paths.test.js`
- Test: `windows/codex_session_manager_electron/test/backup/session-identity.test.js`

- [ ] **Step 1: Add Node test script**

Modify `windows/codex_session_manager_electron/package.json` scripts:

```json
{
  "scripts": {
    "start": "electron .",
    "test": "node --test test/backup/*.test.js",
    "package:win": "electron-packager . codex_session_manager --platform=win32 --arch=x64 --out=../../dist/win10-exe --overwrite --prune=true"
  }
}
```

- [ ] **Step 2: Write failing Windows path tests**

Create `windows/codex_session_manager_electron/test/backup/paths.test.js`:

```javascript
const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const { backupPaths } = require('../../src/backup/paths');

test('backupPaths builds local incremental backup layout', () => {
  const paths = backupPaths('C:\\Users\\alice');
  assert.equal(paths.codexRoot, path.join('C:\\Users\\alice', '.codex'));
  assert.equal(paths.backupRoot, path.join('C:\\Users\\alice', '.codex-session-vault', 'incremental-backups'));
  assert.equal(paths.manifestPath, path.join(paths.backupRoot, 'manifest.json'));
  assert.equal(paths.cursorDatabasePath, path.join(paths.backupRoot, 'cursors.sqlite'));
  assert.equal(paths.statusPath, path.join(paths.backupRoot, 'status.json'));
});

test('backupFilePath uses date folders and session id filename', () => {
  const paths = backupPaths('C:\\Users\\alice');
  const filePath = paths.backupFilePath('session-1', new Date('2026-07-04T10:00:00Z'));
  assert.equal(filePath, path.join(paths.backupRoot, 'sessions', '2026', '07', '04', 'session-1.jsonl'));
  assert.equal(paths.relativeBackupPath(filePath), path.join('sessions', '2026', '07', '04', 'session-1.jsonl'));
});
```

- [ ] **Step 3: Write failing Windows identity tests**

Create `windows/codex_session_manager_electron/test/backup/session-identity.test.js`:

```javascript
const assert = require('node:assert/strict');
const test = require('node:test');
const { sessionIdFromPath, titleFromJsonLine } = require('../../src/backup/session-identity');

test('sessionIdFromPath extracts id from jsonl filename', () => {
  assert.equal(sessionIdFromPath('C:\\Users\\alice\\.codex\\sessions\\session-1.jsonl'), 'session-1');
});

test('sessionIdFromPath ignores non-jsonl files', () => {
  assert.equal(sessionIdFromPath('C:\\Users\\alice\\.codex\\sessions\\notes.txt'), null);
});

test('titleFromJsonLine extracts first user text', () => {
  const line = JSON.stringify({ type: 'message', role: 'user', content: [{ type: 'input_text', text: '请帮我备份 Codex' }] });
  assert.equal(titleFromJsonLine(line), '请帮我备份 Codex');
});
```

- [ ] **Step 4: Run failing Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: FAIL because backup modules do not exist.

- [ ] **Step 5: Implement Windows models and path utilities**

Create `windows/codex_session_manager_electron/src/backup/models.js`:

```javascript
const MANIFEST_VERSION = 1;
const AGENT_VERSION = '1.0.0';

module.exports = {
  MANIFEST_VERSION,
  AGENT_VERSION
};
```

Create `windows/codex_session_manager_electron/src/backup/paths.js`:

```javascript
const path = require('path');

function pad(value) {
  return String(value).padStart(2, '0');
}

function backupPaths(homeDir) {
  const codexRoot = path.join(homeDir, '.codex');
  const vaultRoot = path.join(homeDir, '.codex-session-vault');
  const backupRoot = path.join(vaultRoot, 'incremental-backups');
  return {
    homeDir,
    codexRoot,
    vaultRoot,
    backupRoot,
    manifestPath: path.join(backupRoot, 'manifest.json'),
    cursorDatabasePath: path.join(backupRoot, 'cursors.sqlite'),
    statusPath: path.join(backupRoot, 'status.json'),
    sessionsRoot: path.join(backupRoot, 'sessions'),
    logsRoot: path.join(backupRoot, 'logs'),
    logPath: path.join(backupRoot, 'logs', 'backup-agent.log'), // reserved; first stage does not write rolling logs
    restoreStagingRoot: path.join(vaultRoot, 'incremental-restore-staging'),
    backupFilePath(sessionId, firstSeenAt) {
      const date = new Date(firstSeenAt);
      const year = String(date.getUTCFullYear());
      const month = pad(date.getUTCMonth() + 1);
      const day = pad(date.getUTCDate());
      return path.join(backupRoot, 'sessions', year, month, day, `${sessionId}.jsonl`);
    },
    relativeBackupPath(filePath) {
      return path.relative(backupRoot, filePath);
    }
  };
}

module.exports = { backupPaths };
```

Create `windows/codex_session_manager_electron/src/backup/session-identity.js`:

```javascript
const path = require('path');

function sessionIdFromPath(filePath) {
  if (path.extname(filePath).toLowerCase() !== '.jsonl') return null;
  const id = path.basename(filePath, '.jsonl');
  return id || null;
}

function titleFromJsonLine(line) {
  try {
    const object = JSON.parse(line);
    if (object.role === 'user') return normalizeText(textFromContent(object.content));
    if (object.type === 'message' && object.role === 'user') return normalizeText(textFromContent(object.content));
    if (object.item && object.item.role === 'user') return normalizeText(textFromContent(object.item.content));
  } catch {
    return null;
  }
  return null;
}

function textFromContent(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((part) => part && part.text).filter(Boolean).join(' ');
  }
  return '';
}

function normalizeText(text) {
  const trimmed = String(text || '').trim();
  return trimmed ? trimmed.slice(0, 80) : null;
}

module.exports = { sessionIdFromPath, titleFromJsonLine };
```

- [ ] **Step 6: Run Windows path and identity tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: PASS.

- [ ] **Step 7: Commit Windows path foundation**

Run:

```bash
git add windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/src/backup/models.js windows/codex_session_manager_electron/src/backup/paths.js windows/codex_session_manager_electron/src/backup/session-identity.js windows/codex_session_manager_electron/test/backup/paths.test.js windows/codex_session_manager_electron/test/backup/session-identity.test.js
git commit -m "feat: add Windows backup path foundation"
```

---

### Task 8: Implement Windows Manifest, Cursor Store, Tailer, and Agent

**Files:**
- Create: `windows/codex_session_manager_electron/src/backup/manifest-store.js`
- Create: `windows/codex_session_manager_electron/src/backup/cursor-store.js`
- Create: `windows/codex_session_manager_electron/src/backup/session-tailer.js`
- Create: `windows/codex_session_manager_electron/src/backup/backup-agent.js`
- Test: `windows/codex_session_manager_electron/test/backup/agent.test.js`

- [ ] **Step 1: Write failing Windows agent test**

Create `windows/codex_session_manager_electron/test/backup/agent.test.js`:

```javascript
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { backupPaths } = require('../../src/backup/paths');
const { BackupAgent } = require('../../src/backup/backup-agent');

test('BackupAgent backs up existing jsonl and appends only new lines', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-backup-'));
  const paths = backupPaths(home);
  const sessionDir = path.join(paths.codexRoot, 'sessions', '2026', '07', '04');
  fs.mkdirSync(sessionDir, { recursive: true });
  const source = path.join(sessionDir, 'session-1.jsonl');
  fs.writeFileSync(source, '{"role":"user","content":"one"}\n', 'utf8');

  const agent = new BackupAgent({ paths, now: () => new Date('2026-07-04T10:00:00Z') });
  await agent.performOneShotScan();

  fs.appendFileSync(source, '{"role":"assistant","content":"two"}\n', 'utf8');
  await agent.performOneShotScan();

  const backup = paths.backupFilePath('session-1', new Date('2026-07-04T10:00:00Z'));
  const lines = fs.readFileSync(backup, 'utf8').trim().split('\n');
  assert.deepEqual(lines, ['{"role":"user","content":"one"}', '{"role":"assistant","content":"two"}']);

  const manifest = JSON.parse(fs.readFileSync(paths.manifestPath, 'utf8'));
  assert.equal(manifest.sessions['session-1'].lineCount, 2);
});
```

- [ ] **Step 2: Run failing Windows agent test**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: FAIL because manifest, cursor, tailer, and agent modules do not exist.

- [ ] **Step 3: Implement manifest store**

Create `windows/codex_session_manager_electron/src/backup/manifest-store.js`:

```javascript
const fs = require('fs');
const path = require('path');
const { MANIFEST_VERSION } = require('./models');

function loadOrCreateManifest(paths, now = new Date()) {
  if (!fs.existsSync(paths.manifestPath)) {
    return {
      version: MANIFEST_VERSION,
      codexRoot: paths.codexRoot,
      backupRoot: paths.backupRoot,
      createdAt: now.toISOString(),
      updatedAt: now.toISOString(),
      sessions: {}
    };
  }
  return JSON.parse(fs.readFileSync(paths.manifestPath, 'utf8'));
}

function saveManifest(paths, manifest) {
  fs.mkdirSync(path.dirname(paths.manifestPath), { recursive: true });
  const tmp = `${paths.manifestPath}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(manifest, null, 2), 'utf8');
  fs.renameSync(tmp, paths.manifestPath);
}

module.exports = { loadOrCreateManifest, saveManifest };
```

- [ ] **Step 4: Implement cursor store using sql.js**

Create `windows/codex_session_manager_electron/src/backup/cursor-store.js`:

```javascript
const fs = require('fs');
const path = require('path');
const initSqlJs = require('sql.js');

class CursorStore {
  constructor(databasePath) {
    this.databasePath = databasePath;
    this.SQL = null;
    this.db = null;
  }

  async open() {
    this.SQL = await initSqlJs();
    fs.mkdirSync(path.dirname(this.databasePath), { recursive: true });
    this.db = fs.existsSync(this.databasePath)
      ? new this.SQL.Database(fs.readFileSync(this.databasePath))
      : new this.SQL.Database();
    this.db.run(`
      CREATE TABLE IF NOT EXISTS cursors (
        source_path TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        backup_path TEXT NOT NULL,
        last_byte_offset INTEGER NOT NULL,
        line_count INTEGER NOT NULL,
        pending_partial_line TEXT NOT NULL,
        status TEXT NOT NULL,
        last_error TEXT,
        updated_at TEXT NOT NULL
      );
    `);
    this.flush();
  }

  get(sourcePath) {
    const stmt = this.db.prepare('SELECT * FROM cursors WHERE source_path = ?');
    stmt.bind([sourcePath]);
    const row = stmt.step() ? stmt.getAsObject() : null;
    stmt.free();
    return row;
  }

  upsert(cursor) {
    this.db.run(`
      INSERT OR REPLACE INTO cursors (
        source_path, session_id, backup_path, last_byte_offset, line_count,
        pending_partial_line, status, last_error, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    `, [
      cursor.sourcePath,
      cursor.sessionId,
      cursor.backupPath,
      cursor.lastByteOffset,
      cursor.lineCount,
      Buffer.from(cursor.pendingPartialLine || '').toString('base64'),
      cursor.status,
      cursor.lastError || null,
      cursor.updatedAt
    ]);
    this.flush();
  }

  flush() {
    fs.writeFileSync(this.databasePath, Buffer.from(this.db.export()));
  }
}

module.exports = { CursorStore };
```

- [ ] **Step 5: Implement session tailer**

Create `windows/codex_session_manager_electron/src/backup/session-tailer.js`:

```javascript
const fs = require('fs');

function readNewCompleteLines(filePath, offset, maxReadBytes = 1024 * 1024) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const buffer = Buffer.alloc(maxReadBytes);
    const bytesRead = fs.readSync(fd, buffer, 0, maxReadBytes, offset);
    if (!bytesRead) return { lines: [], nextOffset: offset, pendingPartialLine: '' };
    const chunk = buffer.subarray(0, bytesRead);
    const lines = [];
    let start = 0;
    let consumed = 0;
    for (let index = 0; index < chunk.length; index += 1) {
      if (chunk[index] === 0x0a) {
        const line = chunk.subarray(start, index);
        if (line.length) lines.push(line.toString('utf8'));
        consumed = index + 1;
        start = index + 1;
      }
    }
    const pendingPartialLine = start < chunk.length ? chunk.subarray(start).toString('utf8') : '';
    return { lines, nextOffset: offset + consumed, pendingPartialLine };
  } finally {
    fs.closeSync(fd);
  }
}

module.exports = { readNewCompleteLines };
```

- [ ] **Step 6: Implement Windows BackupAgent**

Create `windows/codex_session_manager_electron/src/backup/backup-agent.js`:

```javascript
const fs = require('fs');
const path = require('path');
const { CursorStore } = require('./cursor-store');
const { loadOrCreateManifest, saveManifest } = require('./manifest-store');
const { sessionIdFromPath, titleFromJsonLine } = require('./session-identity');
const { readNewCompleteLines } = require('./session-tailer');
const { AGENT_VERSION } = require('./models');

class BackupAgent {
  constructor({ paths, now = () => new Date() }) {
    this.paths = paths;
    this.now = now;
    this.cursorStore = new CursorStore(paths.cursorDatabasePath);
    this.pollTimer = null;
  }

  startPolling(intervalMs = 10000) {
    if (this.pollTimer) return;
    this.performOneShotScan().catch((error) => {
      console.error('Local incremental backup scan failed:', error);
    });
    this.pollTimer = setInterval(() => {
      this.performOneShotScan().catch((error) => {
        console.error('Local incremental backup scan failed:', error);
      });
    }, intervalMs);
  }

  stopPolling() {
    if (!this.pollTimer) return;
    clearInterval(this.pollTimer);
    this.pollTimer = null;
  }

  async performOneShotScan() {
    ensureDir(this.paths.backupRoot);
    ensureDir(this.paths.logsRoot);
    await this.cursorStore.open();
    const now = this.now();
    const manifest = loadOrCreateManifest(this.paths, now);
    for (const filePath of discoverJsonlFiles(this.paths.codexRoot)) {
      this.processFile(filePath, manifest);
    }
    manifest.updatedAt = this.now().toISOString();
    saveManifest(this.paths, manifest);
    writeStatus(this.paths, manifest, this.now(), null);
  }

  processFile(filePath, manifest) {
    const sessionId = sessionIdFromPath(filePath);
    if (!sessionId) return;
    const cursor = this.cursorStore.get(filePath);
    const firstSeenAt = manifest.sessions[sessionId]?.firstSeenAt || this.now().toISOString();
    const backupPath = manifest.sessions[sessionId]?.backupPath
      || this.paths.relativeBackupPath(this.paths.backupFilePath(sessionId, new Date(firstSeenAt)));
    const backupAbsolutePath = path.join(this.paths.backupRoot, backupPath);
    const read = readNewCompleteLines(filePath, cursor ? Number(cursor.last_byte_offset) : 0);
    if (!read.lines.length && manifest.sessions[sessionId]) return;

    ensureDir(path.dirname(backupAbsolutePath));
    if (read.lines.length) {
      fs.appendFileSync(backupAbsolutePath, `${read.lines.join('\n')}\n`, 'utf8');
    }
    const previous = manifest.sessions[sessionId];
    const title = previous?.title || read.lines.map(titleFromJsonLine).find(Boolean) || null;
    const lineCount = (previous?.lineCount || cursor?.line_count || 0) + read.lines.length;
    const bytesAdded = Buffer.byteLength(read.lines.map((line) => `${line}\n`).join(''), 'utf8');
    manifest.sessions[sessionId] = {
      sessionId,
      sourcePath: filePath,
      backupPath,
      title,
      firstSeenAt,
      lastBackedUpAt: read.lines.length ? this.now().toISOString() : previous?.lastBackedUpAt || null,
      lineCount,
      bytesBackedUp: (previous?.bytesBackedUp || 0) + bytesAdded,
      status: 'active'
    };
    this.cursorStore.upsert({
      sourcePath: filePath,
      sessionId,
      backupPath,
      lastByteOffset: read.nextOffset,
      lineCount,
      pendingPartialLine: read.pendingPartialLine,
      status: 'active',
      lastError: null,
      updatedAt: this.now().toISOString()
    });
  }
}

function discoverJsonlFiles(codexRoot) {
  const roots = [path.join(codexRoot, 'sessions'), path.join(codexRoot, 'archived_sessions')];
  return roots.flatMap(walkJsonl).sort();
}

function walkJsonl(root) {
  if (!fs.existsSync(root)) return [];
  const entries = fs.readdirSync(root, { withFileTypes: true });
  return entries.flatMap((entry) => {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) return walkJsonl(fullPath);
    if (entry.isFile() && fullPath.toLowerCase().endsWith('.jsonl')) return [fullPath];
    return [];
  });
}

function writeStatus(paths, manifest, now, lastError) {
  const sessions = Object.values(manifest.sessions);
  const status = {
    agentVersion: AGENT_VERSION,
    enabled: true,
    status: lastError ? 'error' : 'running',
    mode: 'polling',
    codexRoot: paths.codexRoot,
    backupRoot: paths.backupRoot,
    firstRunAt: manifest.createdAt,
    lastStartedAt: now.toISOString(),
    lastHeartbeatAt: now.toISOString(),
    lastBackupAt: sessions.map((session) => session.lastBackedUpAt).filter(Boolean).sort().at(-1) || null,
    sessionCount: sessions.length,
    lineCount: sessions.reduce((sum, session) => sum + (session.lineCount || 0), 0),
    bytesBackedUp: sessions.reduce((sum, session) => sum + (session.bytesBackedUp || 0), 0),
    autoStartEnabled: false,
    lastError
  };
  ensureDir(path.dirname(paths.statusPath));
  fs.writeFileSync(paths.statusPath, JSON.stringify(status, null, 2), 'utf8');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

module.exports = { BackupAgent };
```

- [ ] **Step 7: Run Windows backup tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: PASS.

- [ ] **Step 8: Commit Windows backup agent**

Run:

```bash
git add windows/codex_session_manager_electron/src/backup/manifest-store.js windows/codex_session_manager_electron/src/backup/cursor-store.js windows/codex_session_manager_electron/src/backup/session-tailer.js windows/codex_session_manager_electron/src/backup/backup-agent.js windows/codex_session_manager_electron/test/backup/agent.test.js
git commit -m "feat: add Windows local backup agent"
```

---

### Task 9: Integrate Windows Backup Status Into Electron

**Files:**
- Modify: `windows/codex_session_manager_electron/src/main.js`
- Modify: `windows/codex_session_manager_electron/src/preload.js`
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
- Modify: `windows/codex_session_manager_electron/src/index.html`
- Modify: `windows/codex_session_manager_electron/src/styles.css`

- [ ] **Step 1: Start BackupAgent in Electron main process**

In `windows/codex_session_manager_electron/src/main.js`, add near imports:

```javascript
const { backupPaths } = require('./backup/paths');
const { BackupAgent } = require('./backup/backup-agent');
```

Add module-level agent:

```javascript
const localBackupPaths = backupPaths(os.homedir());
const localBackupAgent = new BackupAgent({ paths: localBackupPaths });
```

Inside `loadState()`, include backup status:

```javascript
    backupStatus: readBackupStatus()
```

Add helper:

```javascript
function readBackupStatus() {
  try {
    if (!exists(localBackupPaths.statusPath)) {
      return { status: 'waiting', mode: 'polling', lastError: null };
    }
    return JSON.parse(readText(localBackupPaths.statusPath));
  } catch (error) {
    return { status: 'error', mode: 'polling', lastError: error.message || String(error) };
  }
}
```

After `app.whenReady().then(createWindow);`, add:

```javascript
app.whenReady().then(async () => {
  try {
    localBackupAgent.startPolling(10000);
  } catch (error) {
    console.error('Local incremental backup failed to start:', error);
  }
});
```

Add IPC:

```javascript
ipcMain.handle('load-backup-status', async () => readBackupStatus());
```

- [ ] **Step 2: Expose backup status in preload**

Modify `windows/codex_session_manager_electron/src/preload.js`:

```javascript
  loadBackupStatus: () => ipcRenderer.invoke('load-backup-status'),
```

- [ ] **Step 3: Add status shell to HTML**

In `windows/codex_session_manager_electron/src/index.html`, add inside current state/sidebar status area:

```html
<div class="backup-status-card">
  <strong>本地增量备份</strong>
  <span id="backupStatusText">等待状态</span>
  <small id="backupStatusDetail">正在读取备份状态...</small>
</div>
```

- [ ] **Step 4: Render backup status**

In `windows/codex_session_manager_electron/src/renderer.js`, add to `els`:

```javascript
  backupStatusText: $('#backupStatusText'),
  backupStatusDetail: $('#backupStatusDetail'),
```

In `refresh()`, after setting `state.currentState`, add:

```javascript
    state.backupStatus = data.backupStatus || {};
```

Add renderer helper:

```javascript
function renderBackupStatus() {
  const backup = state.backupStatus || {};
  const status = backup.status || 'waiting';
  const mode = backup.mode || 'unknown';
  els.backupStatusText.textContent = status === 'running' ? '运行中' : (status === 'error' ? '异常' : '等待中');
  const lastBackup = backup.lastBackupAt ? formatDate(backup.lastBackupAt) : '暂无备份';
  els.backupStatusDetail.textContent = backup.lastError
    ? backup.lastError
    : `模式：${mode} · 最近备份：${lastBackup} · 会话：${backup.sessionCount || 0}`;
}
```

Call `renderBackupStatus()` inside `renderAll()`.

- [ ] **Step 5: Add CSS**

In `windows/codex_session_manager_electron/src/styles.css`, add:

```css
.backup-status-card {
  display: grid;
  gap: 4px;
  padding: 10px 12px;
  border: 1px solid rgba(104, 122, 152, 0.24);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.72);
}

.backup-status-card strong {
  font-size: 12px;
  color: #23324d;
}

.backup-status-card span {
  font-size: 13px;
  color: #1f7a5a;
}

.backup-status-card small {
  font-size: 11px;
  line-height: 1.35;
  color: #66758f;
}
```

- [ ] **Step 6: Run Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: PASS.

- [ ] **Step 7: Smoke start Electron app**

Run:

```bash
cd windows/codex_session_manager_electron
npm start
```

Expected: app starts and backup status card renders without JavaScript console errors.

- [ ] **Step 8: Commit Windows integration**

Run:

```bash
git add windows/codex_session_manager_electron/src/main.js windows/codex_session_manager_electron/src/preload.js windows/codex_session_manager_electron/src/renderer.js windows/codex_session_manager_electron/src/index.html windows/codex_session_manager_electron/src/styles.css
git commit -m "feat: show local incremental backup status on Windows"
```

---

### Task 10: Add Documentation and Final Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/操作手册.md`

- [ ] **Step 1: Update README feature list**

Add to `README.md` feature list:

```markdown
- 本地增量备份：后台自动监听 Codex 会话 `.jsonl` 文件，只追加备份新增完整行，不需要手动创建快照。
- 本地备份状态：显示最近备份时间、已备份会话数量、监听/轮询模式和最近错误，便于员工和 IT 排查。
```

Add first-stage limitation note:

```markdown
### 本地增量备份说明

本地增量备份会写入 `~/.codex-session-vault/incremental-backups`。第一阶段只保存到本机，不上传 NAS；NAS 汇总和企业监控将在后续阶段接入。备份内容为明文 `.jsonl` 新增行和最小 manifest。
```

- [ ] **Step 2: Update operations manual**

Add to `docs/操作手册.md`:

```markdown
## 本地增量备份

应用启动后会自动扫描 `~/.codex/sessions` 和 `~/.codex/archived_sessions`，并把新增 `.jsonl` 完整行追加保存到：

```text
~/.codex-session-vault/incremental-backups
```

常用排查：

1. 查看界面里的“本地增量备份”状态。
2. 点击或手动打开备份目录。
3. 检查 `status.json` 的 `lastBackupAt`、`sessionCount`、`lastError`。
4. 检查 `manifest.json` 的会话索引和 `cursors.sqlite` 的读取游标。

第一阶段恢复会生成文件型恢复包，不强行重建 `state_5.sqlite`。恢复后如果 Codex 已打开，请重启 Codex。
```

- [ ] **Step 3: Run all Swift tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 4: Build macOS app**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Run Windows tests**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: PASS.

- [ ] **Step 6: Check git diff**

Run:

```bash
git status --short
git diff --stat
```

Expected: only intentional backup feature files, tests, UI status, and docs are changed.

- [ ] **Step 7: Commit docs and final verification**

Run:

```bash
git add README.md docs/操作手册.md
git commit -m "docs: document local incremental backup"
```

---

## Self-Review

Spec coverage:

- Automatic `.jsonl` incremental backup: Tasks 3, 4, 8, 9. Task 4 adds macOS polling, and Task 8 adds Windows polling.
- Manifest and cursor store: Tasks 2, 3, 8.
- Date-directory/session-id naming: Tasks 1, 7.
- Status and diagnostics: Tasks 4, 6, 8, 9.
- Recovery staging package: Task 5.
- macOS and Windows support: Tasks 1-6 for macOS, Tasks 7-9 for Windows.
- Tests and verification: Tasks 1-5, 7-8, 10.
- Docs and rollout notes: Task 10.

Known follow-up after this plan:

- Replace first-stage polling with native filesystem watcher plus debounce where platform APIs are reliable.
- Add open backup/log directory actions to UI.
- Add user-level auto-start enable/disable controls.
- Add NAS upload phase.

This plan intentionally ships polling-based continuous backup first because it satisfies automatic local backup while keeping the first implementation stable and testable. Native watchers remain an optimization, not a blocker for first-stage automatic backup.

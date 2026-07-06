import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func cursorStoreUpsertsAndLoadsCursor() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(
        databaseURL: tempDirectory.appendingPathComponent("nested/cursors.sqlite")
    )
    try store.open()
    let cursor = makeCursor(sourcePath: "/Users/alice/.codex/sessions/session.jsonl")

    try store.upsert(cursor)
    let loaded = try store.cursor(sourcePath: cursor.sourcePath)

    #expect(loaded == cursor)
}

@Test
func cursorStoreUpdatesExistingCursorForSameSourcePath() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()
    let sourcePath = "/Users/alice/.codex/sessions/session.jsonl"
    let original = makeCursor(sourcePath: sourcePath)
    let updated = BackupCursor(
        sessionId: "session-updated",
        sourcePath: sourcePath,
        backupPath: "sessions/2026/07/04/session-updated.jsonl",
        lastByteOffset: 64,
        lastSourceSize: 80,
        lastSourceModifiedAt: 1_800_000_000,
        lineCount: 3,
        pendingPartialLine: Data("updated partial".utf8),
        status: "error",
        lastError: "failed after retry",
        updatedAt: 1_800_000_001
    )

    try store.upsert(original)
    try store.upsert(updated)
    let loaded = try store.cursor(sourcePath: sourcePath)

    #expect(loaded == updated)
}

@Test
func cursorStoreReturnsNilForMissingSourcePath() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()

    let loaded = try store.cursor(sourcePath: "/missing/session.jsonl")

    #expect(loaded == nil)
}

@Test
func cursorStorePreservesPendingPartialLineAndLastError() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()
    let cursor = BackupCursor(
        sessionId: "session-binary",
        sourcePath: "/Users/alice/.codex/sessions/binary.jsonl",
        backupPath: "sessions/2026/07/04/binary.jsonl",
        lastByteOffset: 10,
        lastSourceSize: 14,
        lastSourceModifiedAt: 1_700_000_100,
        lineCount: 1,
        pendingPartialLine: Data([0, 1, 2, 255]),
        status: "error",
        lastError: "line could not be decoded",
        updatedAt: 1_700_000_101
    )

    try store.upsert(cursor)
    let loaded = try #require(try store.cursor(sourcePath: cursor.sourcePath))

    #expect(loaded.pendingPartialLine == Data([0, 1, 2, 255]))
    #expect(loaded.lastError == "line could not be decoded")
}

@Test
func cursorStoreHandlesQuotesPipesAndNewlinesWithoutCorruptingParsing() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()
    let sourcePath = "/Users/alice/.codex/sessions/quote'pipe|newline\nsession.jsonl"
    let cursor = BackupCursor(
        sessionId: "session-'|",
        sourcePath: sourcePath,
        backupPath: "sessions/2026/07/04/quote'pipe|newline\nsession.jsonl",
        lastByteOffset: 123,
        lastSourceSize: 456,
        lastSourceModifiedAt: 1_900_000_000,
        lineCount: 7,
        pendingPartialLine: Data("{\"partial\":\"line\"}".utf8),
        status: "error|quoted",
        lastError: "failed at 'quote' | pipe\nsecond line",
        updatedAt: 1_900_000_001
    )

    try store.upsert(cursor)
    let loaded = try store.cursor(sourcePath: sourcePath)

    #expect(loaded == cursor)
}

@Test
func cursorStoreReportsUsefulSqliteFailureDescriptions() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let sqliteScript = try writeExecutableScript(
        """
        #!/bin/sh
        echo "simulated sqlite failure" >&2
        exit 7
        """,
        named: "sqlite-fail.sh",
        in: tempDirectory
    )
    let store = BackupCursorStore(
        databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"),
        sqlitePath: sqliteScript.path
    )

    do {
        try store.open()
        #expect(Bool(false), "Expected sqlite failure")
    } catch {
        #expect(error.localizedDescription.contains("sqlite3 failed with exit status 7"))
        #expect(error.localizedDescription.contains("simulated sqlite failure"))
    }
}

@Test
func cursorStorePassesBusyTimeoutBeforeDatabasePath() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let sqliteScript = try writeExecutableScript(
        """
        #!/bin/sh
        args_path="$0.args"
        : > "$args_path"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$args_path"
        done
        exit 1
        """,
        named: "sqlite-record-args.sh",
        in: tempDirectory
    )
    let databaseURL = tempDirectory.appendingPathComponent("cursors.sqlite")
    let store = BackupCursorStore(databaseURL: databaseURL, sqlitePath: sqliteScript.path)

    do {
        try store.open()
        #expect(Bool(false), "Expected fake sqlite to fail")
    } catch {
        let argumentsURL = URL(fileURLWithPath: "\(sqliteScript.path).args")
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let commandIndex = try #require(arguments.firstIndex(of: "-cmd"))
        let timeoutIndex = commandIndex + 1
        let databaseIndex = try #require(arguments.firstIndex(of: databaseURL.path))

        #expect(arguments.indices.contains(timeoutIndex))
        #expect(arguments[timeoutIndex] == ".timeout 5000")
        #expect(commandIndex < databaseIndex)
    }
}

@Test
func cursorStoreStreamsSQLThroughStandardInput() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let sqliteScript = try writeExecutableScript(
        """
        #!/bin/sh
        args_path="$0.args"
        stdin_path="$0.stdin"
        : > "$args_path"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$args_path"
        done
        cat > "$stdin_path"
        exit 1
        """,
        named: "sqlite-stdin.sh",
        in: tempDirectory
    )
    let databaseURL = tempDirectory.appendingPathComponent("cursors.sqlite")
    let store = BackupCursorStore(databaseURL: databaseURL, sqlitePath: sqliteScript.path)

    do {
        try store.open()
        #expect(Bool(false), "Expected fake sqlite to fail")
    } catch {
        let arguments = try String(
            contentsOf: URL(fileURLWithPath: "\(sqliteScript.path).args"),
            encoding: .utf8
        )
        let standardInput = try String(
            contentsOf: URL(fileURLWithPath: "\(sqliteScript.path).stdin"),
            encoding: .utf8
        )

        #expect(!arguments.contains("CREATE TABLE"))
        #expect(standardInput.contains("CREATE TABLE IF NOT EXISTS backup_cursors"))
    }
}

private func makeCursor(sourcePath: String) -> BackupCursor {
    BackupCursor(
        sessionId: "session-123",
        sourcePath: sourcePath,
        backupPath: "sessions/2026/07/04/session-123.jsonl",
        lastByteOffset: 42,
        lastSourceSize: 50,
        lastSourceModifiedAt: 1_700_000_000,
        lineCount: 2,
        pendingPartialLine: Data("partial".utf8),
        status: "backedUp",
        lastError: nil,
        updatedAt: 1_700_000_001
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSessionVaultCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeExecutableScript(_ contents: String, named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

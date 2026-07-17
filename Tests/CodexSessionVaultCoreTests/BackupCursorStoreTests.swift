import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func bulkLoadAndUpsertRoundTrip() throws {
    let fixture = try CursorStoreFixture()
    let original = fixture.cursor(sourcePath: "/tmp/会话 one.jsonl", offset: 10)
    let second = fixture.cursor(sourcePath: "/tmp/o'ne.jsonl", offset: 20)
    let third = fixture.cursor(sourcePath: "/tmp/space three.jsonl", offset: 30)

    try fixture.store.upsertMany([original, second, third])
    var rows = try fixture.store.loadAll()

    #expect(rows.count == 3)
    #expect(rows[original.sourcePath]?.lastByteOffset == 10)
    #expect(rows[second.sourcePath]?.lastByteOffset == 20)
    #expect(rows[third.sourcePath]?.lastByteOffset == 30)

    let replacement = fixture.cursor(sourcePath: original.sourcePath, offset: 40)
    try fixture.store.upsertMany([replacement])
    rows = try fixture.store.loadAll()

    #expect(rows.count == 3)
    #expect(rows[original.sourcePath]?.lastByteOffset == 40)
    #expect(rows[second.sourcePath]?.lastByteOffset == 20)
    #expect(rows[third.sourcePath]?.lastByteOffset == 30)
}

@Test
func bulkOperationsInvokeSQLiteOnceRegardlessOfRowCount() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let readSpy = SQLiteRunnerSpy(
        output: """
        [
          {"session_id":"one","source_path":"/tmp/会话 one.jsonl","backup_path":"one.jsonl","last_byte_offset":10,"last_source_size":11,"last_source_modified_at":1,"line_count":1,"pending_partial_line":"","status":"backedUp","last_error":null,"updated_at":1},
          {"session_id":"two","source_path":"/tmp/o'ne.jsonl","backup_path":"two.jsonl","last_byte_offset":20,"last_source_size":21,"last_source_modified_at":2,"line_count":2,"pending_partial_line":"","status":"backedUp","last_error":null,"updated_at":2},
          {"session_id":"three","source_path":"/tmp/space three.jsonl","backup_path":"three.jsonl","last_byte_offset":30,"last_source_size":31,"last_source_modified_at":3,"line_count":3,"pending_partial_line":"","status":"backedUp","last_error":null,"updated_at":3}
        ]
        """
    )
    let readStore = BackupCursorStore(
        databaseURL: tempDirectory.appendingPathComponent("read.sqlite"),
        sqliteRunner: readSpy.run
    )

    let rows = try readStore.loadAll()

    #expect(rows.count == 3)
    #expect(rows["/tmp/会话 one.jsonl"]?.lastByteOffset == 10)
    #expect(rows["/tmp/o'ne.jsonl"]?.lastByteOffset == 20)
    #expect(rows["/tmp/space three.jsonl"]?.lastByteOffset == 30)
    #expect(readSpy.invocations.count == 1)

    let writeSpy = SQLiteRunnerSpy(output: "")
    let writeStore = BackupCursorStore(
        databaseURL: tempDirectory.appendingPathComponent("write.sqlite"),
        sqliteRunner: writeSpy.run
    )
    let cursors = [
        makeCursor(sourcePath: "/tmp/会话 one.jsonl"),
        makeCursor(sourcePath: "/tmp/o'ne.jsonl"),
        makeCursor(sourcePath: "/tmp/space three.jsonl"),
    ]

    try writeStore.upsertMany([])
    #expect(writeSpy.invocations.isEmpty)

    try writeStore.upsertMany(cursors)

    #expect(writeSpy.invocations.count == 1)
}

@Test
func bulkLoadRejectsDuplicateSourcePaths() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let duplicateRows = """
    [
      {"session_id":"one","source_path":"/tmp/duplicate.jsonl","backup_path":"one.jsonl","last_byte_offset":1,"last_source_size":1,"last_source_modified_at":1,"line_count":1,"pending_partial_line":"","status":"backedUp","last_error":null,"updated_at":1},
      {"session_id":"two","source_path":"/tmp/duplicate.jsonl","backup_path":"two.jsonl","last_byte_offset":2,"last_source_size":2,"last_source_modified_at":2,"line_count":2,"pending_partial_line":"","status":"backedUp","last_error":null,"updated_at":2}
    ]
    """
    let spy = SQLiteRunnerSpy(output: duplicateRows)
    let store = BackupCursorStore(
        databaseURL: tempDirectory.appendingPathComponent("duplicates.sqlite"),
        sqliteRunner: spy.run
    )

    var didThrow = false
    do {
        _ = try store.loadAll()
    } catch {
        didThrow = true
    }

    #expect(didThrow)
    #expect(spy.invocations.count == 1)
}

@Test
func bulkUpsertRollsBackWhenSecondStatementViolatesConstraint() throws {
    let fixture = try CursorStoreFixture()
    let first = fixture.cursor(sourcePath: "/tmp/first.jsonl", offset: 10)
    let second = fixture.cursor(sourcePath: "/tmp/second.jsonl", offset: 20)
    try fixture.store.upsertMany([first, second])
    try executeSQLite(
        """
        CREATE TRIGGER reject_second_cursor
        BEFORE UPDATE ON backup_cursors
        WHEN NEW.source_path = '/tmp/second.jsonl'
        BEGIN
            SELECT RAISE(ABORT, 'forced constraint violation');
        END;
        """,
        databaseURL: fixture.databaseURL
    )
    let updatedFirst = fixture.cursor(sourcePath: first.sourcePath, offset: 100)
    let updatedSecond = fixture.cursor(sourcePath: second.sourcePath, offset: 200)

    var didThrow = false
    do {
        try fixture.store.upsertMany([updatedFirst, updatedSecond])
    } catch {
        didThrow = true
    }
    let rows = try fixture.store.loadAll()

    #expect(didThrow)
    #expect(rows[first.sourcePath]?.lastByteOffset == 10)
    #expect(rows[second.sourcePath]?.lastByteOffset == 20)
}

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
    #expect(try cursorStoreMode(tempDirectory.appendingPathComponent("nested")) == 0o700)
    #expect(try cursorStoreMode(tempDirectory.appendingPathComponent("nested/cursors.sqlite")) == 0o600)
}

@Test
func cursorStoreMigratesLegacySchemaWithoutLosingRows() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let databaseURL = tempDirectory.appendingPathComponent("legacy.sqlite")
    try executeSQLite(
        """
        CREATE TABLE backup_cursors (
            source_path TEXT NOT NULL PRIMARY KEY,
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
        INSERT INTO backup_cursors VALUES (
            '/tmp/legacy.jsonl',
            'legacy-session',
            'sessions/legacy.jsonl',
            9,
            12,
            1700000000,
            1,
            '',
            'active',
            NULL,
            1700000001
        );
        """,
        databaseURL: databaseURL
    )
    let store = BackupCursorStore(databaseURL: databaseURL)

    try store.open()

    var migrated = try #require(try store.cursor(sourcePath: "/tmp/legacy.jsonl"))
    #expect(migrated.sessionId == "legacy-session")
    #expect(migrated.lastByteOffset == 9)
    #expect(migrated.sourceFileIdentity == nil)

    migrated.sourceFileIdentity = "42:99"
    try store.upsert(migrated)
    #expect(try store.cursor(sourcePath: migrated.sourcePath)?.sourceFileIdentity == "42:99")
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

private func cursorStoreMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
}

private func writeExecutableScript(_ contents: String, named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private final class CursorStoreFixture {
    let databaseURL: URL
    let store: BackupCursorStore
    private let tempDirectory: URL

    init() throws {
        tempDirectory = try makeTemporaryDirectory()
        databaseURL = tempDirectory.appendingPathComponent("cursors.sqlite")
        store = BackupCursorStore(databaseURL: databaseURL)
        try store.open()
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func cursor(sourcePath: String, offset: Int64) -> BackupCursor {
        BackupCursor(
            sessionId: "session-\(offset)",
            sourcePath: sourcePath,
            backupPath: "sessions/\(offset).jsonl",
            lastByteOffset: offset,
            lastSourceSize: offset + 1,
            lastSourceModifiedAt: TimeInterval(offset),
            lineCount: Int(offset),
            pendingPartialLine: Data("partial \(offset)".utf8),
            status: "backedUp",
            lastError: nil,
            updatedAt: TimeInterval(offset + 2)
        )
    }
}

private final class SQLiteRunnerSpy {
    struct Invocation {
        var arguments: [String]
        var input: String
    }

    private(set) var invocations: [Invocation] = []
    private let output: String

    init(output: String) {
        self.output = output
    }

    func run(arguments: [String], input: String) throws -> String {
        invocations.append(Invocation(arguments: arguments, input: input))
        return output
    }
}

private func executeSQLite(_ sql: String, databaseURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    let errorPipe = Pipe()
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
        throw NSError(
            domain: "BackupCursorStoreTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

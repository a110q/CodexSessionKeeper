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
        try fixture.writeRecovered(
            sessionID: "session-2",
            contents: #"{"role":"assistant","content":"only assistant"}"# + "\n"
        )
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

    @Test
    func ensureThreadsReturnsWarningWhenThreadsTableIsMissing() throws {
        let fixture = try RecoveredThreadIndexFixture()
        defer { fixture.cleanup() }
        let database = fixture.codexRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        try fixture.runSQLite(database: database, sql: "CREATE TABLE unrelated (id TEXT PRIMARY KEY);")

        let result = try RecoveredThreadIndexWriter().ensureThreads(
            entries: [fixture.entry(sessionID: "a", title: "A")],
            databaseURL: database
        )

        #expect(result.insertedCount == 0)
        #expect(result.warning == "SQLite 索引未写入：threads 表不存在")
    }
}

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

    func insertExistingThread(database: URL, id: String, title: String) throws {
        let sql = """
        INSERT INTO threads (
          id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
          sandbox_policy, approval_mode, tokens_used, has_user_event, archived,
          cli_version, first_user_message, memory_mode, model, preview, recency_at, recency_at_ms
        ) VALUES (
          '\(id)', '/old.jsonl', 1, 1, 'vscode', 'openai', '', '\(title)',
          '', '', 0, 1, 0,
          '', '', 'enabled', 'gpt-5', '', 1, 1000
        );
        """
        try runSQLite(database: database, sql: sql)
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

    func threadRow(database: URL, id: String) throws -> [String: String] {
        let output = try runSQLite(
            database: database,
            arguments: ["-json"],
            sql: "SELECT id, title, rollout_path, archived FROM threads WHERE id = '\(id)';"
        )
        let data = Data(output.utf8)
        let rows = try JSONDecoder().decode([[String: SQLiteValue]].self, from: data)
        let row = try #require(rows.first)
        return row.mapValues(\.stringValue)
    }

    @discardableResult
    func runSQLite(database: URL, arguments: [String] = [], sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments + [database.path, sql]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "RecoveredThreadIndexFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
        return output
    }
}

private enum SQLiteValue: Decodable {
    case string(String)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var stringValue: String {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case .null:
            return ""
        }
    }
}

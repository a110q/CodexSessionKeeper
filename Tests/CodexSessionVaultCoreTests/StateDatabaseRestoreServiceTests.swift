import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("StateDatabaseRestoreService")
struct StateDatabaseRestoreServiceTests {
    enum ConflictTable: String, CaseIterable, Sendable {
        case threads
        case threadGoals = "thread_goals"
        case threadDynamicTools = "thread_dynamic_tools"
        case threadSpawnEdges = "thread_spawn_edges"
        case stage1Outputs = "stage1_outputs"
        case agentJobItems = "agent_job_items"
    }

    @Test(arguments: ConflictTable.allCases)
    func preflightDetectsEveryConversationTableConflict(_ conflictTable: ConflictTable) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase(fixture.live, threads: ["A", "B"])
        try fixture.createDatabase(fixture.snapshot, threads: ["A"])
        try fixture.createConflict(in: fixture.live, table: conflictTable, owner: "B")
        try fixture.createConflict(in: fixture.snapshot, table: conflictTable, owner: "A")
        let service = StateDatabaseRestoreService(sqliteExecutableURL: fixture.sqlite)

        do {
            _ = try service.preflightMerge(
                source: fixture.snapshot,
                destination: fixture.live,
                sessionIDs: ["A"]
            )
            Issue.record("expected SQLITE_RESTORE_CONFLICT for \(conflictTable.rawValue)")
        } catch let error as StateDatabaseRestoreError {
            #expect(error.code == "SQLITE_RESTORE_CONFLICT")
        }

        #expect(try fixture.rows(fixture.live, "SELECT id, title FROM threads ORDER BY id") == [
            ["id": "A", "title": "live-A"],
            ["id": "B", "title": conflictTable == .threads ? "shared" : "live-B"]
        ])
    }

    @Test
    func selectedRelationConflictRollsBackEveryTable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase(fixture.live, threads: ["A", "B"])
        try fixture.createDatabase(fixture.snapshot, threads: ["A"])
        try fixture.sql(fixture.live, """
            CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT, payload TEXT);
            INSERT INTO agent_job_items VALUES ('shared', 'B', 'live B');
            """)
        try fixture.sql(fixture.snapshot, """
            CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT, payload TEXT);
            INSERT INTO agent_job_items VALUES ('shared', 'A', 'snapshot A');
            """)
        let service = StateDatabaseRestoreService(sqliteExecutableURL: fixture.sqlite)

        do {
            try service.merge(
                source: fixture.snapshot,
                destination: fixture.live,
                sessionIDs: ["A"]
            )
            Issue.record("expected SQLITE_RESTORE_CONFLICT")
        } catch let error as StateDatabaseRestoreError {
            #expect(error.code == "SQLITE_RESTORE_CONFLICT")
        }

        #expect(try fixture.rows(fixture.live, "SELECT id, title FROM threads ORDER BY id") == [
            ["id": "A", "title": "live-A"],
            ["id": "B", "title": "live-B"]
        ])
        #expect(try fixture.rows(fixture.live, "SELECT id, assigned_thread_id, payload FROM agent_job_items") == [
            ["id": "shared", "assigned_thread_id": "B", "payload": "live B"]
        ])
    }

    @Test
    func missingDestinationFailureLeavesNoPublishedDatabaseOrSidecars() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase(fixture.snapshot, threads: ["A", "B"])
        let missingSQLite = fixture.root.appendingPathComponent("missing-sqlite3")
        let service = StateDatabaseRestoreService(sqliteExecutableURL: missingSQLite)

        #expect(throws: Error.self) {
            try service.merge(source: fixture.snapshot, destination: fixture.live, sessionIDs: ["A"])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.live.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.live.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.live.path + "-shm"))
    }

    @Test
    func fullReplaceClearsConversationTablesMissingFromTheSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase(fixture.live, threads: ["old-live"])
        try fixture.createDatabase(fixture.snapshot, threads: ["snapshot"])
        try fixture.sql(fixture.live, """
            CREATE TABLE agent_job_items (id TEXT PRIMARY KEY, assigned_thread_id TEXT, payload TEXT);
            INSERT INTO agent_job_items VALUES ('stale', 'old-live', 'live only');
            """)
        let service = StateDatabaseRestoreService(sqliteExecutableURL: fixture.sqlite)

        try service.replace(
            source: fixture.snapshot,
            destination: fixture.live,
            sessionIDs: ["snapshot"]
        )

        #expect(try fixture.rows(
            fixture.live,
            "SELECT COALESCE(group_concat(id), '') AS ids FROM agent_job_items"
        ) == [["ids": ""]])
    }

    @Test
    func rolloutUpdatesTolerateAnOlderThreadsSchema() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.sql(fixture.live, "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);")
        try fixture.sql(fixture.snapshot, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);
            INSERT INTO threads VALUES ('A', 'snapshot');
            """)
        let service = StateDatabaseRestoreService(sqliteExecutableURL: fixture.sqlite)

        try service.merge(
            source: fixture.snapshot,
            destination: fixture.live,
            sessionIDs: ["A"],
            rolloutPathUpdates: [StateDatabaseRolloutPathUpdate(sessionID: "A", rolloutPath: "/safe/A.jsonl")]
        )

        #expect(try fixture.rows(fixture.live, "SELECT id, title FROM threads") == [
            ["id": "A", "title": "snapshot"]
        ])
    }

    private struct Fixture {
        let root: URL
        let live: URL
        let snapshot: URL
        let sqlite = URL(fileURLWithPath: "/usr/bin/sqlite3")

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("state-restore-\(UUID().uuidString)", isDirectory: true)
            live = root.appendingPathComponent("state_5.sqlite")
            snapshot = root.appendingPathComponent("snapshot.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func createDatabase(_ url: URL, threads: [String]) throws {
            try sql(url, """
                CREATE TABLE threads (
                  id TEXT PRIMARY KEY,
                  title TEXT NOT NULL,
                  rollout_path TEXT NOT NULL,
                  archived INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                \(threads.map { "INSERT INTO threads (id, title, rollout_path) VALUES ('\($0)', 'live-\($0)', '/tmp/\($0).jsonl');" }.joined(separator: "\n"))
                """)
        }

        func createConflict(in database: URL, table: ConflictTable, owner: String) throws {
            switch table {
            case .threads:
                try sql(database, """
                    CREATE UNIQUE INDEX threads_unique_title ON threads(title);
                    UPDATE threads SET title = 'shared' WHERE id = '\(owner)';
                    """)
            case .threadSpawnEdges:
                try sql(database, """
                    CREATE TABLE thread_spawn_edges (
                      id TEXT PRIMARY KEY,
                      parent_thread_id TEXT,
                      child_thread_id TEXT,
                      payload TEXT
                    );
                    INSERT INTO thread_spawn_edges VALUES ('shared-key', '\(owner)', '\(owner)', '\(owner) payload');
                    """)
            default:
                let ownerColumn = table == .agentJobItems ? "assigned_thread_id" : "thread_id"
                try sql(database, """
                    CREATE TABLE \(table.rawValue) (id TEXT PRIMARY KEY, \(ownerColumn) TEXT, payload TEXT);
                    INSERT INTO \(table.rawValue) VALUES ('shared-key', '\(owner)', '\(owner) payload');
                    """)
            }
        }

        func sql(_ url: URL, _ sql: String) throws {
            let process = Process()
            process.executableURL = sqlite
            process.arguments = [url.path]
            let input = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardError = error
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(".bail on\n\(sql)\n".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "sqlite-test",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(
                        data: error.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "sqlite failed"]
                )
            }
        }

        func rows(_ url: URL, _ sql: String) throws -> [[String: String]] {
            let process = Process()
            process.executableURL = sqlite
            process.arguments = ["-json", url.path, sql]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try JSONSerialization.jsonObject(with: data) as? [[String: String]] ?? []
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

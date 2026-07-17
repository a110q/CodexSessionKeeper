import Foundation

public enum StateDatabaseRestoreError: Error, LocalizedError, Equatable, Sendable {
    case restoreConflict(String)
    case databaseBusy
    case sqliteFailure(String)

    public var code: String {
        switch self {
        case .restoreConflict: "SQLITE_RESTORE_CONFLICT"
        case .databaseBusy: "SQLITE_BUSY"
        case .sqliteFailure: "SQLITE_RESTORE_FAILED"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .restoreConflict(let detail):
            "SQLite 恢复发生跨会话唯一键冲突，数据库未修改：\(detail)"
        case .databaseBusy:
            "SQLite 数据库正忙，5 秒内未获得写锁；请稍后重试。"
        case .sqliteFailure(let detail):
            "SQLite 恢复失败：\(detail)"
        }
    }
}

public struct StateDatabaseRolloutPathUpdate: Equatable, Sendable {
    public let sessionID: String
    public let rolloutPath: String

    public init(sessionID: String, rolloutPath: String) {
        self.sessionID = sessionID
        self.rolloutPath = rolloutPath
    }
}

public struct StateDatabaseMergePlan: Sendable {
    public let tableNames: [String]
    fileprivate let tables: [TablePlan]

    fileprivate init(tables: [TablePlan]) {
        self.tables = tables
        tableNames = tables.map(\.name)
    }
}

fileprivate struct TablePlan: Sendable {
    let name: String
    let columns: [String]
}

public struct StateDatabaseRestoreService: Sendable {
    public static let conversationTables = [
        "threads",
        "thread_goals",
        "thread_dynamic_tools",
        "thread_spawn_edges",
        "stage1_outputs",
        "agent_job_items"
    ]

    private let sqliteExecutableURL: URL
    private let busyTimeoutMilliseconds: Int

    public init(
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        busyTimeoutMilliseconds: Int = 5_000
    ) {
        self.sqliteExecutableURL = sqliteExecutableURL
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }

    public func preflightMerge(
        source: URL,
        destination: URL,
        sessionIDs: Set<String>? = nil
    ) throws -> StateDatabaseMergePlan {
        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: destination.path) else {
            throw StateDatabaseRestoreError.sqliteFailure("数据库文件缺失")
        }
        var plans: [TablePlan] = []
        for table in Self.conversationTables {
            let sourceColumns = try tableColumns(database: source, table: table)
            let destinationColumns = try tableColumns(database: destination, table: table)
            let common = destinationColumns.filter(sourceColumns.contains)
            if !common.isEmpty {
                // Enumerate every unique key as part of preflight. The final
                // authoritative conflict check remains the plain INSERT inside
                // the same BEGIN IMMEDIATE transaction as deletion/import.
                let uniqueKeys = try uniqueIndexes(database: destination, table: table)
                if let sessionIDs, !sessionIDs.isEmpty {
                    try detectConflicts(
                        source: source,
                        destination: destination,
                        table: table,
                        commonColumns: common,
                        uniqueKeys: uniqueKeys,
                        sessionIDs: sessionIDs
                    )
                }
                plans.append(TablePlan(name: table, columns: common))
            }
        }
        return StateDatabaseMergePlan(tables: plans)
    }

    public func merge(
        source: URL,
        destination: URL,
        sessionIDs: Set<String>,
        rolloutPathUpdates: [StateDatabaseRolloutPathUpdate] = []
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw StateDatabaseRestoreError.sqliteFailure("快照数据库缺失")
        }
        guard !sessionIDs.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try publishSanitizedCandidate(
                    source: source,
                    destination: destination,
                    sessionIDs: sessionIDs,
                    rolloutPathUpdates: rolloutPathUpdates
                )
                return
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Codex created the live database before our no-replace publish.
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    throw StateDatabaseRestoreError.sqliteFailure(
                        "Codex 并发创建的数据库在合并前消失，已停止恢复"
                    )
                }
            }
        }

        let plan = try preflightMerge(
            source: source,
            destination: destination,
            sessionIDs: sessionIDs
        )
        let ids = sessionIDs.map(Self.quoteLiteral).joined(separator: ", ")
        let deletes = plan.tables.map {
            "DELETE FROM \(Self.quoteIdentifier($0.name)) WHERE \(Self.selectedPredicate(table: $0.name, ids: ids));"
        }
        let inserts = plan.tables.map { table -> String in
            let columns = table.columns.map(Self.quoteIdentifier).joined(separator: ", ")
            return "INSERT INTO \(Self.quoteIdentifier(table.name)) (\(columns)) "
                + "SELECT \(columns) FROM snapshot.\(Self.quoteIdentifier(table.name)) "
                + "WHERE \(Self.selectedPredicate(table: table.name, ids: ids));"
        }
        let pathUpdates = try rolloutUpdateStatements(
            rolloutPathUpdates,
            database: destination
        )
        _ = try run(
            database: destination,
            sql: """
                PRAGMA foreign_keys = OFF;
                ATTACH DATABASE \(Self.quoteLiteral(source.path)) AS snapshot;
                BEGIN IMMEDIATE;
                \(deletes.joined(separator: "\n"))
                \(inserts.joined(separator: "\n"))
                \(pathUpdates.joined(separator: "\n"))
                COMMIT;
                DETACH DATABASE snapshot;
                PRAGMA foreign_keys = ON;
                """
        )
    }

    public func replace(
        source: URL,
        destination: URL,
        sessionIDs: Set<String>,
        rolloutPathUpdates: [StateDatabaseRolloutPathUpdate] = []
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw StateDatabaseRestoreError.sqliteFailure("快照数据库缺失")
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try publishSanitizedCandidate(
                    source: source,
                    destination: destination,
                    sessionIDs: sessionIDs,
                    rolloutPathUpdates: rolloutPathUpdates
                )
                return
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    throw StateDatabaseRestoreError.sqliteFailure(
                        "Codex 并发创建的数据库在合并前消失，已停止恢复"
                    )
                }
                try merge(
                    source: source,
                    destination: destination,
                    sessionIDs: sessionIDs,
                    rolloutPathUpdates: rolloutPathUpdates
                )
                return
            }
        }

        let plan = try preflightMerge(source: source, destination: destination)
        let ids = sessionIDs.map(Self.quoteLiteral).joined(separator: ", ")
        let destinationConversationTables = try Self.conversationTables.filter {
            try !tableColumns(database: destination, table: $0).isEmpty
        }
        let deletes = destinationConversationTables.map {
            "DELETE FROM \(Self.quoteIdentifier($0));"
        }
        let inserts = plan.tables.map { table -> String in
            let columns = table.columns.map(Self.quoteIdentifier).joined(separator: ", ")
            let whereClause = sessionIDs.isEmpty
                ? " WHERE 0"
                : " WHERE \(Self.selectedPredicate(table: table.name, ids: ids))"
            return "INSERT INTO \(Self.quoteIdentifier(table.name)) (\(columns)) "
                + "SELECT \(columns) FROM snapshot.\(Self.quoteIdentifier(table.name))\(whereClause);"
        }
        let accountDeletes = try accountTables(in: destination).map {
            "DELETE FROM \(Self.quoteIdentifier($0));"
        }
        let pathUpdates = try rolloutUpdateStatements(
            rolloutPathUpdates,
            database: destination
        )
        _ = try run(
            database: destination,
            sql: """
                PRAGMA foreign_keys = OFF;
                ATTACH DATABASE \(Self.quoteLiteral(source.path)) AS snapshot;
                BEGIN IMMEDIATE;
                \(deletes.joined(separator: "\n"))
                \(inserts.joined(separator: "\n"))
                \(accountDeletes.joined(separator: "\n"))
                \(pathUpdates.joined(separator: "\n"))
                COMMIT;
                DETACH DATABASE snapshot;
                PRAGMA foreign_keys = ON;
                """
        )
    }

    private func publishSanitizedCandidate(
        source: URL,
        destination: URL,
        sessionIDs: Set<String>,
        rolloutPathUpdates: [StateDatabaseRolloutPathUpdate]
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let candidate = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).candidate-\(UUID().uuidString)"
        )
        defer { removeDatabaseArtifacts(candidate) }
        _ = try run(database: source, sql: "VACUUM INTO \(Self.quoteLiteral(candidate.path));")

        let ids = sessionIDs.map(Self.quoteLiteral).joined(separator: ", ")
        var statements: [String] = []
        for table in Self.conversationTables where try !tableColumns(database: candidate, table: table).isEmpty {
            if sessionIDs.isEmpty {
                statements.append("DELETE FROM \(Self.quoteIdentifier(table));")
            } else {
                statements.append(
                    "DELETE FROM \(Self.quoteIdentifier(table)) WHERE NOT (\(Self.selectedPredicate(table: table, ids: ids)));"
                )
            }
        }
        statements.append(contentsOf: try accountTables(in: candidate).map {
            "DELETE FROM \(Self.quoteIdentifier($0));"
        })
        statements.append(contentsOf: try rolloutUpdateStatements(
            rolloutPathUpdates,
            database: candidate
        ))
        _ = try run(
            database: candidate,
            sql: """
                PRAGMA foreign_keys = OFF;
                BEGIN IMMEDIATE;
                \(statements.joined(separator: "\n"))
                COMMIT;
                PRAGMA foreign_keys = ON;
                """
        )

        let integrity = try run(database: candidate, sql: "PRAGMA integrity_check;")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard integrity == "ok" else {
            throw StateDatabaseRestoreError.sqliteFailure("integrity_check 未通过：\(integrity)")
        }
        try validateCandidate(candidate, sessionIDs: sessionIDs)
        let handle = try FileHandle(forUpdating: candidate)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try FileManager.default.linkItem(at: candidate, to: destination)
    }

    private func validateCandidate(_ database: URL, sessionIDs: Set<String>) throws {
        let ids = sessionIDs.map(Self.quoteLiteral).joined(separator: ", ")
        for table in Self.conversationTables where try !tableColumns(database: database, table: table).isEmpty {
            let predicate = sessionIDs.isEmpty ? "0" : Self.selectedPredicate(table: table, ids: ids)
            let rows = try jsonRows(
                database: database,
                sql: "SELECT COUNT(*) AS count FROM \(Self.quoteIdentifier(table)) WHERE NOT (\(predicate));"
            )
            let count = (rows.first?["count"] as? NSNumber)?.intValue ?? -1
            guard count == 0 else {
                throw StateDatabaseRestoreError.sqliteFailure("候选库包含未选择会话：\(table)")
            }
        }
        for table in try accountTables(in: database) {
            let rows = try jsonRows(
                database: database,
                sql: "SELECT COUNT(*) AS count FROM \(Self.quoteIdentifier(table));"
            )
            guard (rows.first?["count"] as? NSNumber)?.intValue == 0 else {
                throw StateDatabaseRestoreError.sqliteFailure("候选库账号表未清空：\(table)")
            }
        }
    }

    private func accountTables(in database: URL) throws -> [String] {
        try ["device_key_bindings", "remote_control_enrollments"].filter {
            try !tableColumns(database: database, table: $0).isEmpty
        }
    }

    private func tableColumns(database: URL, table: String) throws -> [String] {
        try jsonRows(database: database, sql: "PRAGMA table_info(\(Self.quoteIdentifier(table)));")
            .compactMap { $0["name"] as? String }
    }

    private func uniqueIndexes(database: URL, table: String) throws -> [[String]] {
        let tableInfo = try jsonRows(
            database: database,
            sql: "PRAGMA table_info(\(Self.quoteIdentifier(table)));"
        )
        let primaryKey = tableInfo
            .compactMap { row -> (position: Int, name: String)? in
                guard let position = (row["pk"] as? NSNumber)?.intValue,
                      position > 0,
                      let name = row["name"] as? String else { return nil }
                return (position, name)
            }
            .sorted { $0.position < $1.position }
            .map(\.name)
        let indexes = try jsonRows(
            database: database,
            sql: "PRAGMA index_list(\(Self.quoteIdentifier(table)));"
        )
        var result: [[String]] = primaryKey.isEmpty ? [] : [primaryKey]
        for index in indexes where (index["unique"] as? NSNumber)?.boolValue == true {
            guard let name = index["name"] as? String else { continue }
            let columns = try jsonRows(
                database: database,
                sql: "PRAGMA index_info(\(Self.quoteIdentifier(name)));"
            ).compactMap { $0["name"] as? String }
            if !columns.isEmpty { result.append(columns) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.joined(separator: "\0")).inserted }
    }

    private func detectConflicts(
        source: URL,
        destination: URL,
        table: String,
        commonColumns: [String],
        uniqueKeys: [[String]],
        sessionIDs: Set<String>
    ) throws {
        let ids = sessionIDs.sorted().map(Self.quoteLiteral).joined(separator: ", ")
        for key in uniqueKeys where key.allSatisfy(commonColumns.contains) {
            let equality = key.map {
                "\(Self.qualifiedIdentifier(alias: "incoming", column: $0)) = "
                    + Self.qualifiedIdentifier(alias: "live", column: $0)
            }.joined(separator: " AND ")
            let rows = try jsonRows(
                database: destination,
                sql: """
                    ATTACH DATABASE \(Self.quoteLiteral(source.path)) AS snapshot;
                    SELECT 1 AS conflict
                    FROM snapshot.\(Self.quoteIdentifier(table)) AS \(Self.quoteIdentifier("incoming"))
                    JOIN main.\(Self.quoteIdentifier(table)) AS \(Self.quoteIdentifier("live"))
                      ON \(equality)
                    WHERE (\(Self.selectedPredicate(table: table, ids: ids, alias: "incoming")))
                      AND NOT (\(Self.selectedPredicate(table: table, ids: ids, alias: "live")))
                    LIMIT 1;
                    DETACH DATABASE snapshot;
                    """
            )
            if !rows.isEmpty {
                throw StateDatabaseRestoreError.restoreConflict(
                    "\(table)(\(key.joined(separator: ", ")))"
                )
            }
        }
    }

    private func rolloutUpdateStatements(
        _ updates: [StateDatabaseRolloutPathUpdate],
        database: URL
    ) throws -> [String] {
        guard !updates.isEmpty else { return [] }
        let columns = try tableColumns(database: database, table: "threads")
        guard columns.contains("id"), columns.contains("rollout_path") else { return [] }
        return updates.map {
            "UPDATE threads SET rollout_path = \(Self.quoteLiteral($0.rolloutPath)) "
                + "WHERE id = \(Self.quoteLiteral($0.sessionID));"
        }
    }

    private func jsonRows(database: URL, sql: String) throws -> [[String: Any]] {
        let output = try run(database: database, sql: sql, json: true)
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let data = output.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StateDatabaseRestoreError.sqliteFailure("sqlite3 JSON 输出无效")
        }
        return rows
    }

    private func run(database: URL, sql: String, json: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = json ? ["-json", database.path] : [database.path]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(
            ".bail on\n.timeout \(busyTimeoutMilliseconds)\n\(sql)\n".utf8
        ))
        try input.fileHandleForWriting.close()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "sqlite3 执行失败"
            if detail.range(of: #"database is (locked|busy)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw StateDatabaseRestoreError.databaseBusy
            }
            if detail.range(
                of: #"unique constraint failed|primary key|constraint failed"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                throw StateDatabaseRestoreError.restoreConflict(detail)
            }
            throw StateDatabaseRestoreError.sqliteFailure(detail)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func removeDatabaseArtifacts(_ database: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
    }

    private static func selectedPredicate(
        table: String,
        ids: String,
        alias: String? = nil
    ) -> String {
        func column(_ name: String) -> String {
            guard let alias else { return quoteIdentifier(name) }
            return qualifiedIdentifier(alias: alias, column: name)
        }
        switch table {
        case "threads":
            return "\(column("id")) IN (\(ids))"
        case "thread_spawn_edges":
            return "\(column("parent_thread_id")) IN (\(ids)) OR \(column("child_thread_id")) IN (\(ids))"
        case "agent_job_items":
            return "\(column("assigned_thread_id")) IN (\(ids))"
        default:
            return "\(column("thread_id")) IN (\(ids))"
        }
    }

    private static func qualifiedIdentifier(alias: String, column: String) -> String {
        "\(quoteIdentifier(alias)).\(quoteIdentifier(column))"
    }

    private static func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func quoteLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

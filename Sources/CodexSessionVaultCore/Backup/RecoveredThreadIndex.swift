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

    public init(
        id: String,
        rolloutPath: String,
        createdAt: Int64,
        updatedAt: Int64,
        source: String,
        modelProvider: String,
        cwd: String,
        title: String,
        sandboxPolicy: String,
        approvalMode: String,
        tokensUsed: Int64,
        hasUserEvent: Int,
        archived: Int,
        archivedAt: Int64?,
        firstUserMessage: String,
        model: String,
        preview: String,
        recencyAt: Int64,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        recencyAtMs: Int64,
        threadSource: String,
        reasoningEffort: String?,
        cliVersion: String,
        memoryMode: String,
        gitSHA: String?,
        gitBranch: String?,
        gitOriginURL: String?,
        agentNickname: String?,
        agentRole: String?,
        agentPath: String?
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.modelProvider = modelProvider
        self.cwd = cwd
        self.title = title
        self.sandboxPolicy = sandboxPolicy
        self.approvalMode = approvalMode
        self.tokensUsed = tokensUsed
        self.hasUserEvent = hasUserEvent
        self.archived = archived
        self.archivedAt = archivedAt
        self.firstUserMessage = firstUserMessage
        self.model = model
        self.preview = preview
        self.recencyAt = recencyAt
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.recencyAtMs = recencyAtMs
        self.threadSource = threadSource
        self.reasoningEffort = reasoningEffort
        self.cliVersion = cliVersion
        self.memoryMode = memoryMode
        self.gitSHA = gitSHA
        self.gitBranch = gitBranch
        self.gitOriginURL = gitOriginURL
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
    }
}

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
        if let warning {
            return warning
        }
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
        var statements: [String] = ["BEGIN IMMEDIATE;"]

        for entry in entries {
            if try threadExists(databaseURL: databaseURL, id: entry.id) {
                skipped += 1
                continue
            }
            statements.append(insertStatement(entry: entry, columns: columns))
            inserted += 1
        }

        if inserted > 0 {
            statements.append("COMMIT;")
            do {
                try runSQLite(databaseURL: databaseURL, sql: statements.joined(separator: "\n"))
            } catch {
                _ = try? runSQLite(databaseURL: databaseURL, sql: "ROLLBACK;")
                throw error
            }
        }

        return RecoveredThreadIndexResult(insertedCount: inserted, skippedCount: skipped, warning: nil)
    }

    private func tableExists(databaseURL: URL, table: String) throws -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = \(sqliteStringLiteral(table));"
        let output = try runSQLite(databaseURL: databaseURL, sql: sql)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func tableColumns(databaseURL: URL, table: String) throws -> [SQLiteColumn] {
        let output = try runSQLite(
            databaseURL: databaseURL,
            arguments: ["-json"],
            sql: "PRAGMA table_info(\(sqliteIdentifier(table)));"
        )
        return try JSONDecoder().decode([SQLiteColumn].self, from: Data(output.utf8))
    }

    private func threadExists(databaseURL: URL, id: String) throws -> Bool {
        let sql = "SELECT id FROM threads WHERE id = \(sqliteStringLiteral(id)) LIMIT 1;"
        let output = try runSQLite(databaseURL: databaseURL, sql: sql)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    private func runSQLite(databaseURL: URL, arguments: [String] = [], sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = arguments + [databaseURL.path, sql]
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
        if process.terminationStatus != 0 {
            throw RecoveredThreadIndexError.sqliteFailed(error.isEmpty ? output : error)
        }
        return output
    }

    private func insertStatement(entry: RecoveredThreadIndexEntry, columns: [SQLiteColumn]) -> String {
        let values = sqlValues(for: entry)
        let writable = columns.compactMap { column -> (String, String)? in
            if let value = values[column.name] {
                return (column.name, value)
            }
            if column.notnull == 1, column.dfltValue == nil {
                return (column.name, fallbackSQLValue(for: column))
            }
            return nil
        }
        let names = writable.map { sqliteIdentifier($0.0) }.joined(separator: ", ")
        let rawValues = writable.map(\.1).joined(separator: ", ")
        return "INSERT INTO threads (\(names)) VALUES (\(rawValues));"
    }
}

public func makeRecoveredThreadIndexEntry(
    record: BackupSessionRecord,
    recoveredURL: URL,
    codexRoot: URL,
    fileManager _: FileManager = .default
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
        reasoningEffort: metadata.reasoningEffort,
        cliVersion: metadata.cliVersion ?? "",
        memoryMode: metadata.memoryMode ?? "enabled",
        gitSHA: metadata.gitSHA,
        gitBranch: metadata.gitBranch,
        gitOriginURL: metadata.gitOriginURL,
        agentNickname: metadata.agentNickname,
        agentRole: metadata.agentRole,
        agentPath: metadata.agentPath
    )
}

private enum RecoveredThreadIndexError: LocalizedError {
    case sqliteFailed(String)

    var errorDescription: String? {
        switch self {
        case let .sqliteFailed(message):
            return "SQLite 索引写入失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

private struct SQLiteColumn: Decodable {
    let name: String
    let type: String
    let notnull: Int
    let dfltValue: String?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case notnull
        case dfltValue = "dflt_value"
    }
}

private struct RecoveredJSONLMetadata {
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var firstUserMessage = ""
    var provider: String?
    var model: String?
    var cwd: String?
    var source: String?
    var sandboxPolicy: String?
    var approvalMode: String?
    var reasoningEffort: String?
    var cliVersion: String?
    var memoryMode: String?
    var gitSHA: String?
    var gitBranch: String?
    var gitOriginURL: String?
    var agentNickname: String?
    var agentRole: String?
    var agentPath: String?
}

private func extractRecoveredJSONLMetadata(from url: URL) throws -> RecoveredJSONLMetadata {
    let lines = try firstRecoveredJSONLLines(from: url)
    var metadata = RecoveredJSONLMetadata()

    for rawLine in lines {
        guard let object = try? JSONSerialization.jsonObject(with: rawLine) as? [String: Any] else {
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
        metadata.reasoningEffort = metadata.reasoningEffort ?? stringValue(object["reasoning_effort"]) ?? stringValue(payload?["reasoning_effort"])
        metadata.cliVersion = metadata.cliVersion ?? stringValue(object["cli_version"]) ?? stringValue(payload?["cli_version"])
        metadata.memoryMode = metadata.memoryMode ?? stringValue(object["memory_mode"]) ?? stringValue(payload?["memory_mode"])
        metadata.gitSHA = metadata.gitSHA ?? stringValue(object["git_sha"]) ?? stringValue(payload?["git_sha"])
        metadata.gitBranch = metadata.gitBranch ?? stringValue(object["git_branch"]) ?? stringValue(payload?["git_branch"])
        metadata.gitOriginURL = metadata.gitOriginURL ?? stringValue(object["git_origin_url"]) ?? stringValue(payload?["git_origin_url"])
        metadata.agentNickname = metadata.agentNickname ?? stringValue(object["agent_nickname"]) ?? stringValue(payload?["agent_nickname"])
        metadata.agentRole = metadata.agentRole ?? stringValue(object["agent_role"]) ?? stringValue(payload?["agent_role"])
        metadata.agentPath = metadata.agentPath ?? stringValue(object["agent_path"]) ?? stringValue(payload?["agent_path"])
        if metadata.firstUserMessage.isEmpty, let message = firstUserMessage(from: object) {
            metadata.firstUserMessage = collapseWhitespace(message)
        }
    }
    return metadata
}

private func firstRecoveredJSONLLines(from url: URL, limit: Int = 400) throws -> [Data] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var lines: [Data] = []
    var pending = Data()
    while lines.count < limit,
          let chunk = try handle.read(upToCount: 1_048_576),
          !chunk.isEmpty {
        var start = chunk.startIndex
        for newline in chunk.indices where chunk[newline] == 0x0A {
            if start < newline {
                pending.append(contentsOf: chunk[start..<newline])
            }
            if !pending.isEmpty { lines.append(pending) }
            pending.removeAll(keepingCapacity: true)
            if lines.count == limit { return lines }
            start = chunk.index(after: newline)
        }
        if start < chunk.endIndex {
            pending.append(contentsOf: chunk[start..<chunk.endIndex])
            guard pending.count <= SessionTailer.defaultMaxLineBytes else {
                throw BackupFileVerificationError.lineTooLong(SessionTailer.defaultMaxLineBytes)
            }
        }
    }
    if !pending.isEmpty, lines.count < limit { lines.append(pending) }
    return lines
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
    if let string = value as? String {
        return string
    }
    if let items = value as? [[String: Any]] {
        let texts = items.compactMap { item -> String? in
            if let text = item["text"] as? String {
                return text
            }
            if let text = item["content"] as? String {
                return text
            }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
    return nil
}

private func sqlValues(for entry: RecoveredThreadIndexEntry) -> [String: String] {
    [
        "id": sqliteStringLiteral(entry.id),
        "rollout_path": sqliteStringLiteral(entry.rolloutPath),
        "created_at": String(entry.createdAt),
        "updated_at": String(entry.updatedAt),
        "source": sqliteStringLiteral(entry.source),
        "model_provider": sqliteStringLiteral(entry.modelProvider),
        "cwd": sqliteStringLiteral(entry.cwd),
        "title": sqliteStringLiteral(entry.title),
        "sandbox_policy": sqliteStringLiteral(entry.sandboxPolicy),
        "approval_mode": sqliteStringLiteral(entry.approvalMode),
        "tokens_used": String(entry.tokensUsed),
        "has_user_event": String(entry.hasUserEvent),
        "archived": String(entry.archived),
        "archived_at": entry.archivedAt.map(String.init) ?? "NULL",
        "first_user_message": sqliteStringLiteral(entry.firstUserMessage),
        "model": sqliteStringLiteral(entry.model),
        "preview": sqliteStringLiteral(entry.preview),
        "recency_at": String(entry.recencyAt),
        "created_at_ms": String(entry.createdAtMs),
        "updated_at_ms": String(entry.updatedAtMs),
        "recency_at_ms": String(entry.recencyAtMs),
        "thread_source": sqliteStringLiteral(entry.threadSource),
        "reasoning_effort": entry.reasoningEffort.map(sqliteStringLiteral) ?? "NULL",
        "cli_version": sqliteStringLiteral(entry.cliVersion),
        "memory_mode": sqliteStringLiteral(entry.memoryMode),
        "git_sha": entry.gitSHA.map(sqliteStringLiteral) ?? "NULL",
        "git_branch": entry.gitBranch.map(sqliteStringLiteral) ?? "NULL",
        "git_origin_url": entry.gitOriginURL.map(sqliteStringLiteral) ?? "NULL",
        "agent_nickname": entry.agentNickname.map(sqliteStringLiteral) ?? "NULL",
        "agent_role": entry.agentRole.map(sqliteStringLiteral) ?? "NULL",
        "agent_path": entry.agentPath.map(sqliteStringLiteral) ?? "NULL"
    ]
}

private func fallbackSQLValue(for column: SQLiteColumn) -> String {
    let uppercasedType = column.type.uppercased()
    if uppercasedType.contains("INT") || uppercasedType.contains("REAL") || uppercasedType.contains("NUM") {
        return "0"
    }
    return "''"
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

private func sqliteIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func sqliteStringLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

import Foundation

public struct BackupCursor: Equatable, Sendable {
    public var sessionId: String
    public var sourcePath: String
    public var backupPath: String
    public var lastByteOffset: Int64
    public var lastSourceSize: Int64
    public var lastSourceModifiedAt: TimeInterval
    public var sourceFileIdentity: String?
    public var lineCount: Int
    public var pendingPartialLine: Data
    public var status: String
    public var lastError: String?
    public var blockedLineLimitBytes: Int?
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
        updatedAt: TimeInterval,
        sourceFileIdentity: String? = nil,
        blockedLineLimitBytes: Int? = nil
    ) {
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.backupPath = backupPath
        self.lastByteOffset = lastByteOffset
        self.lastSourceSize = lastSourceSize
        self.lastSourceModifiedAt = lastSourceModifiedAt
        self.sourceFileIdentity = sourceFileIdentity
        self.lineCount = lineCount
        self.pendingPartialLine = pendingPartialLine
        self.status = status
        self.lastError = lastError
        self.blockedLineLimitBytes = blockedLineLimitBytes
        self.updatedAt = updatedAt
    }
}

public final class BackupCursorStore {
    private let databaseURL: URL
    private let sqlitePath: String
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let sqliteRunner: (([String], String) throws -> String)?

    public init(databaseURL: URL, sqlitePath: String = "/usr/bin/sqlite3") {
        self.databaseURL = databaseURL
        self.sqlitePath = sqlitePath
        self.fileManager = .default
        self.decoder = JSONDecoder()
        self.sqliteRunner = nil
    }

    init(
        databaseURL: URL,
        sqlitePath: String = "/usr/bin/sqlite3",
        sqliteRunner: @escaping ([String], String) throws -> String
    ) {
        self.databaseURL = databaseURL
        self.sqlitePath = sqlitePath
        self.fileManager = .default
        self.decoder = JSONDecoder()
        self.sqliteRunner = sqliteRunner
    }

    public func open() throws {
        let parent = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        if (try? fileManager.destinationOfSymbolicLink(atPath: databaseURL.path)) != nil {
            throw CocoaError(.fileWriteNoPermission)
        }
        let databaseExisted = fileManager.fileExists(atPath: databaseURL.path)
        if !databaseExisted {
            guard fileManager.createFile(
                atPath: databaseURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)

        let createTable = """
        CREATE TABLE IF NOT EXISTS backup_cursors (
            source_path TEXT NOT NULL PRIMARY KEY,
            session_id TEXT NOT NULL,
            backup_path TEXT NOT NULL,
            last_byte_offset INTEGER NOT NULL,
            last_source_size INTEGER NOT NULL,
            last_source_modified_at REAL NOT NULL,
            source_file_identity TEXT,
            line_count INTEGER NOT NULL,
            pending_partial_line TEXT NOT NULL,
            status TEXT NOT NULL,
            last_error TEXT,
            blocked_line_limit_bytes INTEGER,
            updated_at REAL NOT NULL
        );
        """
        if databaseExisted {
            let columns = try cursorColumnNames()
            if columns.isEmpty {
                try execute(createTable)
            } else {
                var migrations: [String] = []
                if !columns.contains("source_file_identity") {
                    migrations.append("ALTER TABLE backup_cursors ADD COLUMN source_file_identity TEXT;")
                }
                if !columns.contains("blocked_line_limit_bytes") {
                    migrations.append("ALTER TABLE backup_cursors ADD COLUMN blocked_line_limit_bytes INTEGER;")
                    migrations.append("""
                    UPDATE backup_cursors
                    SET blocked_line_limit_bytes = 33554432
                    WHERE blocked_line_limit_bytes IS NULL
                      AND last_error LIKE 'Session JSONL line exceeds maximum JSONL line size of 33554432 bytes at offset %';
                    """)
                }
                if !migrations.isEmpty {
                    try execute("""
                    .bail on
                    .timeout 5000
                    BEGIN IMMEDIATE;
                    \(migrations.joined(separator: "\n"))
                    COMMIT;
                    """)
                }
            }
        } else {
            try execute(createTable)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    public func loadAll() throws -> [String: BackupCursor] {
        try loadAll(readOnly: false)
    }

    func loadAllReadOnly() throws -> [String: BackupCursor] {
        try loadAll(readOnly: true)
    }

    private func loadAll(readOnly: Bool) throws -> [String: BackupCursor] {
        let output = try queryJSON("""
        SELECT
            session_id,
            source_path,
            backup_path,
            last_byte_offset,
            last_source_size,
            last_source_modified_at,
            source_file_identity,
            line_count,
            pending_partial_line,
            status,
            last_error,
            blocked_line_limit_bytes,
            updated_at
        FROM backup_cursors
        ORDER BY source_path COLLATE BINARY ASC;
        """, readOnly: readOnly)

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }

        let rows = try decoder.decode([CursorRow].self, from: Data(output.utf8))
        var cursors: [String: BackupCursor] = [:]
        cursors.reserveCapacity(rows.count)

        for row in rows {
            let cursor = try row.cursor()
            guard cursors.updateValue(cursor, forKey: cursor.sourcePath) == nil else {
                throw BackupCursorStoreError.duplicateSourcePath(cursor.sourcePath)
            }
        }

        return cursors
    }

    public func cursor(sourcePath: String) throws -> BackupCursor? {
        try loadAll()[sourcePath]
    }

    public func upsert(_ cursor: BackupCursor) throws {
        try upsertMany([cursor])
    }

    public func upsertMany(
        _ cursors: [BackupCursor],
        deletingSourcePaths: [String] = []
    ) throws {
        let upsertedSourcePaths = Set(cursors.map(\.sourcePath))
        let deletedSourcePaths = Set(deletingSourcePaths).subtracting(upsertedSourcePaths)
        guard !cursors.isEmpty || !deletedSourcePaths.isEmpty else {
            return
        }

        let deletions = deletedSourcePaths.sorted().map { sourcePath in
            "DELETE FROM backup_cursors WHERE source_path = \(Self.sqlText(sourcePath));"
        }.joined(separator: "\n")
        let statements = cursors.map(Self.upsertStatement).joined(separator: "\n")
        try execute("""
        .bail on
        .timeout 5000
        BEGIN IMMEDIATE;
        \(deletions)
        \(statements)
        COMMIT;
        """)
    }

    private static func upsertStatement(_ cursor: BackupCursor) -> String {
        let pendingPartialLine = cursor.pendingPartialLine.base64EncodedString()

        return """
        INSERT INTO backup_cursors (
            source_path,
            session_id,
            backup_path,
            last_byte_offset,
            last_source_size,
            last_source_modified_at,
            source_file_identity,
            line_count,
            pending_partial_line,
            status,
            last_error,
            blocked_line_limit_bytes,
            updated_at
        ) VALUES (
            \(Self.sqlText(cursor.sourcePath)),
            \(Self.sqlText(cursor.sessionId)),
            \(Self.sqlText(cursor.backupPath)),
            \(cursor.lastByteOffset),
            \(cursor.lastSourceSize),
            \(cursor.lastSourceModifiedAt),
            \(Self.sqlNullableText(cursor.sourceFileIdentity)),
            \(cursor.lineCount),
            \(Self.sqlText(pendingPartialLine)),
            \(Self.sqlText(cursor.status)),
            \(Self.sqlNullableText(cursor.lastError)),
            \(Self.sqlNullableInt(cursor.blockedLineLimitBytes)),
            \(cursor.updatedAt)
        )
        ON CONFLICT(source_path) DO UPDATE SET
            session_id = excluded.session_id,
            backup_path = excluded.backup_path,
            last_byte_offset = excluded.last_byte_offset,
            last_source_size = excluded.last_source_size,
            last_source_modified_at = excluded.last_source_modified_at,
            source_file_identity = excluded.source_file_identity,
            line_count = excluded.line_count,
            pending_partial_line = excluded.pending_partial_line,
            status = excluded.status,
            last_error = excluded.last_error,
            blocked_line_limit_bytes = excluded.blocked_line_limit_bytes,
            updated_at = excluded.updated_at;
        """
    }

    private func execute(_ sql: String) throws {
        _ = try runSQLite(arguments: baseSQLiteArguments + [databaseURL.path], input: sql)
    }

    private func queryJSON(_ sql: String, readOnly: Bool = false) throws -> String {
        let mode = readOnly ? ["-readonly"] : []
        return try runSQLite(
            arguments: baseSQLiteArguments + mode + ["-json", databaseURL.path],
            input: sql
        )
    }

    private func cursorColumnNames() throws -> Set<String> {
        let output = try queryJSON(
            "SELECT name FROM pragma_table_info('backup_cursors') ORDER BY cid;",
            readOnly: true
        )
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return Set(try decoder.decode([CursorColumnRow].self, from: Data(output.utf8)).map(\.name))
    }

    private var baseSQLiteArguments: [String] {
        ["-batch", "-bail", "-cmd", ".timeout 5000"]
    }

    private func runSQLite(arguments: [String], input: String) throws -> String {
        if let sqliteRunner {
            return try sqliteRunner(arguments, input)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = arguments

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

        let outputCollector = PipeDataCollector()
        let errorCollector = PipeDataCollector()
        let readGroup = DispatchGroup()

        do {
            try process.run()
        } catch {
            throw BackupCursorStoreError.launchFailed(sqlitePath: sqlitePath, underlying: error)
        }

        inputWriter.write(Data(input.utf8))
        try? inputWriter.close()
        Self.drain(outputPipe, into: outputCollector, group: readGroup)
        Self.drain(errorPipe, into: errorCollector, group: readGroup)

        process.waitUntilExit()
        readGroup.wait()

        let output = String(data: outputCollector.collectedData(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorCollector.collectedData(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw BackupCursorStoreError.sqliteFailed(
                status: process.terminationStatus,
                stderr: errorOutput
            )
        }

        return output
    }

    private static func drain(_ pipe: Pipe, into collector: PipeDataCollector, group: DispatchGroup) {
        group.enter()
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            let data = reader.readDataToEndOfFile()
            try? reader.close()
            collector.append(data)
            group.leave()
        }
    }

    private static func sqlText(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlNullableText(_ value: String?) -> String {
        guard let value else {
            return "NULL"
        }
        return sqlText(value)
    }

    private static func sqlNullableInt(_ value: Int?) -> String {
        value.map(String.init) ?? "NULL"
    }
}

private struct CursorRow: Decodable {
    var sessionId: String
    var sourcePath: String
    var backupPath: String
    var lastByteOffset: Int64
    var lastSourceSize: Int64
    var lastSourceModifiedAt: TimeInterval
    var sourceFileIdentity: String?
    var lineCount: Int
    var pendingPartialLine: String
    var status: String
    var lastError: String?
    var blockedLineLimitBytes: Int?
    var updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sourcePath = "source_path"
        case backupPath = "backup_path"
        case lastByteOffset = "last_byte_offset"
        case lastSourceSize = "last_source_size"
        case lastSourceModifiedAt = "last_source_modified_at"
        case sourceFileIdentity = "source_file_identity"
        case lineCount = "line_count"
        case pendingPartialLine = "pending_partial_line"
        case status
        case lastError = "last_error"
        case blockedLineLimitBytes = "blocked_line_limit_bytes"
        case updatedAt = "updated_at"
    }

    func cursor() throws -> BackupCursor {
        guard let pendingPartialLineData = Data(base64Encoded: pendingPartialLine) else {
            throw BackupCursorStoreError.invalidPendingPartialLine
        }

        return BackupCursor(
            sessionId: sessionId,
            sourcePath: sourcePath,
            backupPath: backupPath,
            lastByteOffset: lastByteOffset,
            lastSourceSize: lastSourceSize,
            lastSourceModifiedAt: lastSourceModifiedAt,
            lineCount: lineCount,
            pendingPartialLine: pendingPartialLineData,
            status: status,
            lastError: lastError,
            updatedAt: updatedAt,
            sourceFileIdentity: sourceFileIdentity,
            blockedLineLimitBytes: blockedLineLimitBytes
        )
    }
}

private struct CursorColumnRow: Decodable {
    var name: String
}

private enum BackupCursorStoreError: Error, Sendable {
    case launchFailed(sqlitePath: String, underlying: Error)
    case sqliteFailed(status: Int32, stderr: String)
    case invalidPendingPartialLine
    case duplicateSourcePath(String)
}

extension BackupCursorStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .launchFailed(sqlitePath, underlying):
            "Failed to launch sqlite3 at \(sqlitePath): \(underlying.localizedDescription)"
        case let .sqliteFailed(status, stderr):
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "sqlite3 failed with exit status \(status)."
            } else {
                "sqlite3 failed with exit status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        case .invalidPendingPartialLine:
            "Stored backup cursor has invalid base64 pending partial line data."
        case let .duplicateSourcePath(sourcePath):
            "Stored backup cursors contain duplicate source path: \(sourcePath)"
        }
    }
}

private final class PipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

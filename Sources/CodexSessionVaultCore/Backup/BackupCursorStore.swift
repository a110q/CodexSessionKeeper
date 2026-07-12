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
    private let sqlitePath: String
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    public init(databaseURL: URL, sqlitePath: String = "/usr/bin/sqlite3") {
        self.databaseURL = databaseURL
        self.sqlitePath = sqlitePath
        self.fileManager = .default
        self.decoder = JSONDecoder()
    }

    public func open() throws {
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try execute("""
        CREATE TABLE IF NOT EXISTS backup_cursors (
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
        """)
    }

    public func cursor(sourcePath: String) throws -> BackupCursor? {
        let output = try queryJSON("""
        SELECT
            session_id,
            source_path,
            backup_path,
            last_byte_offset,
            last_source_size,
            last_source_modified_at,
            line_count,
            pending_partial_line,
            status,
            last_error,
            updated_at
        FROM backup_cursors
        WHERE source_path = \(Self.sqlText(sourcePath))
        LIMIT 1;
        """)

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let rows = try decoder.decode([CursorRow].self, from: Data(output.utf8))
        guard let row = rows.first else {
            return nil
        }

        return try row.cursor()
    }

    public func upsert(_ cursor: BackupCursor) throws {
        let pendingPartialLine = cursor.pendingPartialLine.base64EncodedString()

        try execute("""
        INSERT INTO backup_cursors (
            source_path,
            session_id,
            backup_path,
            last_byte_offset,
            last_source_size,
            last_source_modified_at,
            line_count,
            pending_partial_line,
            status,
            last_error,
            updated_at
        ) VALUES (
            \(Self.sqlText(cursor.sourcePath)),
            \(Self.sqlText(cursor.sessionId)),
            \(Self.sqlText(cursor.backupPath)),
            \(cursor.lastByteOffset),
            \(cursor.lastSourceSize),
            \(cursor.lastSourceModifiedAt),
            \(cursor.lineCount),
            \(Self.sqlText(pendingPartialLine)),
            \(Self.sqlText(cursor.status)),
            \(Self.sqlNullableText(cursor.lastError)),
            \(cursor.updatedAt)
        )
        ON CONFLICT(source_path) DO UPDATE SET
            session_id = excluded.session_id,
            backup_path = excluded.backup_path,
            last_byte_offset = excluded.last_byte_offset,
            last_source_size = excluded.last_source_size,
            last_source_modified_at = excluded.last_source_modified_at,
            line_count = excluded.line_count,
            pending_partial_line = excluded.pending_partial_line,
            status = excluded.status,
            last_error = excluded.last_error,
            updated_at = excluded.updated_at;
        """)
    }

    private func execute(_ sql: String) throws {
        _ = try runSQLite(arguments: baseSQLiteArguments + [databaseURL.path], input: sql)
    }

    private func queryJSON(_ sql: String) throws -> String {
        try runSQLite(arguments: baseSQLiteArguments + ["-json", databaseURL.path], input: sql)
    }

    private var baseSQLiteArguments: [String] {
        ["-batch", "-bail", "-cmd", ".timeout 5000"]
    }

    private func runSQLite(arguments: [String], input: String) throws -> String {
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
}

private struct CursorRow: Decodable {
    var sessionId: String
    var sourcePath: String
    var backupPath: String
    var lastByteOffset: Int64
    var lastSourceSize: Int64
    var lastSourceModifiedAt: TimeInterval
    var lineCount: Int
    var pendingPartialLine: String
    var status: String
    var lastError: String?
    var updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sourcePath = "source_path"
        case backupPath = "backup_path"
        case lastByteOffset = "last_byte_offset"
        case lastSourceSize = "last_source_size"
        case lastSourceModifiedAt = "last_source_modified_at"
        case lineCount = "line_count"
        case pendingPartialLine = "pending_partial_line"
        case status
        case lastError = "last_error"
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
            updatedAt: updatedAt
        )
    }
}

private enum BackupCursorStoreError: Error, Sendable {
    case launchFailed(sqlitePath: String, underlying: Error)
    case sqliteFailed(status: Int32, stderr: String)
    case invalidPendingPartialLine
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

import Foundation

public final class BackupAgent: @unchecked Sendable {
    private static let agentVersion = "1.0.0"
    private static let activeStatus = "active"
    private static let newline = Data([0x0A])

    private let paths: BackupPaths
    private let now: () -> Date
    private let fileManager: FileManager
    private let tailer: SessionTailer
    private let taskLock = NSLock()
    private var pollingTask: Task<Void, Never>?

    public init(
        paths: BackupPaths = BackupPaths(),
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        tailer: SessionTailer = SessionTailer()
    ) {
        self.paths = paths
        self.now = now
        self.fileManager = fileManager
        self.tailer = tailer
    }

    deinit {
        stop()
    }

    public func performOneShotScan() throws {
        let scanDate = now()
        try ensureBackupDirectoriesExist()

        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()

        let manifestURL = paths.manifestURL
        let manifestExisted = fileManager.fileExists(atPath: manifestURL.path)
        let manifestStore = BackupManifestStore(manifestURL: manifestURL)
        var manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: scanDate
        )
        var manifestChanged = !manifestExisted

        if manifest.codexRoot != paths.codexRoot.path {
            manifest.codexRoot = paths.codexRoot.path
            manifestChanged = true
        }
        if manifest.backupRoot != paths.backupRoot.path {
            manifest.backupRoot = paths.backupRoot.path
            manifestChanged = true
        }

        for sourceURL in try discoverSessionFiles() {
            guard let sessionID = SessionIdentity.sessionID(from: sourceURL) else {
                continue
            }

            let changed = try processSessionFile(
                sourceURL,
                sessionID: sessionID,
                scanDate: scanDate,
                manifest: &manifest,
                cursorStore: cursorStore
            )
            manifestChanged = manifestChanged || changed
        }

        if manifestChanged {
            manifest.updatedAt = scanDate
            try manifestStore.save(manifest)
        }

        try writeStatus(for: manifest, status: .running, lastError: nil, at: scanDate)
    }

    public func startPolling(intervalSeconds: UInt64 = 10) {
        taskLock.lock()
        defer { taskLock.unlock() }

        guard pollingTask == nil else {
            return
        }

        let sleepNanoseconds = Self.nanoseconds(fromSeconds: intervalSeconds)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let agent = self else {
                        return
                    }
                    try agent.performOneShotScan()
                } catch {
                    guard let agent = self else {
                        return
                    }
                    try? agent.writeErrorStatus(error)
                }

                guard !Task.isCancelled else {
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        taskLock.lock()
        let task = pollingTask
        pollingTask = nil
        taskLock.unlock()

        task?.cancel()
    }

    private func ensureBackupDirectoriesExist() throws {
        try fileManager.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sessionsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: paths.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func discoverSessionFiles() throws -> [URL] {
        let roots = [
            paths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
            paths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        var discovered: [URL] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "jsonl" else {
                    continue
                }

                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues.isRegularFile == true else {
                    continue
                }

                discovered.append(fileURL)
            }
        }

        return discovered.sorted { $0.path < $1.path }
    }

    private func processSessionFile(
        _ sourceURL: URL,
        sessionID: String,
        scanDate: Date,
        manifest: inout BackupManifest,
        cursorStore: BackupCursorStore
    ) throws -> Bool {
        let sourcePath = sourceURL.path
        let existingRecord = manifest.sessions[sessionID]
        let existingCursor = try cursorStore.cursor(sourcePath: sourcePath)
        let firstSeenAt = existingRecord?.firstSeenAt ?? scanDate
        let backupURL = try backupFileURL(
            for: sessionID,
            firstSeenAt: firstSeenAt,
            existingRecord: existingRecord
        )
        let relativeBackupPath = try validatedRelativeBackupPath(for: backupURL)
        let readOffset = existingCursor?.lastByteOffset ?? 0
        let tailResult = try tailer.readNewCompleteLines(from: sourceURL, offset: readOffset)
        let sourceMetadata = try metadata(for: sourceURL)

        let appendedByteCount: Int64
        if tailResult.lines.isEmpty {
            appendedByteCount = 0
        } else {
            appendedByteCount = try append(lines: tailResult.lines, to: backupURL)
        }

        let newLineCount = tailResult.lines.count
        let existingLineCount = existingRecord?.lineCount ?? existingCursor?.lineCount ?? 0
        let totalLineCount = existingLineCount + newLineCount
        let existingBytesBackedUp = existingRecord?.bytesBackedUp ?? 0
        let totalBytesBackedUp = existingBytesBackedUp + appendedByteCount
        let title = existingRecord?.title ?? firstTitle(in: tailResult.lines)

        var manifestChanged = existingRecord == nil
        if newLineCount > 0 {
            manifestChanged = true
        }
        if existingRecord?.sourcePath != nil, existingRecord?.sourcePath != sourcePath {
            manifestChanged = true
        }
        if existingRecord?.backupPath != nil, existingRecord?.backupPath != relativeBackupPath {
            manifestChanged = true
        }
        if existingRecord?.status != nil, existingRecord?.status != Self.activeStatus {
            manifestChanged = true
        }
        if existingRecord?.title == nil, title != nil {
            manifestChanged = true
        }

        if manifestChanged {
            manifest.sessions[sessionID] = BackupSessionRecord(
                sessionId: sessionID,
                sourcePath: sourcePath,
                backupPath: relativeBackupPath,
                title: title,
                firstSeenAt: firstSeenAt,
                lastBackedUpAt: newLineCount > 0 ? scanDate : existingRecord?.lastBackedUpAt,
                lineCount: totalLineCount,
                bytesBackedUp: totalBytesBackedUp,
                status: Self.activeStatus
            )
        }

        try cursorStore.upsert(BackupCursor(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            lastByteOffset: tailResult.nextOffset,
            lastSourceSize: sourceMetadata.size,
            lastSourceModifiedAt: sourceMetadata.modifiedAt,
            lineCount: totalLineCount,
            pendingPartialLine: tailResult.pendingPartialLine,
            status: Self.activeStatus,
            lastError: nil,
            updatedAt: scanDate.timeIntervalSince1970
        ))

        return manifestChanged
    }

    private func backupFileURL(
        for sessionID: String,
        firstSeenAt: Date,
        existingRecord: BackupSessionRecord?
    ) throws -> URL {
        guard let existingRecord else {
            return paths.backupFileURL(sessionID: sessionID, firstSeenAt: firstSeenAt)
        }

        if existingRecord.backupPath.hasPrefix("/") {
            return URL(fileURLWithPath: existingRecord.backupPath)
        }

        return paths.backupRoot.appendingPathComponent(existingRecord.backupPath)
    }

    private func validatedRelativeBackupPath(for backupURL: URL) throws -> String {
        guard let relativePath = paths.relativeBackupPath(for: backupURL) else {
            throw BackupAgentError.backupPathOutsideRoot(
                path: backupURL.path,
                backupRoot: paths.backupRoot.path
            )
        }

        return relativePath
    }

    private func append(lines: [Data], to backupURL: URL) throws -> Int64 {
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !fileManager.fileExists(atPath: backupURL.path) {
            fileManager.createFile(atPath: backupURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: backupURL)
        defer { try? handle.close() }

        try handle.seekToEnd()
        var appendedByteCount: Int64 = 0
        for line in lines {
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Self.newline)
            appendedByteCount += Int64(line.count + Self.newline.count)
        }

        return appendedByteCount
    }

    private func firstTitle(in lines: [Data]) -> String? {
        for line in lines {
            guard let text = String(data: line, encoding: .utf8),
                  let title = SessionIdentity.title(fromJSONLine: text)
            else {
                continue
            }

            return title
        }

        return nil
    }

    private func metadata(for sourceURL: URL) throws -> (size: Int64, modifiedAt: TimeInterval) {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modifiedAt)
    }

    private func writeStatus(
        for manifest: BackupManifest,
        status: BackupHealthStatus,
        lastError: String?,
        at date: Date
    ) throws {
        try fileManager.createDirectory(
            at: paths.statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existingStatus = try? loadStatus()
        let records = Array(manifest.sessions.values)
        let lastBackupAt = records
            .compactMap(\.lastBackedUpAt)
            .max()
        let snapshot = BackupStatus(
            agentVersion: Self.agentVersion,
            enabled: true,
            status: status,
            mode: .polling,
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            firstRunAt: existingStatus?.firstRunAt ?? date,
            lastStartedAt: existingStatus?.lastStartedAt ?? date,
            lastHeartbeatAt: date,
            lastBackupAt: lastBackupAt,
            sessionCount: records.count,
            lineCount: records.reduce(0) { $0 + $1.lineCount },
            bytesBackedUp: records.reduce(Int64(0)) { $0 + $1.bytesBackedUp },
            autoStartEnabled: false,
            lastError: lastError
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: paths.statusURL, options: [.atomic])
    }

    private func writeErrorStatus(_ error: Error) throws {
        try ensureBackupDirectoriesExist()

        let manifestStore = BackupManifestStore(manifestURL: paths.manifestURL)
        let manifest = (try? manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now()
        )) ?? BackupManifest(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            createdAt: now(),
            updatedAt: now()
        )

        try writeStatus(
            for: manifest,
            status: .error,
            lastError: error.localizedDescription,
            at: now()
        )
    }

    private func loadStatus() throws -> BackupStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupStatus.self, from: Data(contentsOf: paths.statusURL))
    }

    private static func nanoseconds(fromSeconds seconds: UInt64) -> UInt64 {
        let multiplier: UInt64 = 1_000_000_000
        guard seconds <= UInt64.max / multiplier else {
            return UInt64.max
        }

        return seconds * multiplier
    }
}

private enum BackupAgentError: Error, Sendable {
    case backupPathOutsideRoot(path: String, backupRoot: String)
}

extension BackupAgentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .backupPathOutsideRoot(path, backupRoot):
            "Backup path is outside backup root: \(path) is not contained in \(backupRoot)."
        }
    }
}

import Foundation

public enum BackupProgressPhase: String, Codable, Sendable {
    case seeding
    case scanning
}

public struct BackupProgress: Equatable, Sendable {
    public let totalFiles: Int
    public let completedFiles: Int
    public let pendingFiles: Int
    public let phase: BackupProgressPhase
}

public final class BackupAgent: @unchecked Sendable {
    private static let agentVersion = "2.0.0"
    private static let activeStatus = "active"

    private let paths: BackupPaths
    private let now: () -> Date
    private let fileManager: FileManager
    private let tailer: SessionTailer
    private let targetValidator: BackupTargetValidator
    private let fileCommitter: BackupFileCommitter
    private let progressHandler: ((BackupProgress) -> Void)?
    private let remoteStatusWriter: (Data, URL) throws -> Void
    private let scanLock = NSLock()
    private let taskLock = NSLock()
    private var pollingTask: Task<Void, Never>?
    private var pollingStartedAt: Date?

    private struct ProcessSessionFileResult {
        var manifestChanged: Bool
        var cursor: BackupCursor?
        var lastError: String?
    }

    public init(
        paths: BackupPaths = BackupPaths(),
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        tailer: SessionTailer = SessionTailer(),
        targetValidator: BackupTargetValidator? = nil,
        fileCommitter: BackupFileCommitter = BackupFileCommitter(),
        progressHandler: ((BackupProgress) -> Void)? = nil,
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.paths = paths
        self.now = now
        self.fileManager = fileManager
        self.tailer = tailer
        self.targetValidator = targetValidator ?? BackupTargetValidator(backupRoot: paths.backupRoot)
        self.fileCommitter = fileCommitter
        self.progressHandler = progressHandler
        self.remoteStatusWriter = remoteStatusWriter ?? { data, url in
            try DurableAtomicWriter().write(data, to: url, createParentDirectories: false)
        }
    }

    deinit {
        stop()
    }

    public func performOneShotScan() throws {
        scanLock.lock()
        defer { scanLock.unlock() }
        do {
            try performOneShotScanLocked()
        } catch {
            try? writeErrorStatus(error)
            throw error
        }
    }

    private func performOneShotScanLocked() throws {
        try targetValidator.validateTarget()
        try ensureLocalStateDirectoriesExist()
        let scanDate = now()
        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()

        let manifestExisted = fileManager.fileExists(atPath: paths.manifestURL.path)
        let manifestStore = BackupManifestStore(
            manifestURL: paths.manifestURL,
            createParentDirectories: false
        )
        var manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: scanDate
        )
        var manifestChanged = !manifestExisted
        if manifest.version != 2 {
            manifest.version = 2
            manifestChanged = true
        }
        if manifest.codexRoot != paths.codexRoot.path {
            manifest.codexRoot = paths.codexRoot.path
            manifestChanged = true
        }
        if manifest.backupRoot != paths.backupRoot.path {
            manifest.backupRoot = paths.backupRoot.path
            manifestChanged = true
        }

        let sources = try discoverSessionFiles()
        let phase: BackupProgressPhase = manifestExisted ? .scanning : .seeding
        var processedSessionIDs = Set<String>()
        var updatedCursors: [BackupCursor] = []
        var scanErrors: [String] = []
        var completed = 0
        for sourceURL in sources {
            guard let sessionID = SessionIdentity.sessionID(from: sourceURL),
                  processedSessionIDs.insert(sessionID).inserted else {
                continue
            }
            let result = try processSessionFile(
                sourceURL,
                sessionID: sessionID,
                scanDate: scanDate,
                manifest: &manifest,
                cursorStore: cursorStore
            )
            manifestChanged = manifestChanged || result.manifestChanged
            if let cursor = result.cursor {
                updatedCursors.append(cursor)
            }
            if let lastError = result.lastError {
                scanErrors.append(lastError)
            }
            completed += 1
            progressHandler?(BackupProgress(
                totalFiles: sources.count,
                completedFiles: completed,
                pendingFiles: max(0, sources.count - completed),
                phase: phase
            ))
        }

        if manifestChanged {
            manifest.updatedAt = scanDate
            try manifestStore.save(manifest)
        }
        for cursor in updatedCursors {
            let current = try cursorStore.cursor(sourcePath: cursor.sourcePath)
            if cursorNeedsUpsert(currentCursor: current, updatedCursor: cursor) {
                try cursorStore.upsert(cursor)
            }
        }

        try writeStatus(
            for: manifest,
            status: scanErrors.isEmpty ? .running : .error,
            lastError: scanErrors.first,
            at: scanDate,
            includeRemote: true
        )
        try writePendingSources([])
    }

    public func startPolling(intervalSeconds: UInt64 = 10) {
        taskLock.lock()
        defer { taskLock.unlock() }
        guard pollingTask == nil else { return }
        pollingStartedAt = now()
        let sleepNanoseconds = Self.nanoseconds(fromSeconds: intervalSeconds)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? self.performOneShotScan()
                guard !Task.isCancelled else { return }
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

    public func pendingSessionCount() throws -> Int {
        try ensureLocalStateDirectoriesExist()
        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        let existing = try loadPendingSources()
        var pendingByPath: [String: PendingSourceRecord] = [:]
        let sources = try discoverSessionFiles()
        let discoveredPaths = Set(sources.map(\.path))
        for source in sources {
            let metadata = try metadata(for: source)
            let cursor = try cursorStore.cursor(sourcePath: source.path)
            if cursor == nil
                || cursor?.lastSourceSize != metadata.size
                || cursor?.lastSourceModifiedAt != metadata.modifiedAt {
                pendingByPath[source.path] = PendingSourceRecord(
                    sourcePath: source.path,
                    sourceSize: metadata.size,
                    sourceModifiedAt: metadata.modifiedAt,
                    committedOffset: cursor?.lastByteOffset ?? 0,
                    unrecoverable: false
                )
            }
        }
        for record in existing where !discoveredPaths.contains(record.sourcePath) {
            pendingByPath[record.sourcePath] = PendingSourceRecord(
                sourcePath: record.sourcePath,
                sourceSize: record.sourceSize,
                sourceModifiedAt: record.sourceModifiedAt,
                committedOffset: record.committedOffset,
                unrecoverable: true
            )
        }
        let pending = pendingByPath.values.sorted { $0.sourcePath < $1.sourcePath }
        try writePendingSources(pending)
        return pending.count
    }

    private func processSessionFile(
        _ sourceURL: URL,
        sessionID: String,
        scanDate: Date,
        manifest: inout BackupManifest,
        cursorStore: BackupCursorStore
    ) throws -> ProcessSessionFileResult {
        let sourcePath = sourceURL.path
        let existingRecord = manifest.sessions[sessionID]
        let currentCursor = try cursorStore.cursor(sourcePath: sourcePath)
        let baselineCursor = try currentCursor ?? migratedCursor(
            for: existingRecord,
            currentSourcePath: sourcePath,
            cursorStore: cursorStore
        )
        let targetURL = try paths.backupFileURL(for: sourceURL)
        guard let relativeBackupPath = paths.relativeBackupPath(for: targetURL) else {
            throw BackupTargetValidationError.unsafeTarget(targetURL.path)
        }
        let sourceMetadata = try fileCommitter.inspectSource(sourceURL)
        let targetState = try fileCommitter.inspectTarget(targetURL)
        let targetExists = targetState.exists
        let recordedBytes = existingRecord?.bytesBackedUp ?? 0
        let recordedLines = existingRecord?.lineCount ?? 0
        let recordedOffset = baselineCursor?.lastByteOffset ?? 0
        let pathChanged = existingRecord.map { $0.backupPath != relativeBackupPath } ?? false
        var rebuild = pathChanged || sourceMetadata.byteCount < recordedOffset
        var readOffset = recordedOffset
        var baseLineCount = recordedLines
        if targetExists, !rebuild {
            if targetState.byteCount == recordedBytes {
                if let contentHash = existingRecord?.contentHash, recordedOffset > 0 {
                    rebuild = try fileCommitter.hashPrefix(of: sourceURL, byteCount: recordedOffset) != contentHash
                        || !fileCommitter.targetMatchesBoundedFingerprint(
                            targetURL,
                            source: sourceURL,
                            byteCount: recordedBytes
                        )
                } else if targetState.byteCount > 0 {
                    rebuild = try !fileCommitter.targetIsCompletePrefix(targetURL, of: sourceURL)
                }
            } else if targetState.byteCount > recordedBytes,
                      try fileCommitter.targetIsCompletePrefix(targetURL, of: sourceURL) {
                readOffset = targetState.byteCount
                baseLineCount = try fileCommitter.stats(at: targetURL).lineCount
            } else {
                rebuild = true
            }
        } else if !targetExists, recordedOffset > 0 || recordedBytes > 0 {
            rebuild = true
        }

        let tailResult: TailReadResult
        let finalStats: BackupFileStats
        let wroteData: Bool
        if rebuild {
            tailResult = try tailer.readNewCompleteLines(from: sourceURL, offset: 0)
            finalStats = try fileCommitter.rebuildCompleteLines(
                lines: tailResult.lines,
                at: targetURL,
                under: paths.backupRoot
            )
            wroteData = true
        } else {
            tailResult = try tailer.readNewCompleteLines(from: sourceURL, offset: readOffset)
            if !targetExists {
                finalStats = try fileCommitter.commitInitial(
                    lines: tailResult.lines,
                    to: targetURL,
                    under: paths.backupRoot
                )
            } else {
                finalStats = try fileCommitter.appendAndSynchronize(
                    lines: tailResult.lines,
                    to: targetURL,
                    under: paths.backupRoot
                )
            }
            wroteData = !tailResult.lines.isEmpty || targetState.byteCount != recordedBytes
        }

        let finalOffset = tailResult.nextOffset
        let contentHash = finalOffset > 0
            ? try fileCommitter.hashPrefix(of: sourceURL, byteCount: finalOffset)
            : nil
        let title = existingRecord?.title
            ?? firstTitle(in: tailResult.lines)
            ?? firstTitle(inBackupFileAt: targetURL)
        let firstSeenAt = existingRecord?.firstSeenAt ?? scanDate
        let lastBackedUpAt = wroteData || existingRecord?.lastBackedUpAt == nil && finalStats.lineCount > 0
            ? scanDate
            : existingRecord?.lastBackedUpAt
        let updatedRecord = BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            title: title,
            firstSeenAt: firstSeenAt,
            lastBackedUpAt: lastBackedUpAt,
            lineCount: rebuild || !targetExists
                ? finalStats.lineCount
                : max(baseLineCount + tailResult.lines.count, baseLineCount),
            bytesBackedUp: finalStats.byteCount,
            status: Self.activeStatus,
            contentHash: contentHash
        )
        let manifestChanged = existingRecord != updatedRecord
        if manifestChanged {
            manifest.sessions[sessionID] = updatedRecord
        }
        let updatedCursor = BackupCursor(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            lastByteOffset: finalOffset,
            lastSourceSize: sourceMetadata.byteCount,
            lastSourceModifiedAt: sourceMetadata.modifiedAt,
            lineCount: updatedRecord.lineCount,
            pendingPartialLine: tailResult.pendingPartialLine,
            status: Self.activeStatus,
            lastError: tailResult.blockedError,
            updatedAt: scanDate.timeIntervalSince1970
        )
        return ProcessSessionFileResult(
            manifestChanged: manifestChanged,
            cursor: cursorNeedsUpsert(currentCursor: currentCursor, updatedCursor: updatedCursor) ? updatedCursor : nil,
            lastError: tailResult.blockedError
        )
    }

    private func migratedCursor(
        for existingRecord: BackupSessionRecord?,
        currentSourcePath: String,
        cursorStore: BackupCursorStore
    ) throws -> BackupCursor? {
        guard let previousSourcePath = existingRecord?.sourcePath,
              previousSourcePath != currentSourcePath else {
            return nil
        }
        return try cursorStore.cursor(sourcePath: previousSourcePath)
    }

    private func ensureLocalStateDirectoriesExist() throws {
        try fileManager.createDirectory(at: paths.stateRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func discoverSessionFiles() throws -> [URL] {
        let roots = [
            (url: paths.codexRoot.appendingPathComponent("sessions", isDirectory: true), priority: 0),
            (url: paths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true), priority: 1)
        ]
        var discovered: [(url: URL, priority: Int)] = []
        for root in roots where fileManager.fileExists(atPath: root.url.path) {
            guard let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                discovered.append((url: fileURL, priority: root.priority))
            }
        }
        return discovered.sorted {
            $0.priority == $1.priority ? $0.url.path < $1.url.path : $0.priority < $1.priority
        }.map(\.url)
    }

    private func metadata(for sourceURL: URL) throws -> (size: Int64, modifiedAt: TimeInterval) {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        return (
            (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }

    private func firstTitle(in lines: [Data]) -> String? {
        for line in lines {
            guard let text = String(data: line, encoding: .utf8),
                  let title = SessionIdentity.title(fromJSONLine: text) else { continue }
            return title
        }
        return nil
    }

    private func firstTitle(inBackupFileAt backupURL: URL) -> String? {
        guard fileManager.fileExists(atPath: backupURL.path),
              let handle = try? FileHandle(forReadingFrom: backupURL) else { return nil }
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    if let text = String(data: pending, encoding: .utf8),
                       let title = SessionIdentity.title(fromJSONLine: text) {
                        return title
                    }
                    pending.removeAll(keepingCapacity: true)
                } else {
                    pending.append(byte)
                }
            }
        }
        return nil
    }

    private func cursorNeedsUpsert(currentCursor: BackupCursor?, updatedCursor: BackupCursor) -> Bool {
        guard let currentCursor else { return true }
        return currentCursor.sessionId != updatedCursor.sessionId
            || currentCursor.sourcePath != updatedCursor.sourcePath
            || currentCursor.backupPath != updatedCursor.backupPath
            || currentCursor.lastByteOffset != updatedCursor.lastByteOffset
            || currentCursor.lastSourceSize != updatedCursor.lastSourceSize
            || currentCursor.lastSourceModifiedAt != updatedCursor.lastSourceModifiedAt
            || currentCursor.lineCount != updatedCursor.lineCount
            || currentCursor.pendingPartialLine != updatedCursor.pendingPartialLine
            || currentCursor.status != updatedCursor.status
            || currentCursor.lastError != updatedCursor.lastError
    }

    private func writeStatus(
        for manifest: BackupManifest,
        status: BackupHealthStatus,
        lastError: String?,
        at date: Date,
        includeRemote: Bool
    ) throws {
        let existingStatus = try? loadLocalStatus()
        let records = Array(manifest.sessions.values)
        let snapshot = BackupStatus(
            agentVersion: Self.agentVersion,
            enabled: true,
            status: status,
            mode: .polling,
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            firstRunAt: existingStatus?.firstRunAt ?? date,
            lastStartedAt: startedAt(existingStatus: existingStatus, fallback: date),
            lastHeartbeatAt: date,
            lastBackupAt: records.compactMap(\.lastBackedUpAt).max(),
            sessionCount: records.count,
            lineCount: records.reduce(0) { $0 + $1.lineCount },
            bytesBackedUp: records.reduce(Int64(0)) { $0 + $1.bytesBackedUp },
            autoStartEnabled: false,
            lastError: lastError
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        if includeRemote {
            try remoteStatusWriter(data, paths.remoteStatusURL)
        }
        try DurableAtomicWriter().write(data, to: paths.localStatusURL, createParentDirectories: true)
    }

    private func writeErrorStatus(_ error: Error) throws {
        try ensureLocalStateDirectoriesExist()
        let manifest: BackupManifest
        if fileManager.fileExists(atPath: paths.manifestURL.path),
           let loaded = try? BackupManifestStore(
               manifestURL: paths.manifestURL,
               createParentDirectories: false
           ).loadOrCreate(codexRoot: paths.codexRoot.path, backupRoot: paths.backupRoot.path, now: now()) {
            manifest = loaded
        } else {
            manifest = BackupManifest(
                codexRoot: paths.codexRoot.path,
                backupRoot: paths.backupRoot.path,
                createdAt: now(),
                updatedAt: now()
            )
        }
        _ = try? pendingSessionCount()
        try writeStatus(
            for: manifest,
            status: .error,
            lastError: error.localizedDescription,
            at: now(),
            includeRemote: false
        )
    }

    private func loadLocalStatus() throws -> BackupStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupStatus.self, from: Data(contentsOf: paths.localStatusURL))
    }

    private func writePendingSources(_ records: [PendingSourceRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try DurableAtomicWriter().write(data, to: paths.pendingSourcesURL, createParentDirectories: true)
    }

    private func loadPendingSources() throws -> [PendingSourceRecord] {
        guard fileManager.fileExists(atPath: paths.pendingSourcesURL.path) else { return [] }
        return try JSONDecoder().decode(
            [PendingSourceRecord].self,
            from: Data(contentsOf: paths.pendingSourcesURL)
        )
    }

    private func startedAt(existingStatus: BackupStatus?, fallback: Date) -> Date {
        taskLock.lock()
        let value = pollingStartedAt
        taskLock.unlock()
        return value ?? existingStatus?.lastStartedAt ?? fallback
    }

    private static func nanoseconds(fromSeconds seconds: UInt64) -> UInt64 {
        let multiplier: UInt64 = 1_000_000_000
        guard seconds <= UInt64.max / multiplier else { return UInt64.max }
        return seconds * multiplier
    }
}

private struct PendingSourceRecord: Codable {
    let sourcePath: String
    let sourceSize: Int64
    let sourceModifiedAt: TimeInterval
    let committedOffset: Int64
    let unrecoverable: Bool?
}

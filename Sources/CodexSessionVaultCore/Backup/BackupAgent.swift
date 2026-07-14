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

struct BackupAgentInstrumentation {
    let sourceBodyRead: (URL, Int64, Int64) -> Void
    let targetStat: (URL) -> Void
    let fullHash: (URL, Int64) -> Void
    let auditInterruptionSet: () -> Void

    init(
        sourceBodyRead: @escaping (URL, Int64, Int64) -> Void = { _, _, _ in },
        targetStat: @escaping (URL) -> Void = { _ in },
        fullHash: @escaping (URL, Int64) -> Void = { _, _ in },
        auditInterruptionSet: @escaping () -> Void = {}
    ) {
        self.sourceBodyRead = sourceBodyRead
        self.targetStat = targetStat
        self.fullHash = fullHash
        self.auditInterruptionSet = auditInterruptionSet
    }
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
    private let sessionBackupStreamer: SessionBackupStreamer
    private let progressHandler: ((BackupProgress) -> Void)?
    private let remoteStatusWriter: (Data, URL) throws -> Void
    private let cursorStoreFactory: (URL) -> BackupCursorStore
    private let manifestStoreFactory: (URL) -> BackupManifestStore
    private let instrumentation: BackupAgentInstrumentation
    private let integrityAuditorFactory: (BackupPaths) -> BackupIntegrityAuditor
    private let scanLock = NSLock()
    private let auditInterruptionLock = NSLock()
    private let taskLock = NSLock()
    private var pollingTask: Task<Void, Never>?
    private var pollingStartedAt: Date?
    private var lastKnownProgress: BackupProgress?
    private var auditInterruptionRequested = false

    private struct ProcessSessionFileResult {
        var manifestChanged: Bool
        var cursor: BackupCursor?
        var lastError: String?
    }

    public convenience init(
        paths: BackupPaths = BackupPaths(),
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        tailer: SessionTailer = SessionTailer(),
        targetValidator: BackupTargetValidator? = nil,
        fileCommitter: BackupFileCommitter = BackupFileCommitter(),
        progressHandler: ((BackupProgress) -> Void)? = nil,
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.init(
            paths: paths,
            now: now,
            fileManager: fileManager,
            tailer: tailer,
            targetValidator: targetValidator,
            fileCommitter: fileCommitter,
            progressHandler: progressHandler,
            remoteStatusWriter: remoteStatusWriter,
            sessionBackupStreamer: SessionBackupStreamer(),
            cursorStoreFactory: { BackupCursorStore(databaseURL: $0) },
            manifestStoreFactory: {
                BackupManifestStore(manifestURL: $0, createParentDirectories: false)
            },
            instrumentation: BackupAgentInstrumentation(),
            integrityAuditorFactory: { BackupIntegrityAuditor(paths: $0) }
        )
    }

    init(
        paths: BackupPaths,
        now: @escaping () -> Date,
        fileManager: FileManager = .default,
        tailer: SessionTailer = SessionTailer(),
        targetValidator: BackupTargetValidator? = nil,
        fileCommitter: BackupFileCommitter = BackupFileCommitter(),
        progressHandler: ((BackupProgress) -> Void)? = nil,
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil,
        sessionBackupStreamer: SessionBackupStreamer,
        cursorStoreFactory: @escaping (URL) -> BackupCursorStore,
        manifestStoreFactory: @escaping (URL) -> BackupManifestStore,
        instrumentation: BackupAgentInstrumentation,
        integrityAuditorFactory: @escaping (BackupPaths) -> BackupIntegrityAuditor = {
            BackupIntegrityAuditor(paths: $0)
        }
    ) {
        self.paths = paths
        self.now = now
        self.fileManager = fileManager
        self.tailer = tailer
        self.targetValidator = targetValidator ?? BackupTargetValidator(backupRoot: paths.backupRoot)
        self.fileCommitter = fileCommitter
        self.sessionBackupStreamer = sessionBackupStreamer
        self.progressHandler = progressHandler
        self.cursorStoreFactory = cursorStoreFactory
        self.manifestStoreFactory = manifestStoreFactory
        self.instrumentation = instrumentation
        self.integrityAuditorFactory = integrityAuditorFactory
        self.remoteStatusWriter = remoteStatusWriter ?? { data, url in
            try DurableAtomicWriter().write(data, to: url, createParentDirectories: false)
        }
    }

    deinit {
        stop()
    }

    public func performOneShotScan() throws {
        requestAuditInterruption()
        scanLock.lock()
        defer { scanLock.unlock() }
        clearAuditInterruption()
        do {
            try performOneShotScanLocked()
        } catch {
            try? writeErrorStatus(error)
            throw error
        }
    }

    public func performIntegrityAuditIfDue(deviceID: UUID) throws -> IntegrityAuditOutcome {
        scanLock.lock()
        defer { scanLock.unlock() }
        clearAuditInterruption()
        do {
            try performOneShotScanLocked()
            let cursorStore = cursorStoreFactory(paths.cursorDatabaseURL)
            try cursorStore.open()
            let cursors = try cursorStore.loadAll()
            return try integrityAuditorFactory(paths).runIfDue(
                now: now(),
                deviceID: deviceID,
                cursors: cursors,
                interruptionRequested: { [weak self] in
                    self?.isAuditInterruptionRequested() ?? true
                }
            )
        } catch {
            try? writeErrorStatus(error)
            throw error
        }
    }

    private func performOneShotScanLocked() throws {
        try targetValidator.validateTarget()
        try ensureLocalStateDirectoriesExist()
        let scanDate = now()
        let cursorStore = cursorStoreFactory(paths.cursorDatabaseURL)
        try cursorStore.open()
        let cursorMap = try cursorStore.loadAll()

        let manifestExisted = fileManager.fileExists(atPath: paths.manifestURL.path)
        let manifestStore = manifestStoreFactory(paths.manifestURL)
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
        lastKnownProgress = BackupProgress(
            totalFiles: sources.count,
            completedFiles: 0,
            pendingFiles: sources.count,
            phase: phase
        )
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
                cursorMap: cursorMap
            )
            manifestChanged = manifestChanged || result.manifestChanged
            if let cursor = result.cursor {
                updatedCursors.append(cursor)
            }
            if let lastError = result.lastError {
                scanErrors.append(lastError)
            }
            completed += 1
            let progress = BackupProgress(
                totalFiles: sources.count,
                completedFiles: completed,
                pendingFiles: max(0, sources.count - completed),
                phase: phase
            )
            lastKnownProgress = progress
            progressHandler?(progress)
        }

        if manifestChanged {
            manifest.updatedAt = scanDate
            try manifestStore.save(manifest)
        }
        if !updatedCursors.isEmpty {
            try cursorStore.upsertMany(updatedCursors)
        }
        if !manifestExisted, scanErrors.isEmpty {
            try integrityAuditorFactory(paths).recordInitialSeedCompleted(at: scanDate)
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
        let cursorStore = cursorStoreFactory(paths.cursorDatabaseURL)
        try cursorStore.open()
        let cursorMap = try cursorStore.loadAll()
        let existing = try loadPendingSources()
        var pendingByPath: [String: PendingSourceRecord] = [:]
        let sources = try discoverSessionFiles()
        let discoveredPaths = Set(sources.map(canonicalSourcePath))
        for source in sources {
            let metadata = try metadata(for: source)
            let sourcePath = canonicalSourcePath(source)
            let cursor = cursorMap[sourcePath] ?? cursorMap[source.path]
            if cursor == nil
                || cursor?.lastSourceSize != metadata.size
                || cursor?.lastSourceModifiedAt != metadata.modifiedAt {
                pendingByPath[sourcePath] = PendingSourceRecord(
                    sourcePath: sourcePath,
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
        cursorMap: [String: BackupCursor]
    ) throws -> ProcessSessionFileResult {
        let sourcePath = canonicalSourcePath(sourceURL)
        let existingRecord = manifest.sessions[sessionID]
        let currentCursor = cursorMap[sourcePath] ?? cursorMap[sourceURL.path]
        let baselineCursor = currentCursor ?? migratedCursor(
            for: existingRecord,
            currentSourcePath: sourcePath,
            cursorMap: cursorMap
        )
        let targetURL = try paths.backupFileURL(for: sourceURL)
        guard let relativeBackupPath = paths.relativeBackupPath(for: targetURL) else {
            throw BackupTargetValidationError.unsafeTarget(targetURL.path)
        }
        let sourceMetadata = try fileCommitter.inspectSource(sourceURL)
        if scanIsStrictlyUnchanged(
            sourcePath: sourcePath,
            relativeBackupPath: relativeBackupPath,
            sourceMetadata: sourceMetadata,
            record: existingRecord,
            cursor: currentCursor
        ) {
            return ProcessSessionFileResult(
                manifestChanged: false,
                cursor: nil,
                lastError: currentCursor?.lastError
            )
        }

        instrumentation.targetStat(targetURL)
        let targetState = try fileCommitter.inspectTarget(targetURL)
        let recordedOffset = baselineCursor?.lastByteOffset ?? 0
        let recordedLineCount = baselineCursor?.lineCount ?? existingRecord?.lineCount ?? 0
        let metadataAgrees = baselineCursor.map {
            sourceMetadata.byteCount > $0.lastSourceSize
                && sourceMetadata.byteCount >= $0.lastByteOffset
                && existingRecord?.bytesBackedUp == $0.lastByteOffset
                && existingRecord?.lineCount == $0.lineCount
        } ?? false
        let pathAgrees = baselineCursor?.backupPath == relativeBackupPath
            && existingRecord?.backupPath == relativeBackupPath
            && existingRecord?.sourcePath == sourcePath
        let rebuild = !targetState.exists
            || !metadataAgrees
            || !pathAgrees
            || targetState.byteCount != recordedOffset

        let finalStats: BackupFileStats
        let wroteData: Bool
        let finalOffset: Int64
        let pendingPartialLine: Data
        let blockedError: String?
        let contentHash: String?
        let appendedLineCount: Int
        let fallbackTitle: String?
        if rebuild {
            instrumentation.sourceBodyRead(sourceURL, 0, sourceMetadata.byteCount)
            let streamed = try fileCommitter.rebuildCompleteLines(
                from: sourceURL,
                at: targetURL,
                under: paths.backupRoot,
                using: sessionBackupStreamer
            )
            if !targetState.exists, streamed.committedByteCount == 0 {
                try? fileManager.removeItem(at: targetURL)
            }
            finalStats = BackupFileStats(
                byteCount: streamed.committedByteCount,
                lineCount: streamed.lineCount
            )
            wroteData = targetState.exists || streamed.committedByteCount > 0
            finalOffset = streamed.committedByteCount
            pendingPartialLine = streamed.pendingPartialLine
            blockedError = streamed.blockedError
            contentHash = streamed.contentHash
            appendedLineCount = 0
            fallbackTitle = streamed.firstTitle
        } else {
            instrumentation.sourceBodyRead(
                sourceURL,
                recordedOffset,
                sourceMetadata.byteCount - recordedOffset
            )
            let appended = try fileCommitter.appendCompleteLines(
                from: sourceURL,
                offset: recordedOffset,
                to: targetURL,
                under: paths.backupRoot,
                using: sessionBackupStreamer
            )
            finalStats = BackupFileStats(
                byteCount: appended.committedByteCount,
                lineCount: appended.lineCount
            )
            finalOffset = appended.committedByteCount
            pendingPartialLine = appended.pendingPartialLine
            blockedError = appended.blockedError
            appendedLineCount = appended.lineCount
            wroteData = appended.appendedByteCount > 0
            contentHash = appended.appendedByteCount > 0 ? nil : existingRecord?.contentHash
            fallbackTitle = appended.firstTitle

            if finalOffset > recordedOffset {
                let verifiedByteCount = finalOffset - recordedOffset
                instrumentation.sourceBodyRead(sourceURL, recordedOffset, verifiedByteCount)
                guard try sessionBackupStreamer.rangesMatch(
                    source: sourceURL,
                    sourceOffset: recordedOffset,
                    target: targetURL,
                    targetOffset: recordedOffset,
                    length: verifiedByteCount
                ) else {
                    throw BackupAgentScanError.rangeVerificationFailed(targetURL.path)
                }
            }
        }

        let title = existingRecord?.title
            ?? fallbackTitle
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
            lineCount: rebuild
                ? finalStats.lineCount
                : recordedLineCount + appendedLineCount,
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
            pendingPartialLine: pendingPartialLine,
            status: Self.activeStatus,
            lastError: blockedError,
            updatedAt: scanDate.timeIntervalSince1970
        )
        return ProcessSessionFileResult(
            manifestChanged: manifestChanged,
            cursor: cursorNeedsUpsert(currentCursor: currentCursor, updatedCursor: updatedCursor) ? updatedCursor : nil,
            lastError: blockedError
        )
    }

    private func migratedCursor(
        for existingRecord: BackupSessionRecord?,
        currentSourcePath: String,
        cursorMap: [String: BackupCursor]
    ) -> BackupCursor? {
        guard let previousSourcePath = existingRecord?.sourcePath,
              previousSourcePath != currentSourcePath else {
            return nil
        }
        return cursorMap[previousSourcePath]
    }

    private func scanIsStrictlyUnchanged(
        sourcePath: String,
        relativeBackupPath: String,
        sourceMetadata: BackupSourceMetadata,
        record: BackupSessionRecord?,
        cursor: BackupCursor?
    ) -> Bool {
        guard let record, let cursor,
              record.sourcePath == sourcePath,
              cursor.sourcePath == sourcePath,
              record.backupPath == relativeBackupPath,
              cursor.backupPath == relativeBackupPath,
              record.bytesBackedUp == cursor.lastByteOffset,
              record.lineCount == cursor.lineCount,
              cursor.lastByteOffset >= 0,
              cursor.lastByteOffset <= sourceMetadata.byteCount,
              cursor.lastSourceSize == sourceMetadata.byteCount,
              cursor.lastSourceModifiedAt == sourceMetadata.modifiedAt else {
            return false
        }

        let hasUncommittedBytes = sourceMetadata.byteCount > cursor.lastByteOffset
        if hasUncommittedBytes {
            return !cursor.pendingPartialLine.isEmpty || cursor.lastError != nil
        }
        return cursor.pendingPartialLine.isEmpty && cursor.lastError == nil
    }

    private func canonicalSourcePath(_ sourceURL: URL) -> String {
        sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
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
        let auditState = try? loadIntegrityAuditState()
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
            lastError: lastError,
            lastAuditAt: auditState?.lastCompletedAt ?? existingStatus?.lastAuditAt,
            lastAuditResult: auditState?.lastResult ?? existingStatus?.lastAuditResult,
            lastRepairAt: existingStatus?.lastRepairAt,
            repairCount: auditState?.repairedCount ?? existingStatus?.repairCount
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
           let loaded = try? manifestStoreFactory(paths.manifestURL).loadOrCreate(
               codexRoot: paths.codexRoot.path,
               backupRoot: paths.backupRoot.path,
               now: now()
           ) {
            manifest = loaded
        } else {
            manifest = BackupManifest(
                codexRoot: paths.codexRoot.path,
                backupRoot: paths.backupRoot.path,
                createdAt: now(),
                updatedAt: now()
            )
        }
        if let lastKnownProgress {
            progressHandler?(lastKnownProgress)
        }
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

    private func loadIntegrityAuditState() throws -> IntegrityAuditState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            IntegrityAuditState.self,
            from: Data(contentsOf: paths.auditStateURL)
        )
    }

    private func requestAuditInterruption() {
        auditInterruptionLock.lock()
        auditInterruptionRequested = true
        auditInterruptionLock.unlock()
        instrumentation.auditInterruptionSet()
    }

    private func clearAuditInterruption() {
        auditInterruptionLock.lock()
        auditInterruptionRequested = false
        auditInterruptionLock.unlock()
    }

    private func isAuditInterruptionRequested() -> Bool {
        auditInterruptionLock.lock()
        defer { auditInterruptionLock.unlock() }
        return auditInterruptionRequested
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

private enum BackupAgentScanError: LocalizedError {
    case rangeVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .rangeVerificationFailed(path):
            return "NAS append range verification failed: \(path)"
        }
    }
}

private struct PendingSourceRecord: Codable {
    let sourcePath: String
    let sourceSize: Int64
    let sourceModifiedAt: TimeInterval
    let committedOffset: Int64
    let unrecoverable: Bool?
}

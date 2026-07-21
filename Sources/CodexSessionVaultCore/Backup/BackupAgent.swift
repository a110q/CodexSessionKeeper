import Foundation

public final class BackupAgent: @unchecked Sendable {
    private static let agentVersion = "1.0.0"
    private static let activeStatus = "active"
    private static let newlineByte: UInt8 = 0x0A
    private static let newline = Data([0x0A])

    private let paths: BackupPaths
    private let now: () -> Date
    private let fileManager: FileManager
    private let tailer: SessionTailer
    private let scanLock = NSLock()
    private let taskLock = NSLock()
    private var pollingTask: Task<Void, Never>?
    private var pollingStartedAt: Date?

    private final class DrainGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func finish(_ value: Bool) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = value
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    private struct ProcessSessionFileResult {
        var manifestChanged: Bool
        var lastError: String?
    }

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
        scanLock.lock()
        defer { scanLock.unlock() }

        try performOneShotScanLocked()
    }

    private func performOneShotScanLocked() throws {
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

        var processedSessionIDs = Set<String>()
        var scanErrors: [String] = []
        for sourceURL in try discoverSessionFiles() {
            guard let sessionID = SessionIdentity.sessionID(from: sourceURL) else {
                continue
            }
            guard processedSessionIDs.insert(sessionID).inserted else {
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
            if let lastError = result.lastError {
                scanErrors.append(lastError)
            }
        }

        if manifestChanged {
            manifest.updatedAt = scanDate
            try manifestStore.save(manifest)
        }

        let lastError = scanErrors.first
        try writeStatus(
            for: manifest,
            status: lastError == nil ? .running : .error,
            lastError: lastError,
            at: scanDate
        )
    }

    public func startPolling(intervalSeconds: UInt64 = 10) {
        taskLock.lock()
        defer { taskLock.unlock() }

        guard pollingTask == nil else {
            return
        }

        pollingStartedAt = now()
        let sleepNanoseconds = Self.nanoseconds(fromSeconds: intervalSeconds)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let agent = self else {
                        return
                    }
                    guard !Task.isCancelled else {
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

    public func stopAndDrain(timeout: Duration = .seconds(5)) async -> Bool {
        stop()
        let gate = DrainGate()
        DispatchQueue.global(qos: .utility).async { [scanLock] in
            scanLock.lock()
            scanLock.unlock()
            gate.finish(true)
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                gate.finish(false)
            } catch {
                return
            }
        }
        let result = await gate.wait()
        timeoutTask.cancel()
        return result
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
            (
                url: paths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
                priority: 0
            ),
            (
                url: paths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
                priority: 1
            )
        ]
        var discovered: [(url: URL, priority: Int)] = []

        for root in roots where fileManager.fileExists(atPath: root.url.path) {
            guard let enumerator = fileManager.enumerator(
                at: root.url,
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

                discovered.append((url: fileURL, priority: root.priority))
            }
        }

        return discovered.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }

            return lhs.url.path < rhs.url.path
        }.map(\.url)
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
        let firstSeenAt = existingRecord?.firstSeenAt ?? scanDate
        let backupURL = try backupFileURL(
            for: sessionID,
            firstSeenAt: firstSeenAt,
            existingRecord: existingRecord,
            baselineCursor: baselineCursor
        )
        let relativeBackupPath = try validatedRelativeBackupPath(for: backupURL)
        let readOffset = baselineCursor?.lastByteOffset ?? 0
        let lineCountBeforeReadOffset = readOffset > 0 ? (baselineCursor?.lineCount ?? 0) : 0
        let tailResult = try tailer.readNewCompleteLines(from: sourceURL, offset: readOffset)
        let sourceMetadata = try metadata(for: sourceURL)
        let recordedLineCount = max(existingRecord?.lineCount ?? 0, baselineCursor?.lineCount ?? 0)
        let recordedBytesBackedUp = existingRecord?.bytesBackedUp ?? 0
        let sourcePathMigrated = existingRecord.map { $0.sourcePath != sourcePath } ?? false
        let needsBackupStats = shouldReadBackupFileStats(
            existingRecord: existingRecord,
            baselineCursor: baselineCursor,
            sourcePathMigrated: sourcePathMigrated,
            hasNewCompleteLines: !tailResult.lines.isEmpty
        )
        let backupStatsBeforeAppend = needsBackupStats
            ? try backupFileStats(at: backupURL)
            : BackupFileStats(byteCount: recordedBytesBackedUp, lineCount: recordedLineCount)
        let skippedAlreadyBackedUpLineCount = min(
            tailResult.lines.count,
            max(0, backupStatsBeforeAppend.lineCount - lineCountBeforeReadOffset)
        )
        let linesToAppend = Array(tailResult.lines.dropFirst(skippedAlreadyBackedUpLineCount))
        let appendedLineStats = lineStats(for: linesToAppend)

        if !linesToAppend.isEmpty {
            _ = try append(lines: linesToAppend, to: backupURL)
        }
        let backupStatsAfterAppend = BackupFileStats(
            byteCount: backupStatsBeforeAppend.byteCount + appendedLineStats.byteCount,
            lineCount: backupStatsBeforeAppend.lineCount + appendedLineStats.lineCount
        )

        let consumedCompleteLineCount = lineCountBeforeReadOffset + tailResult.lines.count
        let totalLineCount = max(
            recordedLineCount,
            consumedCompleteLineCount,
            backupStatsAfterAppend.lineCount
        )
        let totalBytesBackedUp = max(recordedBytesBackedUp, backupStatsAfterAppend.byteCount)
        let titleFromNewLines = firstTitle(in: tailResult.lines)
        let title = existingRecord?.title ?? titleFromNewLines ?? backupTitleIfAlreadyInspectingFile(
            at: backupURL,
            needsBackupStats: needsBackupStats
        )
        let lastBackedUpAt = resolvedLastBackedUpAt(
            existingRecord: existingRecord,
            appendedLineCount: linesToAppend.count,
            totalLineCount: totalLineCount,
            totalBytesBackedUp: totalBytesBackedUp,
            scanDate: scanDate
        )
        let updatedRecord = BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            title: title,
            firstSeenAt: firstSeenAt,
            lastBackedUpAt: lastBackedUpAt,
            lineCount: totalLineCount,
            bytesBackedUp: totalBytesBackedUp,
            status: Self.activeStatus
        )

        let manifestChanged = existingRecord != updatedRecord
        if manifestChanged {
            manifest.sessions[sessionID] = updatedRecord
        }

        let updatedCursor = BackupCursor(
            sessionId: sessionID,
            sourcePath: sourcePath,
            backupPath: relativeBackupPath,
            lastByteOffset: tailResult.nextOffset,
            lastSourceSize: sourceMetadata.size,
            lastSourceModifiedAt: sourceMetadata.modifiedAt,
            lineCount: totalLineCount,
            pendingPartialLine: tailResult.pendingPartialLine,
            status: Self.activeStatus,
            lastError: tailResult.blockedError,
            updatedAt: scanDate.timeIntervalSince1970
        )
        if cursorNeedsUpsert(currentCursor: currentCursor, updatedCursor: updatedCursor) {
            try cursorStore.upsert(updatedCursor)
        }

        return ProcessSessionFileResult(
            manifestChanged: manifestChanged,
            lastError: tailResult.blockedError
        )
    }

    private func migratedCursor(
        for existingRecord: BackupSessionRecord?,
        currentSourcePath: String,
        cursorStore: BackupCursorStore
    ) throws -> BackupCursor? {
        guard let previousSourcePath = existingRecord?.sourcePath,
              previousSourcePath != currentSourcePath
        else {
            return nil
        }

        return try cursorStore.cursor(sourcePath: previousSourcePath)
    }

    private func shouldReadBackupFileStats(
        existingRecord: BackupSessionRecord?,
        baselineCursor: BackupCursor?,
        sourcePathMigrated: Bool,
        hasNewCompleteLines: Bool
    ) -> Bool {
        if hasNewCompleteLines {
            return true
        }

        guard let existingRecord else {
            return baselineCursor != nil
        }

        let baselineLineCount = baselineCursor?.lineCount
        let recordedLineCount = max(existingRecord.lineCount, baselineLineCount ?? 0)
        if sourcePathMigrated {
            guard let baselineCursor else {
                return true
            }
            if baselineCursor.lineCount != existingRecord.lineCount {
                return true
            }
        } else if let baselineLineCount, baselineLineCount != existingRecord.lineCount {
            return true
        }

        return recordedLineCount > 0 && existingRecord.bytesBackedUp == 0
    }

    private func resolvedLastBackedUpAt(
        existingRecord: BackupSessionRecord?,
        appendedLineCount: Int,
        totalLineCount: Int,
        totalBytesBackedUp: Int64,
        scanDate: Date
    ) -> Date? {
        if appendedLineCount > 0 {
            return scanDate
        }

        if existingRecord?.lastBackedUpAt == nil,
           totalLineCount > 0 || totalBytesBackedUp > 0 {
            return scanDate
        }

        return existingRecord?.lastBackedUpAt
    }

    private func backupFileURL(
        for sessionID: String,
        firstSeenAt: Date,
        existingRecord: BackupSessionRecord?,
        baselineCursor: BackupCursor?
    ) throws -> URL {
        if let backupPath = existingRecord?.backupPath ?? baselineCursor?.backupPath {
            return backupFileURL(forStoredBackupPath: backupPath)
        }

        return paths.backupFileURL(sessionID: sessionID, firstSeenAt: firstSeenAt)
    }

    private func backupFileURL(forStoredBackupPath backupPath: String) -> URL {
        if backupPath.hasPrefix("/") {
            return URL(fileURLWithPath: backupPath)
        }

        return paths.backupRoot.appendingPathComponent(backupPath)
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

    private func backupTitleIfAlreadyInspectingFile(at backupURL: URL, needsBackupStats: Bool) -> String? {
        guard needsBackupStats else {
            return nil
        }

        return firstTitle(inBackupFileAt: backupURL)
    }

    private func firstTitle(inBackupFileAt backupURL: URL) -> String? {
        guard fileManager.fileExists(atPath: backupURL.path),
              let handle = try? FileHandle(forReadingFrom: backupURL)
        else {
            return nil
        }
        defer { try? handle.close() }

        var pendingLine = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for byte in chunk {
                if byte == Self.newlineByte {
                    if let text = String(data: pendingLine, encoding: .utf8),
                       let title = SessionIdentity.title(fromJSONLine: text) {
                        return title
                    }
                    pendingLine.removeAll(keepingCapacity: true)
                } else {
                    pendingLine.append(byte)
                }
            }
        }

        return nil
    }

    private func lineStats(for lines: [Data]) -> BackupFileStats {
        BackupFileStats(
            byteCount: lines.reduce(Int64(0)) { total, line in
                total + Int64(line.count + Self.newline.count)
            },
            lineCount: lines.count
        )
    }

    private func metadata(for sourceURL: URL) throws -> (size: Int64, modifiedAt: TimeInterval) {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modifiedAt)
    }

    private func cursorNeedsUpsert(currentCursor: BackupCursor?, updatedCursor: BackupCursor) -> Bool {
        guard let currentCursor else {
            return true
        }

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

    private func backupFileStats(at backupURL: URL) throws -> BackupFileStats {
        guard fileManager.fileExists(atPath: backupURL.path) else {
            return BackupFileStats(byteCount: 0, lineCount: 0)
        }

        let attributes = try fileManager.attributesOfItem(atPath: backupURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: backupURL)
        defer { try? handle.close() }

        var lineCount = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            lineCount += chunk.reduce(0) { count, byte in
                count + (byte == Self.newlineByte ? 1 : 0)
            }
        }

        return BackupFileStats(byteCount: byteCount, lineCount: lineCount)
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
            lastStartedAt: lastStartedAtForStatus(existingStatus: existingStatus, fallback: date),
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

    private func lastStartedAtForStatus(existingStatus: BackupStatus?, fallback: Date) -> Date {
        taskLock.lock()
        let startedAt = pollingStartedAt
        taskLock.unlock()

        return startedAt ?? existingStatus?.lastStartedAt ?? fallback
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

private struct BackupFileStats: Sendable {
    var byteCount: Int64
    var lineCount: Int
}

extension BackupAgentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .backupPathOutsideRoot(path, backupRoot):
            "Backup path is outside backup root: \(path) is not contained in \(backupRoot)."
        }
    }
}

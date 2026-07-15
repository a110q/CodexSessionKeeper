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
    let auditWillStart: @Sendable () -> Void
    let auditDidFinish: @Sendable (IntegrityAuditOutcome) -> Void

    init(
        sourceBodyRead: @escaping (URL, Int64, Int64) -> Void = { _, _, _ in },
        targetStat: @escaping (URL) -> Void = { _ in },
        fullHash: @escaping (URL, Int64) -> Void = { _, _ in },
        auditInterruptionSet: @escaping () -> Void = {},
        auditWillStart: @escaping @Sendable () -> Void = {},
        auditDidFinish: @escaping @Sendable (IntegrityAuditOutcome) -> Void = { _ in }
    ) {
        self.sourceBodyRead = sourceBodyRead
        self.targetStat = targetStat
        self.fullHash = fullHash
        self.auditInterruptionSet = auditInterruptionSet
        self.auditWillStart = auditWillStart
        self.auditDidFinish = auditDidFinish
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
    private let deviceID: UUID?
    private let fileCommitter: BackupFileCommitter
    private let sessionBackupStreamer: SessionBackupStreamer
    private let progressHandler: ((BackupProgress) -> Void)?
    private let statusHandler: (@Sendable (BackupStatus) -> Void)?
    private let remoteStatusWriter: (Data, URL) throws -> Void
    private let cursorStoreFactory: (URL) -> BackupCursorStore
    private let manifestStoreFactory: (URL) -> BackupManifestStore
    private let instrumentation: BackupAgentInstrumentation
    private let integrityAuditorFactory: (BackupPaths) -> BackupIntegrityAuditor
    private let auditDelayProvider: @Sendable (Date, Date?, UUID) -> TimeInterval
    private let auditTimerScheduler: @Sendable (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> Task<Void, Never>
    private let scanLock = NSLock()
    private let stateLock = NSCondition()
    private var pollingTask: Task<Void, Never>?
    private var auditTimerTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var pollingStartedAt: Date?
    private var lastKnownProgress: BackupProgress?
    private var cachedStatus: BackupStatus?
    private var auditInterruptionEpoch: UInt64 = 0
    private var auditTimerGeneration: UInt64 = 0
    private var workerActive = false
    private var isScanning = false
    private var isAuditing = false
    private var rescanQueued = false
    private var pendingAuditBaselineEpoch: UInt64?
    private var stopped = false

    private enum BackgroundWork {
        case scan(BackupScanTrigger)
        case audit(baselineEpoch: UInt64)
    }

    private struct ProcessSessionFileResult {
        var manifestChanged: Bool
        var cursor: BackupCursor?
        var staleCursorSourcePath: String?
        var lastError: String?
    }

    public convenience init(
        paths: BackupPaths = BackupPaths(),
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        tailer: SessionTailer = SessionTailer(),
        targetValidator: BackupTargetValidator? = nil,
        deviceID: UUID? = nil,
        initialStatus: BackupStatus? = nil,
        fileCommitter: BackupFileCommitter = BackupFileCommitter(),
        progressHandler: ((BackupProgress) -> Void)? = nil,
        statusHandler: (@Sendable (BackupStatus) -> Void)? = nil,
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.init(
            paths: paths,
            now: now,
            fileManager: fileManager,
            tailer: tailer,
            targetValidator: targetValidator,
            deviceID: deviceID,
            initialStatus: initialStatus,
            fileCommitter: fileCommitter,
            progressHandler: progressHandler,
            statusHandler: statusHandler,
            remoteStatusWriter: remoteStatusWriter,
            auditDelayProvider: nil,
            auditTimerScheduler: nil,
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
        deviceID: UUID? = nil,
        initialStatus: BackupStatus? = nil,
        fileCommitter: BackupFileCommitter = BackupFileCommitter(),
        progressHandler: ((BackupProgress) -> Void)? = nil,
        statusHandler: (@Sendable (BackupStatus) -> Void)? = nil,
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil,
        auditDelayProvider: (@Sendable (Date, Date?, UUID) -> TimeInterval)? = nil,
        auditTimerScheduler: (@Sendable (
            TimeInterval,
            @escaping @Sendable () -> Void
        ) -> Task<Void, Never>)? = nil,
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
        self.deviceID = deviceID
        self.fileCommitter = fileCommitter
        self.sessionBackupStreamer = sessionBackupStreamer
        self.progressHandler = progressHandler
        self.statusHandler = statusHandler
        self.cursorStoreFactory = cursorStoreFactory
        self.manifestStoreFactory = manifestStoreFactory
        self.instrumentation = instrumentation
        self.integrityAuditorFactory = integrityAuditorFactory
        self.auditDelayProvider = auditDelayProvider ?? { now, lastAuditAt, deviceID in
            Self.auditDelay(now: now, lastAuditAt: lastAuditAt, deviceID: deviceID)
        }
        self.auditTimerScheduler = auditTimerScheduler ?? { delay, action in
            Task.detached(priority: .background) {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(fromTimeInterval: delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
        }
        self.cachedStatus = initialStatus ?? Self.loadPersistedStatus(at: paths.localStatusURL)
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
        do {
            try performOneShotScanLocked()
        } catch {
            try? writeErrorStatus(error)
            throw error
        }
    }

    public func performIntegrityAuditIfDue(deviceID: UUID) throws -> IntegrityAuditOutcome {
        try performIntegrityAuditIfDue(
            deviceID: deviceID,
            baselineEpoch: currentAuditInterruptionEpoch()
        )
    }

    private func performIntegrityAuditIfDue(
        deviceID: UUID,
        baselineEpoch: UInt64
    ) throws -> IntegrityAuditOutcome {
        scanLock.lock()
        defer { scanLock.unlock() }
        guard !auditWasInterrupted(since: baselineEpoch) else { return .interrupted }
        do {
            try performOneShotScanLocked()
            guard !auditWasInterrupted(since: baselineEpoch) else { return .interrupted }
            let cursorStore = cursorStoreFactory(paths.cursorDatabaseURL)
            try cursorStore.open()
            let cursors = try cursorStore.loadAll()
            let outcome = try integrityAuditorFactory(paths).runIfDue(
                now: now(),
                deviceID: deviceID,
                cursors: cursors,
                interruptionRequested: { [weak self] in
                    self?.auditWasInterrupted(since: baselineEpoch) ?? true
                }
            )
            if outcome != .interrupted {
                publishPersistedStatusIfAvailable()
            }
            return outcome
        } catch {
            try? writeErrorStatus(error)
            throw error
        }
    }

    private func performOneShotScanLocked() throws {
        try targetValidator.validateTarget()
        try ensureLocalStateDirectoriesExist()
        let scanDate = now()
        let pendingRepairURL = paths.stateRoot.appendingPathComponent(
            "integrity-repair-pending.json",
            isDirectory: false
        )
        let recoveringPendingRepair = fileManager.fileExists(atPath: pendingRepairURL.path)
        try integrityAuditorFactory(paths).recoverPendingRepairIfNeeded(now: scanDate)
        if recoveringPendingRepair {
            publishPersistedStatusIfAvailable()
        }
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
        var staleCursorSourcePaths: [String] = []
        var scanErrors: [String] = []
        var completed = 0
        var interrupted = false
        var remainingSources: [URL] = []
        lastKnownProgress = BackupProgress(
            totalFiles: sources.count,
            completedFiles: 0,
            pendingFiles: sources.count,
            phase: phase
        )
        for (sourceIndex, sourceURL) in sources.enumerated() {
            if shouldStopBetweenSessionAtomicSteps() {
                interrupted = true
                remainingSources = Array(sources[sourceIndex...]).filter { source in
                    guard let sessionID = SessionIdentity.sessionID(from: source) else { return false }
                    return !processedSessionIDs.contains(sessionID)
                }
                break
            }
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
            if let staleCursorSourcePath = result.staleCursorSourcePath {
                staleCursorSourcePaths.append(staleCursorSourcePath)
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
        if !updatedCursors.isEmpty || !staleCursorSourcePaths.isEmpty {
            try cursorStore.upsertMany(
                updatedCursors,
                deletingSourcePaths: staleCursorSourcePaths
            )
        }
        if interrupted {
            let pending = try interruptedPendingSources(
                remainingSources: remainingSources,
                allDiscoveredSources: sources,
                cursorMap: cursorMap
            )
            try writePendingSources(pending)
            try writeStatus(
                for: manifest,
                status: .waiting,
                lastError: nil,
                at: scanDate,
                includeRemote: true
            )
            return
        }
        if scanErrors.isEmpty {
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

    private func interruptedPendingSources(
        remainingSources: [URL],
        allDiscoveredSources: [URL],
        cursorMap: [String: BackupCursor]
    ) throws -> [PendingSourceRecord] {
        let discoveredPaths = Set(allDiscoveredSources.map(canonicalSourcePath))
        var pendingByPath: [String: PendingSourceRecord] = [:]
        for record in try loadPendingSources() where !discoveredPaths.contains(record.sourcePath) {
            pendingByPath[record.sourcePath] = PendingSourceRecord(
                sourcePath: record.sourcePath,
                sourceSize: record.sourceSize,
                sourceModifiedAt: record.sourceModifiedAt,
                committedOffset: record.committedOffset,
                unrecoverable: true
            )
        }
        for source in remainingSources {
            let sourcePath = canonicalSourcePath(source)
            let sourceMetadata = try metadata(for: source)
            let cursor = cursorMap[sourcePath] ?? cursorMap[source.path]
            guard cursor == nil
                    || cursor?.lastSourceSize != sourceMetadata.size
                    || cursor?.lastSourceModifiedAt != sourceMetadata.modifiedAt else {
                continue
            }
            pendingByPath[sourcePath] = PendingSourceRecord(
                sourcePath: sourcePath,
                sourceSize: sourceMetadata.size,
                sourceModifiedAt: sourceMetadata.modifiedAt,
                committedOffset: cursor?.lastByteOffset ?? 0,
                unrecoverable: false
            )
        }
        return pendingByPath.values.sorted { $0.sourcePath < $1.sourcePath }
    }

    public func startPolling(intervalSeconds: UInt64 = 30) {
        let sleepNanoseconds = Self.nanoseconds(fromSeconds: intervalSeconds)
        stateLock.lock()
        guard !stopped, pollingTask == nil else {
            stateLock.unlock()
            return
        }
        pollingStartedAt = now()
        pollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.requestImmediateScan(.timer)
            }
        }
        stateLock.unlock()
    }

    public func requestImmediateScan(_ trigger: BackupScanTrigger) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        auditInterruptionEpoch &+= 1
        if workerActive {
            rescanQueued = true
        } else {
            startWorkerLocked(with: .scan(trigger))
        }
        stateLock.unlock()
        instrumentation.auditInterruptionSet()
        if trigger == .wake {
            scheduleAudit(replacingExisting: true)
        }
    }

    public func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        auditInterruptionEpoch &+= 1
        auditTimerGeneration &+= 1
        rescanQueued = false
        pendingAuditBaselineEpoch = nil
        let polling = pollingTask
        let auditTimer = auditTimerTask
        let worker = workerTask
        pollingTask = nil
        auditTimerTask = nil
        stateLock.unlock()
        instrumentation.auditInterruptionSet()
        polling?.cancel()
        auditTimer?.cancel()
        worker?.cancel()
    }

    public func stopAndAwaitQuiescence(timeout: TimeInterval) -> Bool {
        stop()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        stateLock.lock()
        defer { stateLock.unlock() }
        while workerActive {
            guard stateLock.wait(until: deadline) else { return false }
        }
        return true
    }

    private func startWorkerLocked(with initialWork: BackgroundWork) {
        workerActive = true
        workerTask = Task.detached(priority: .utility) { [weak self] in
            self?.drainBackgroundWork(startingWith: initialWork)
        }
    }

    private func drainBackgroundWork(startingWith initialWork: BackgroundWork) {
        var work = initialWork
        var scanCount = 0
        var auditCount = 0
        var rescheduleAuditAfterDrain = false
        while true {
            guard !backgroundWorkShouldStop() else {
                finishBackgroundWorker()
                return
            }

            var interruptedAudit = false
            switch work {
            case .scan:
                scanCount += 1
                setBackgroundPhase(scanning: true, auditing: false)
                try? performOneShotScan()
                setBackgroundPhase(scanning: false, auditing: false)
                ensureAuditScheduled()
            case let .audit(baselineEpoch):
                auditCount += 1
                setBackgroundPhase(scanning: false, auditing: true)
                instrumentation.auditWillStart()
                if let deviceID {
                    let outcome = try? performIntegrityAuditIfDue(
                        deviceID: deviceID,
                        baselineEpoch: baselineEpoch
                    )
                    if let outcome {
                        instrumentation.auditDidFinish(outcome)
                    }
                    interruptedAudit = outcome == .interrupted
                }
                setBackgroundPhase(scanning: false, auditing: false)
                if !interruptedAudit {
                    scheduleAudit(replacingExisting: true)
                } else {
                    rescheduleAuditAfterDrain = true
                }
            }

            stateLock.lock()
            if stopped {
                stateLock.unlock()
                finishBackgroundWorker()
                return
            }
            if rescanQueued {
                rescanQueued = false
                if scanCount < 2 {
                    work = .scan(.queued)
                    stateLock.unlock()
                    continue
                }
            }
            if let baselineEpoch = pendingAuditBaselineEpoch, auditCount == 0 {
                pendingAuditBaselineEpoch = nil
                work = .audit(baselineEpoch: baselineEpoch)
                stateLock.unlock()
                continue
            }
            if pendingAuditBaselineEpoch != nil {
                pendingAuditBaselineEpoch = nil
                rescheduleAuditAfterDrain = true
            }
            workerActive = false
            workerTask = nil
            stateLock.broadcast()
            stateLock.unlock()
            if rescheduleAuditAfterDrain {
                scheduleAudit(replacingExisting: true)
            }
            return
        }
    }

    private func backgroundWorkShouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped || Task.isCancelled
    }

    private func setBackgroundPhase(scanning: Bool, auditing: Bool) {
        stateLock.lock()
        isScanning = scanning
        isAuditing = auditing
        stateLock.unlock()
    }

    private func finishBackgroundWorker() {
        stateLock.lock()
        workerActive = false
        isScanning = false
        isAuditing = false
        workerTask = nil
        stateLock.broadcast()
        stateLock.unlock()
    }

    private func requestScheduledAudit(timerGeneration: UInt64) {
        stateLock.lock()
        guard timerGeneration == auditTimerGeneration else {
            stateLock.unlock()
            return
        }
        auditTimerTask = nil
        guard !stopped else {
            stateLock.unlock()
            return
        }
        let baselineEpoch = auditInterruptionEpoch
        if workerActive {
            pendingAuditBaselineEpoch = baselineEpoch
        } else {
            startWorkerLocked(with: .audit(baselineEpoch: baselineEpoch))
        }
        stateLock.unlock()
    }

    private func ensureAuditScheduled() {
        stateLock.lock()
        let shouldSchedule = !stopped
            && deviceID != nil
            && auditTimerTask == nil
            && pendingAuditBaselineEpoch == nil
            && !isAuditing
        stateLock.unlock()
        if shouldSchedule {
            scheduleAudit(replacingExisting: false)
        }
    }

    private func scheduleAudit(replacingExisting: Bool) {
        guard let deviceID else { return }
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        if !replacingExisting, auditTimerTask != nil {
            stateLock.unlock()
            return
        }
        let existingTask = auditTimerTask
        auditTimerTask = nil
        auditTimerGeneration &+= 1
        let timerGeneration = auditTimerGeneration
        let currentDate = now()
        let delay = auditDelayProvider(currentDate, cachedStatus?.lastAuditAt, deviceID)
        auditTimerTask = auditTimerScheduler(delay) { [weak self] in
            self?.requestScheduledAudit(timerGeneration: timerGeneration)
        }
        stateLock.unlock()
        existingTask?.cancel()
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
        let migratedCursor = migratedCursor(
            for: existingRecord,
            currentSourcePath: sourcePath,
            cursorMap: cursorMap
        )
        let baselineCursor = currentCursor ?? migratedCursor
        let mirroredTargetURL = try paths.backupFileURL(for: sourceURL)
        let targetURL = trustedRecordedBackupURL(
            existingRecord?.backupPath ?? baselineCursor?.backupPath
        ) ?? mirroredTargetURL
        guard let relativeBackupPath = paths.relativeBackupPath(for: targetURL) else {
            throw BackupTargetValidationError.unsafeTarget(targetURL.path)
        }
        let staleCursorSourcePath = currentCursor == nil
            && migratedCursor?.backupPath == relativeBackupPath
            ? migratedCursor?.sourcePath
            : nil
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
                staleCursorSourcePath: nil,
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
            staleCursorSourcePath: staleCursorSourcePath,
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
        guard let cursor = cursorMap[previousSourcePath],
              cursor.sessionId == existingRecord?.sessionId,
              cursor.backupPath == existingRecord?.backupPath else {
            return nil
        }
        return cursor
    }

    private func trustedRecordedBackupURL(_ relativePath: String?) -> URL? {
        guard let relativePath else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1,
              ["sessions", "archived_sessions"].contains(components[0]),
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.contains("\\")
                      && !component.contains(":")
                      && !component.contains("\0")
              }) else {
            return nil
        }
        let target = components.reduce(paths.backupRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        guard paths.relativeBackupPath(for: target) == relativePath else {
            return nil
        }
        guard (try? RestoreFilesystemValidator.validateDestination(target, under: paths.backupRoot)) != nil else {
            return nil
        }
        return target
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
        let existingStatus = cachedStatusSnapshot()
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
        publish(snapshot)
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

    private static func loadPersistedStatus(at url: URL) -> BackupStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(BackupStatus.self, from: data)
    }

    private func publishPersistedStatusIfAvailable() {
        guard let status = try? loadLocalStatus() else { return }
        publish(status)
    }

    private func publish(_ status: BackupStatus) {
        stateLock.lock()
        cachedStatus = status
        stateLock.unlock()
        statusHandler?(status)
    }

    private func cachedStatusSnapshot() -> BackupStatus? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedStatus
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
        stateLock.lock()
        auditInterruptionEpoch &+= 1
        stateLock.unlock()
        instrumentation.auditInterruptionSet()
    }

    private func currentAuditInterruptionEpoch() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return auditInterruptionEpoch
    }

    private func auditWasInterrupted(since baselineEpoch: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped || auditInterruptionEpoch != baselineEpoch || Task.isCancelled
    }

    private func shouldStopBetweenSessionAtomicSteps() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped || Task.isCancelled
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
        stateLock.lock()
        let value = pollingStartedAt
        stateLock.unlock()
        return value ?? existingStatus?.lastStartedAt ?? fallback
    }

    private static func nanoseconds(fromSeconds seconds: UInt64) -> UInt64 {
        let multiplier: UInt64 = 1_000_000_000
        guard seconds <= UInt64.max / multiplier else { return UInt64.max }
        return seconds * multiplier
    }

    private static func nanoseconds(fromTimeInterval interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let nanoseconds = interval * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds.rounded(.up))
    }

    static func auditDelay(now: Date, lastAuditAt: Date?, deviceID: UUID) -> TimeInterval {
        let auditInterval: TimeInterval = 86_400
        guard let lastAuditAt else {
            return BackupIntegrityAuditor.overdueWakeDelaySeconds(deviceID: deviceID)
        }
        if now.timeIntervalSince(lastAuditAt) >= auditInterval {
            return BackupIntegrityAuditor.overdueWakeDelaySeconds(deviceID: deviceID)
        }

        let offset = BackupIntegrityAuditor.dailyOffsetSeconds(deviceID: deviceID)
        let startOfUTCDay = floor(now.timeIntervalSince1970 / auditInterval) * auditInterval
        var candidate = Date(timeIntervalSince1970: startOfUTCDay + offset)
        let earliestAllowed = lastAuditAt.addingTimeInterval(auditInterval)
        while candidate <= now || candidate < earliestAllowed {
            candidate = candidate.addingTimeInterval(auditInterval)
        }
        return candidate.timeIntervalSince(now)
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

import Foundation

public enum BackupProgressPhase: String, Codable, Sendable {
    case seeding
    case scanning
    case verifying
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
    private let healthCheckInterval: TimeInterval
    private let remoteHeartbeatInterval: TimeInterval
    private let autoStartEnabled: () -> Bool
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
    private var lastHealthCheckAt: Date?
    private var lastRemoteHeartbeatAt: Date?
    private var settledSourceSnapshot: [String: BackupSourceMetadata]?
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
        var sourcePath: String
        var sourceMetadata: BackupSourceMetadata
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
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil,
        healthCheckInterval: TimeInterval = 300,
        remoteHeartbeatInterval: TimeInterval = 1_800,
        autoStartEnabled: @escaping () -> Bool = { false }
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
            healthCheckInterval: healthCheckInterval,
            remoteHeartbeatInterval: remoteHeartbeatInterval,
            autoStartEnabled: autoStartEnabled,
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
        healthCheckInterval: TimeInterval = 300,
        remoteHeartbeatInterval: TimeInterval = 1_800,
        autoStartEnabled: @escaping () -> Bool = { false },
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
        self.healthCheckInterval = max(0.001, healthCheckInterval)
        self.remoteHeartbeatInterval = max(0.001, remoteHeartbeatInterval)
        self.autoStartEnabled = autoStartEnabled
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
        self.remoteStatusWriter = remoteStatusWriter ?? { data, url in
            try DurableAtomicWriter().write(data, to: url, createParentDirectories: false)
        }
        self.cachedStatus = initialStatus ?? Self.loadPersistedStatus(at: paths.localStatusURL)
        self.lastHealthCheckAt = self.cachedStatus?.lastHeartbeatAt
        self.lastRemoteHeartbeatAt = self.cachedStatus?.lastHeartbeatAt
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
        let verificationStore = BackupVerificationStore(
            fileURL: paths.verificationURL,
            createParentDirectories: false,
            fileManager: fileManager
        )
        var verification = try verificationStore.load()
        let originalVerification = verification
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
        var nextSettledSourceSnapshot: [String: BackupSourceMetadata] = [:]
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
                verification: &verification,
                verificationProgress: { [weak self] in
                    guard let self else { return }
                    let progress = BackupProgress(
                        totalFiles: sources.count,
                        completedFiles: completed,
                        pendingFiles: max(0, sources.count - completed),
                        phase: .verifying
                    )
                    self.lastKnownProgress = progress
                    self.progressHandler?(progress)
                },
                cursorMap: cursorMap
            )
            nextSettledSourceSnapshot[result.sourcePath] = result.sourceMetadata
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

        if verification != originalVerification {
            try verificationStore.save(verification)
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
        if scanErrors.isEmpty {
            stateLock.lock()
            settledSourceSnapshot = nextSettledSourceSnapshot
            stateLock.unlock()
        }
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
        if trigger == .timer {
            let hasPendingWork = (try? timerPreflightHasPendingWork()) ?? true
            guard hasPendingWork else {
                guard !backgroundWorkerIsActive() else { return }
                do {
                    try performIdleMaintenanceIfDue()
                } catch {
                    try? writeErrorStatus(error)
                }
                return
            }
        }

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

    private func backgroundWorkerIsActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped && workerActive
    }

    private func performIdleMaintenanceIfDue() throws {
        scanLock.lock()
        defer { scanLock.unlock() }
        let date = now()
        stateLock.lock()
        let healthDue = intervalIsDue(
            previous: lastHealthCheckAt,
            current: date,
            interval: healthCheckInterval
        )
        let heartbeatDue = intervalIsDue(
            previous: lastRemoteHeartbeatAt,
            current: date,
            interval: remoteHeartbeatInterval
        )
        stateLock.unlock()
        guard healthDue || heartbeatDue else { return }

        try targetValidator.validateTarget()
        stateLock.lock()
        lastHealthCheckAt = date
        stateLock.unlock()
        guard heartbeatDue, var status = cachedStatusSnapshot() else { return }

        status.lastHeartbeatAt = date
        status.autoStartEnabled = autoStartEnabled()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try remoteStatusWriter(data, paths.remoteStatusURL)
        try DurableAtomicWriter().write(
            data,
            to: paths.localStatusURL,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )
        stateLock.lock()
        lastRemoteHeartbeatAt = date
        stateLock.unlock()
        publish(status)
    }

    private func intervalIsDue(
        previous: Date?,
        current: Date,
        interval: TimeInterval
    ) -> Bool {
        guard let previous else { return true }
        return current.timeIntervalSince(previous) >= interval
    }

    private func timerPreflightHasPendingWork() throws -> Bool {
        stateLock.lock()
        let settled = settledSourceSnapshot
        stateLock.unlock()
        guard let settled else { return true }
        var currentCount = 0
        var processedSessionIDs = Set<String>()
        for source in try discoverSessionFiles() {
            guard let sessionID = SessionIdentity.sessionID(from: source),
                  processedSessionIDs.insert(sessionID).inserted else {
                continue
            }
            let sourcePath = canonicalSourcePath(source)
            let metadata = try metadata(for: source)
            guard let previous = settled[sourcePath],
                  previous.byteCount == metadata.size,
                  previous.modifiedAt == metadata.modifiedAt else {
                return true
            }
            currentCount += 1
        }
        return currentCount != settled.count
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
        verification: inout BackupVerificationDocument,
        verificationProgress: () -> Void,
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
        let existingVerification = verification.sessions[sessionID]
        let recordHasTrustedVerification = verificationMatches(
            existingVerification,
            record: existingRecord,
            relativeBackupPath: relativeBackupPath,
            chunkSize: verification.chunkSize
        )
        if recordHasTrustedVerification, scanIsStrictlyUnchanged(
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
                lastError: currentCursor?.lastError,
                sourcePath: sourcePath,
                sourceMetadata: sourceMetadata
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
        var rebuild = !targetState.exists
            || !metadataAgrees
            || !pathAgrees
            || targetState.byteCount != recordedOffset
            || !recordHasTrustedVerification
        if !rebuild {
            let identityMatches = baselineCursor?.sourceFileIdentity == nil
                || baselineCursor?.sourceFileIdentity == sourceMetadata.fileIdentity
            let anchorsMatch = if identityMatches, let existingVerification {
                (try? BackupFileVerifier(
                    chunkSize: verification.chunkSize
                ).verifyAppendAnchors(
                    source: sourceURL,
                    previous: existingVerification,
                    onRead: { range in
                        instrumentation.sourceBodyRead(
                            sourceURL,
                            range.lowerBound,
                            range.upperBound - range.lowerBound
                        )
                    }
                )) ?? false
            } else {
                false
            }
            rebuild = !identityMatches || !anchorsMatch
        }

        let finalStats: BackupFileStats
        let wroteData: Bool
        let finalOffset: Int64
        let pendingPartialLine: Data
        let blockedError: String?
        let contentHash: String?
        let appendedLineCount: Int
        let fallbackTitle: String?
        let verificationChunkSize = verification.chunkSize
        if rebuild {
            instrumentation.sourceBodyRead(sourceURL, 0, sourceMetadata.byteCount)
            let (streamed, verified) = try verifiedRebuild(
                sourceURL: sourceURL,
                targetURL: targetURL,
                chunkSize: verificationChunkSize,
                attempts: 2,
                verificationProgress: verificationProgress
            )
            verification.sessions[sessionID] = BackupSessionVerification(
                backupPath: relativeBackupPath,
                byteCount: verified.byteCount,
                lineCount: verified.lineCount,
                chunkHashes: verified.chunkHashes,
                verifiedAt: scanDate
            )
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
            guard let existingVerification else {
                throw BackupFileVerificationError.invalidFile(targetURL.path)
            }
            do {
                let appended = try fileCommitter.appendCompleteLines(
                    from: sourceURL,
                    offset: recordedOffset,
                    to: targetURL,
                    under: paths.backupRoot,
                    using: sessionBackupStreamer
                )
                let finalLineCount = recordedLineCount + appended.lineCount
                let updatedVerification: BackupSessionVerification
                if appended.appendedByteCount > 0 {
                    verificationProgress()
                    updatedVerification = try BackupFileVerifier(
                        chunkSize: verificationChunkSize
                    ).verifyChangedChunks(
                        source: sourceURL,
                        target: targetURL,
                        previous: existingVerification,
                        backupPath: relativeBackupPath,
                        committedByteCount: appended.committedByteCount,
                        lineCount: finalLineCount,
                        verifiedAt: scanDate
                    )
                } else {
                    updatedVerification = existingVerification
                }
                guard let sourceMetadataAfterAppend = try? fileCommitter.inspectSource(sourceURL),
                      sourceMetadataMatches(sourceMetadataAfterAppend, sourceMetadata) else {
                    throw BackupAgentScanError.sourceChangedDuringAppend(sourceURL.path)
                }
                verification.sessions[sessionID] = updatedVerification
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
            } catch BackupAgentScanError.sourceChangedDuringAppend(let path) {
                try fileCommitter.truncateTarget(
                    targetURL,
                    to: recordedOffset,
                    under: paths.backupRoot
                )
                throw BackupAgentScanError.sourceChangedDuringAppend(path)
            } catch {
                guard let sourceMetadataAfterFailure = try? fileCommitter.inspectSource(sourceURL),
                      sourceMetadataMatches(sourceMetadataAfterFailure, sourceMetadata) else {
                    try fileCommitter.truncateTarget(
                        targetURL,
                        to: recordedOffset,
                        under: paths.backupRoot
                    )
                    throw BackupAgentScanError.sourceChangedDuringAppend(sourceURL.path)
                }
                try fileCommitter.truncateTarget(
                    targetURL,
                    to: recordedOffset,
                    under: paths.backupRoot
                )
                instrumentation.sourceBodyRead(sourceURL, 0, sourceMetadata.byteCount)
                let (streamed, verified) = try verifiedRebuild(
                    sourceURL: sourceURL,
                    targetURL: targetURL,
                    chunkSize: verificationChunkSize,
                    attempts: 1,
                    verificationProgress: verificationProgress
                )
                verification.sessions[sessionID] = BackupSessionVerification(
                    backupPath: relativeBackupPath,
                    byteCount: verified.byteCount,
                    lineCount: verified.lineCount,
                    chunkHashes: verified.chunkHashes,
                    verifiedAt: scanDate
                )
                finalStats = BackupFileStats(
                    byteCount: streamed.committedByteCount,
                    lineCount: streamed.lineCount
                )
                finalOffset = streamed.committedByteCount
                pendingPartialLine = streamed.pendingPartialLine
                blockedError = streamed.blockedError
                appendedLineCount = streamed.lineCount - recordedLineCount
                wroteData = true
                contentHash = streamed.contentHash
                fallbackTitle = streamed.firstTitle
            }

            if finalOffset > recordedOffset {
                instrumentation.sourceBodyRead(
                    sourceURL,
                    recordedOffset,
                    finalOffset - recordedOffset
                )
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
            updatedAt: scanDate.timeIntervalSince1970,
            sourceFileIdentity: sourceMetadata.fileIdentity
        )
        return ProcessSessionFileResult(
            manifestChanged: manifestChanged,
            cursor: cursorNeedsUpsert(currentCursor: currentCursor, updatedCursor: updatedCursor) ? updatedCursor : nil,
            staleCursorSourcePath: staleCursorSourcePath,
            lastError: blockedError,
            sourcePath: sourcePath,
            sourceMetadata: sourceMetadata
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
              cursor.lastSourceModifiedAt == sourceMetadata.modifiedAt,
              cursor.sourceFileIdentity == nil
                || cursor.sourceFileIdentity == sourceMetadata.fileIdentity else {
            return false
        }

        let hasUncommittedBytes = sourceMetadata.byteCount > cursor.lastByteOffset
        if hasUncommittedBytes {
            return !cursor.pendingPartialLine.isEmpty || cursor.lastError != nil
        }
        return cursor.pendingPartialLine.isEmpty && cursor.lastError == nil
    }

    private func verificationMatches(
        _ verification: BackupSessionVerification?,
        record: BackupSessionRecord?,
        relativeBackupPath: String,
        chunkSize: Int
    ) -> Bool {
        guard let verification, let record,
              chunkSize > 0,
              verification.backupPath == relativeBackupPath,
              verification.backupPath == record.backupPath,
              verification.byteCount == record.bytesBackedUp,
              verification.lineCount == record.lineCount,
              verification.byteCount >= 0,
              verification.lineCount >= 0 else {
            return false
        }
        let expectedChunks = Int(
            (verification.byteCount + Int64(chunkSize) - 1) / Int64(chunkSize)
        )
        return verification.chunkHashes.count == expectedChunks
            && verification.chunkHashes.allSatisfy(Self.isSHA256)
    }

    private func verifiedRebuild(
        sourceURL: URL,
        targetURL: URL,
        chunkSize: Int,
        attempts: Int,
        verificationProgress: () -> Void
    ) throws -> (StreamedBackupResult, BackupFileVerificationResult) {
        guard attempts > 0 else {
            throw BackupFileVerificationError.invalidFile(targetURL.path)
        }
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                var verification: BackupFileVerificationResult?
                verificationProgress()
                let streamed = try fileCommitter.rebuildCompleteLines(
                    from: sourceURL,
                    at: targetURL,
                    under: paths.backupRoot,
                    using: sessionBackupStreamer,
                    verifyTemporary: { temporaryURL, expected in
                        verification = try BackupFileVerifier(chunkSize: chunkSize).verifyFull(
                            temporaryURL,
                            expectedByteCount: expected.committedByteCount,
                            expectedLineCount: expected.lineCount,
                            expectedContentHash: expected.contentHash
                        )
                    }
                )
                guard let verification else {
                    throw BackupFileVerificationError.invalidFile(targetURL.path)
                }
                return (streamed, verification)
            } catch {
                lastError = error
                if attempt + 1 == attempts {
                    guard error is BackupFileVerificationError else { throw error }
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    throw BackupAgentScanError.backupUploadOrVerificationFailed(
                        path: targetURL.path,
                        reason: reason
                    )
                }
            }
        }
        let finalError = lastError ?? BackupFileVerificationError.invalidFile(targetURL.path)
        guard finalError is BackupFileVerificationError else { throw finalError }
        let reason = (finalError as? LocalizedError)?.errorDescription
            ?? finalError.localizedDescription
        throw BackupAgentScanError.backupUploadOrVerificationFailed(
            path: targetURL.path,
            reason: reason
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private func canonicalSourcePath(_ sourceURL: URL) -> String {
        sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func ensureLocalStateDirectoriesExist() throws {
        try ensurePrivateLocalDirectory(paths.stateRoot)
        try ensurePrivateLocalDirectory(paths.logURL.deletingLastPathComponent())
    }

    private func ensurePrivateLocalDirectory(_ directory: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
        let metadata = try fileCommitter.inspectSource(sourceURL)
        return (metadata.byteCount, metadata.modifiedAt)
    }

    private func cursorNeedsUpsert(currentCursor: BackupCursor?, updatedCursor: BackupCursor) -> Bool {
        guard let currentCursor else { return true }
        return currentCursor.sessionId != updatedCursor.sessionId
            || currentCursor.sourcePath != updatedCursor.sourcePath
            || currentCursor.backupPath != updatedCursor.backupPath
            || currentCursor.lastByteOffset != updatedCursor.lastByteOffset
            || currentCursor.lastSourceSize != updatedCursor.lastSourceSize
            || currentCursor.lastSourceModifiedAt != updatedCursor.lastSourceModifiedAt
            || currentCursor.sourceFileIdentity != updatedCursor.sourceFileIdentity
            || currentCursor.lineCount != updatedCursor.lineCount
            || currentCursor.pendingPartialLine != updatedCursor.pendingPartialLine
            || currentCursor.status != updatedCursor.status
            || currentCursor.lastError != updatedCursor.lastError
    }

    private func sourceMetadataMatches(
        _ current: BackupSourceMetadata,
        _ scanStart: BackupSourceMetadata
    ) -> Bool {
        current.fileIdentity == scanStart.fileIdentity
            && current.byteCount == scanStart.byteCount
            && current.modifiedAt == scanStart.modifiedAt
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
            autoStartEnabled: autoStartEnabled(),
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
            stateLock.lock()
            lastHealthCheckAt = date
            lastRemoteHeartbeatAt = date
            stateLock.unlock()
        }
        try DurableAtomicWriter().write(
            data,
            to: paths.localStatusURL,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )
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
        try DurableAtomicWriter().write(
            data,
            to: paths.pendingSourcesURL,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )
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
    case backupUploadOrVerificationFailed(path: String, reason: String)
    case sourceChangedDuringAppend(String)

    var errorDescription: String? {
        switch self {
        case let .rangeVerificationFailed(path):
            return "NAS append range verification failed: \(path)"
        case let .backupUploadOrVerificationFailed(path, reason):
            return "NAS 备份上传或回读校验失败：\(path)。原因：\(reason)"
        case let .sourceChangedDuringAppend(path):
            return "Source changed during NAS append and will be retried: \(path)"
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

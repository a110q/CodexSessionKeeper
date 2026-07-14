import Foundation

public enum NASSetupState: String, Codable, Sendable {
    case unconfigured
    case disconnected
    case validating
    case seeding
    case running
    case pending
    case error
}

public enum BackupScanTrigger: String, Sendable {
    case startup
    case activation
    case timer
    case wake
    case reconnect
    case queued
}

public struct NASSetupSnapshot: Codable, Equatable, Sendable {
    public static let unconfigured = NASSetupSnapshot(state: .unconfigured)

    public let state: NASSetupState
    public let configuration: NASBackupConfiguration?
    public let pendingCount: Int
    public let completedCount: Int
    public let totalCount: Int
    public let lastBackupAt: Date?
    public let lastError: String?
    public let lastAuditAt: Date?
    public let lastAuditResult: String?
    public let lastRepairAt: Date?
    public let repairCount: Int?

    public init(
        state: NASSetupState,
        configuration: NASBackupConfiguration? = nil,
        pendingCount: Int = 0,
        completedCount: Int = 0,
        totalCount: Int = 0,
        lastBackupAt: Date? = nil,
        lastError: String? = nil,
        lastAuditAt: Date? = nil,
        lastAuditResult: String? = nil,
        lastRepairAt: Date? = nil,
        repairCount: Int? = nil
    ) {
        self.state = state
        self.configuration = configuration
        self.pendingCount = pendingCount
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.lastBackupAt = lastBackupAt
        self.lastError = lastError
        self.lastAuditAt = lastAuditAt
        self.lastAuditResult = lastAuditResult
        self.lastRepairAt = lastRepairAt
        self.repairCount = repairCount
    }
}

public protocol NASBackupAgentControlling: AnyObject {
    func startPolling(intervalSeconds: UInt64)
    func requestImmediateScan(_ trigger: BackupScanTrigger)
    func stop()
    func stopAndAwaitQuiescence(timeout: TimeInterval) -> Bool
}

extension BackupAgent: NASBackupAgentControlling {}

public enum NASBackupRuntimeError: LocalizedError, Sendable {
    case replacementQuiescenceTimedOut

    public var errorDescription: String? {
        switch self {
        case .replacementQuiescenceTimedOut:
            return "The previous backup writer is still finishing its current file; replacement was deferred."
        }
    }
}

private final class BackupCallbackSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            sequence &+= 1
            return sequence
        }
    }
}

@MainActor
public final class NASBackupRuntime {
    public typealias AgentFactory = (
        BackupPaths,
        UUID,
        BackupTargetValidator,
        BackupStatus?,
        @escaping (BackupProgress) -> Void,
        @escaping @Sendable (BackupStatus) -> Void
    ) -> any NASBackupAgentControlling
    public typealias StatusLoader = @MainActor (URL) -> BackupStatus?
    public typealias CallbackDelivery = @Sendable (
        @escaping @MainActor @Sendable () -> Void
    ) -> Void
    public typealias RetryScheduler = (
        TimeInterval,
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private let configurationService: NASConfigurationService
    private let codexRoot: URL
    private let agentFactory: AgentFactory
    private let loadStatus: StatusLoader
    private let callbackDelivery: CallbackDelivery
    private let scheduleRetry: RetryScheduler
    private let retryDelay: TimeInterval
    private let replacementQuiescenceTimeout: TimeInterval
    private var agent: (any NASBackupAgentControlling)?
    private var activeTarget: NASBackupTarget?
    private var snapshot = NASSetupSnapshot.unconfigured
    private var retryScheduled = false
    private var retryGeneration: UInt64 = 0
    private var stopped = false
    private var agentGeneration: UInt64 = 0
    private var lastAppliedCallbackSequence: UInt64 = 0

    public init(
        configurationService: NASConfigurationService,
        codexRoot: URL,
        agentFactory: @escaping AgentFactory = { paths, deviceID, validator, initialStatus, progress, status in
            BackupAgent(
                paths: paths,
                targetValidator: validator,
                deviceID: deviceID,
                initialStatus: initialStatus,
                progressHandler: progress,
                statusHandler: status
            )
        },
        loadStatus: @escaping StatusLoader = { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(BackupStatus.self, from: data)
        },
        callbackDelivery: @escaping CallbackDelivery = { action in
            Task { @MainActor in action() }
        },
        retryDelay: TimeInterval = 30,
        replacementQuiescenceTimeout: TimeInterval = 0.1,
        scheduleRetry: @escaping RetryScheduler = { delay, action in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                action()
            }
        }
    ) {
        self.configurationService = configurationService
        self.codexRoot = codexRoot
        self.agentFactory = agentFactory
        self.loadStatus = loadStatus
        self.callbackDelivery = callbackDelivery
        self.retryDelay = retryDelay
        self.replacementQuiescenceTimeout = replacementQuiescenceTimeout
        self.scheduleRetry = scheduleRetry
    }

    public func initialize() throws {
        stopped = false
        guard agent == nil else { return }
        snapshot = NASSetupSnapshot(
            state: .validating,
            configuration: try configurationService.savedConfiguration()
        )
        do {
            let target = try configurationService.resolveActiveTarget()
            startAgent(for: target, trigger: .startup)
        } catch NASConfigurationError.configurationMissing {
            snapshot = .unconfigured
        } catch {
            markDisconnected(error)
        }
    }

    @discardableResult
    public func activate(department: String, employee: String) throws -> NASBackupTarget {
        invalidateScheduledRetry()
        stopped = false
        guard stopAgentForReplacement() else {
            let error = NASBackupRuntimeError.replacementQuiescenceTimedOut
            markReplacementDeferred(error)
            throw error
        }
        snapshot = NASSetupSnapshot(state: .validating)
        do {
            let target = try configurationService.activate(department: department, employee: employee)
            startAgent(for: target, trigger: .activation)
            return target
        } catch {
            if let previous = try? configurationService.resolveActiveTarget() {
                startAgent(for: previous, trigger: .activation)
            } else {
                markDisconnected(error)
            }
            throw error
        }
    }

    public func retry() throws {
        guard !stopped else { return }
        invalidateScheduledRetry()
        let trigger: BackupScanTrigger = snapshot.state == .disconnected ? .reconnect : .activation
        guard stopAgentForReplacement() else {
            let error = NASBackupRuntimeError.replacementQuiescenceTimedOut
            markReplacementDeferred(error)
            throw error
        }
        snapshot = NASSetupSnapshot(state: .validating, configuration: snapshot.configuration)
        do {
            let target = try configurationService.resolveActiveTarget()
            startAgent(for: target, trigger: trigger)
        } catch {
            markDisconnected(error)
            throw error
        }
    }

    public func stop() {
        stopped = true
        invalidateScheduledRetry()
        stopAgentImmediately()
    }

    public func setupSnapshot() -> NASSetupSnapshot {
        return snapshot
    }

    public func requestImmediateScan(_ trigger: BackupScanTrigger) {
        guard !stopped else { return }
        agent?.requestImmediateScan(trigger)
    }

    public func recoverySources() throws -> [NASRecoverySource] {
        try configurationService.recoverySources()
    }

    public func paths(for source: NASRecoverySourceIdentity) throws -> BackupPaths {
        let target = try configurationService.resolveRecoveryTarget(source)
        return BackupPaths(
            codexRoot: codexRoot,
            backupRoot: target.backupRoot,
            stateRoot: target.localStateRoot
        )
    }

    private func startAgent(for target: NASBackupTarget, trigger: BackupScanTrigger) {
        invalidateScheduledRetry()
        let paths = BackupPaths(
            codexRoot: codexRoot,
            backupRoot: target.backupRoot,
            stateRoot: target.localStateRoot
        )
        let validator = BackupTargetValidator { [configurationService, configuration = target.configuration] in
            let resolved = try configurationService.resolveActiveTarget()
            guard resolved.configuration == configuration else {
                throw NASConfigurationError.invalidDeviceMarker(target.deviceRoot.path)
            }
        }
        let initialStatus = loadStatus(paths.localStatusURL)
        agentGeneration &+= 1
        let generation = agentGeneration
        let callbackSequencer = BackupCallbackSequencer()
        lastAppliedCallbackSequence = 0
        activeTarget = target
        snapshot = snapshot(
            state: initialStatus?.status == .error ? .error : .running,
            configuration: target.configuration,
            status: initialStatus
        )
        let createdAgent = agentFactory(
            paths,
            target.configuration.deviceID,
            validator,
            initialStatus,
            { [weak self, callbackDelivery] progress in
                let sequence = callbackSequencer.next()
                callbackDelivery { @MainActor [weak self] in
                    self?.record(
                        progress,
                        for: target.configuration,
                        generation: generation,
                        sequence: sequence
                    )
                }
            },
            { [weak self, callbackDelivery] status in
                let sequence = callbackSequencer.next()
                callbackDelivery { @MainActor [weak self] in
                    self?.record(
                        status,
                        for: target.configuration,
                        generation: generation,
                        sequence: sequence
                    )
                }
            }
        )
        agent = createdAgent
        createdAgent.startPolling(intervalSeconds: 30)
        createdAgent.requestImmediateScan(trigger)
    }

    private func stopAgentForReplacement() -> Bool {
        agentGeneration &+= 1
        lastAppliedCallbackSequence = 0
        guard let agent else {
            activeTarget = nil
            return true
        }
        guard agent.stopAndAwaitQuiescence(timeout: replacementQuiescenceTimeout) else {
            return false
        }
        self.agent = nil
        activeTarget = nil
        return true
    }

    private func stopAgentImmediately() {
        agentGeneration &+= 1
        lastAppliedCallbackSequence = 0
        agent?.stop()
        agent = nil
        activeTarget = nil
    }

    private func record(
        _ progress: BackupProgress,
        for configuration: NASBackupConfiguration,
        generation: UInt64,
        sequence: UInt64
    ) {
        guard shouldApplyCallback(
            configuration: configuration,
            generation: generation,
            sequence: sequence
        ) else { return }
        let state: NASSetupState = progress.pendingFiles > 0
            ? (progress.phase == .seeding ? .seeding : .pending)
            : .running
        snapshot = NASSetupSnapshot(
            state: state,
            configuration: configuration,
            pendingCount: progress.pendingFiles,
            completedCount: progress.completedFiles,
            totalCount: progress.totalFiles,
            lastBackupAt: snapshot.lastBackupAt,
            lastError: snapshot.lastError,
            lastAuditAt: snapshot.lastAuditAt,
            lastAuditResult: snapshot.lastAuditResult,
            lastRepairAt: snapshot.lastRepairAt,
            repairCount: snapshot.repairCount
        )
    }

    private func record(
        _ status: BackupStatus,
        for configuration: NASBackupConfiguration,
        generation: UInt64,
        sequence: UInt64
    ) {
        guard shouldApplyCallback(
            configuration: configuration,
            generation: generation,
            sequence: sequence
        ) else { return }
        let state: NASSetupState
        if status.status == .error {
            state = .error
        } else if snapshot.pendingCount > 0 {
            state = snapshot.state == .seeding ? .seeding : .pending
        } else {
            state = .running
        }
        snapshot = snapshot(state: state, configuration: configuration, status: status)
    }

    private func markDisconnected(_ error: Error) {
        stopAgentImmediately()
        updateDisconnectedSnapshot(error)
        scheduleReconnectRetry()
    }

    private func markReplacementDeferred(_ error: Error) {
        updateDisconnectedSnapshot(error)
        scheduleReconnectRetry()
    }

    private func updateDisconnectedSnapshot(_ error: Error) {
        snapshot = NASSetupSnapshot(
            state: .disconnected,
            configuration: snapshot.configuration,
            pendingCount: snapshot.pendingCount,
            completedCount: snapshot.completedCount,
            totalCount: snapshot.totalCount,
            lastBackupAt: snapshot.lastBackupAt,
            lastError: error.localizedDescription,
            lastAuditAt: snapshot.lastAuditAt,
            lastAuditResult: snapshot.lastAuditResult,
            lastRepairAt: snapshot.lastRepairAt,
            repairCount: snapshot.repairCount
        )
    }

    private func scheduleReconnectRetry() {
        guard !stopped else { return }
        retryGeneration &+= 1
        let scheduledGeneration = retryGeneration
        retryScheduled = true
        scheduleRetry(retryDelay) { [weak self] in
            guard let self,
                  !self.stopped,
                  self.retryScheduled,
                  self.retryGeneration == scheduledGeneration else {
                return
            }
            self.retryScheduled = false
            try? self.retry()
        }
    }

    private func invalidateScheduledRetry() {
        retryGeneration &+= 1
        retryScheduled = false
    }

    private func shouldApplyCallback(
        configuration: NASBackupConfiguration,
        generation: UInt64,
        sequence: UInt64
    ) -> Bool {
        guard agentGeneration == generation,
              activeTarget?.configuration == configuration,
              sequence > lastAppliedCallbackSequence else {
            return false
        }
        lastAppliedCallbackSequence = sequence
        return true
    }

    private func snapshot(
        state: NASSetupState,
        configuration: NASBackupConfiguration,
        status: BackupStatus?
    ) -> NASSetupSnapshot {
        NASSetupSnapshot(
            state: state,
            configuration: configuration,
            pendingCount: snapshot.pendingCount,
            completedCount: snapshot.completedCount,
            totalCount: snapshot.totalCount,
            lastBackupAt: status?.lastBackupAt ?? snapshot.lastBackupAt,
            lastError: status?.lastError,
            lastAuditAt: status?.lastAuditAt ?? snapshot.lastAuditAt,
            lastAuditResult: status?.lastAuditResult ?? snapshot.lastAuditResult,
            lastRepairAt: status?.lastRepairAt ?? snapshot.lastRepairAt,
            repairCount: status?.repairCount ?? snapshot.repairCount
        )
    }

}

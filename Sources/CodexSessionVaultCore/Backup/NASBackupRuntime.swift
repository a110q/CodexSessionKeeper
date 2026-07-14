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
}

extension BackupAgent: NASBackupAgentControlling {}

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
    public typealias RetryScheduler = (
        TimeInterval,
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private let configurationService: NASConfigurationService
    private let codexRoot: URL
    private let agentFactory: AgentFactory
    private let loadStatus: StatusLoader
    private let scheduleRetry: RetryScheduler
    private let retryDelay: TimeInterval
    private var agent: (any NASBackupAgentControlling)?
    private var activeTarget: NASBackupTarget?
    private var snapshot = NASSetupSnapshot.unconfigured
    private var retryScheduled = false
    private var stopped = false
    private var agentGeneration: UInt64 = 0

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
        retryDelay: TimeInterval = 30,
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
        self.retryDelay = retryDelay
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
        stopped = false
        stopAgent()
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
        let trigger: BackupScanTrigger = snapshot.state == .disconnected ? .reconnect : .activation
        retryScheduled = false
        stopAgent()
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
        retryScheduled = false
        stopAgent()
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
            { [weak self] progress in
                Task { @MainActor in
                    self?.record(progress, for: target.configuration, generation: generation)
                }
            },
            { [weak self] status in
                Task { @MainActor in
                    self?.record(status, for: target.configuration, generation: generation)
                }
            }
        )
        agent = createdAgent
        retryScheduled = false
        createdAgent.startPolling(intervalSeconds: 30)
        createdAgent.requestImmediateScan(trigger)
    }

    private func stopAgent() {
        agentGeneration &+= 1
        agent?.stop()
        agent = nil
        activeTarget = nil
    }

    private func record(
        _ progress: BackupProgress,
        for configuration: NASBackupConfiguration,
        generation: UInt64
    ) {
        guard agentGeneration == generation, activeTarget?.configuration == configuration else { return }
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
        generation: UInt64
    ) {
        guard agentGeneration == generation, activeTarget?.configuration == configuration else { return }
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
        stopAgent()
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
        guard !retryScheduled, !stopped else { return }
        retryScheduled = true
        scheduleRetry(retryDelay) { [weak self] in
            guard let self, !self.stopped, self.agent == nil else { return }
            self.retryScheduled = false
            try? self.retry()
        }
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

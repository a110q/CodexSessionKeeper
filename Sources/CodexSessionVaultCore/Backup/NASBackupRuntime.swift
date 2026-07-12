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

public struct NASSetupSnapshot: Codable, Equatable, Sendable {
    public static let unconfigured = NASSetupSnapshot(state: .unconfigured)

    public let state: NASSetupState
    public let configuration: NASBackupConfiguration?
    public let pendingCount: Int
    public let completedCount: Int
    public let totalCount: Int
    public let lastBackupAt: Date?
    public let lastError: String?

    public init(
        state: NASSetupState,
        configuration: NASBackupConfiguration? = nil,
        pendingCount: Int = 0,
        completedCount: Int = 0,
        totalCount: Int = 0,
        lastBackupAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.state = state
        self.configuration = configuration
        self.pendingCount = pendingCount
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.lastBackupAt = lastBackupAt
        self.lastError = lastError
    }
}

public protocol NASBackupAgentControlling: AnyObject {
    func startPolling(intervalSeconds: UInt64)
    func stop()
    func pendingSessionCount() throws -> Int
}

extension BackupAgent: NASBackupAgentControlling {}

@MainActor
public final class NASBackupRuntime {
    public typealias AgentFactory = (
        BackupPaths,
        BackupTargetValidator,
        @escaping (BackupProgress) -> Void
    ) -> any NASBackupAgentControlling
    public typealias RetryScheduler = (
        TimeInterval,
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private let configurationService: NASConfigurationService
    private let codexRoot: URL
    private let agentFactory: AgentFactory
    private let scheduleRetry: RetryScheduler
    private let retryDelay: TimeInterval
    private var agent: (any NASBackupAgentControlling)?
    private var activeTarget: NASBackupTarget?
    private var snapshot = NASSetupSnapshot.unconfigured
    private var retryScheduled = false
    private var stopped = false

    public init(
        configurationService: NASConfigurationService,
        codexRoot: URL,
        agentFactory: @escaping AgentFactory = { paths, validator, progress in
            BackupAgent(paths: paths, targetValidator: validator, progressHandler: progress)
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
            startAgent(for: target)
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
            startAgent(for: target)
            return target
        } catch {
            if let previous = try? configurationService.resolveActiveTarget() {
                startAgent(for: previous)
            } else {
                markDisconnected(error)
            }
            throw error
        }
    }

    public func retry() throws {
        guard !stopped else { return }
        retryScheduled = false
        stopAgent()
        snapshot = NASSetupSnapshot(state: .validating, configuration: snapshot.configuration)
        do {
            let target = try configurationService.resolveActiveTarget()
            startAgent(for: target)
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
        if let target = activeTarget,
           let status = loadLocalStatus(from: target.localStateRoot.appendingPathComponent("status.json")) {
            if status.status == .error {
                snapshot = NASSetupSnapshot(
                    state: .error,
                    configuration: target.configuration,
                    pendingCount: snapshot.pendingCount,
                    completedCount: snapshot.completedCount,
                    totalCount: snapshot.totalCount,
                    lastBackupAt: status.lastBackupAt,
                    lastError: status.lastError
                )
            } else if snapshot.state == .error {
                snapshot = NASSetupSnapshot(
                    state: .running,
                    configuration: target.configuration,
                    lastBackupAt: status.lastBackupAt
                )
            }
        }
        if let agent,
           snapshot.state == .running || snapshot.state == .pending,
           let pendingCount = try? agent.pendingSessionCount() {
            snapshot = NASSetupSnapshot(
                state: pendingCount > 0 ? .pending : .running,
                configuration: snapshot.configuration,
                pendingCount: pendingCount,
                completedCount: snapshot.completedCount,
                totalCount: snapshot.totalCount,
                lastBackupAt: snapshot.lastBackupAt,
                lastError: snapshot.lastError
            )
        }
        return snapshot
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

    private func startAgent(for target: NASBackupTarget) {
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
        let createdAgent = agentFactory(paths, validator) { [weak self] progress in
            Task { @MainActor in
                self?.record(progress)
            }
        }
        agent = createdAgent
        activeTarget = target
        retryScheduled = false
        createdAgent.startPolling(intervalSeconds: 10)
        snapshot = NASSetupSnapshot(state: .running, configuration: target.configuration)
    }

    private func stopAgent() {
        agent?.stop()
        agent = nil
        activeTarget = nil
    }

    private func record(_ progress: BackupProgress) {
        guard let configuration = activeTarget?.configuration else { return }
        let state: NASSetupState = progress.pendingFiles > 0
            ? (progress.phase == .seeding ? .seeding : .pending)
            : .running
        snapshot = NASSetupSnapshot(
            state: state,
            configuration: configuration,
            pendingCount: progress.pendingFiles,
            completedCount: progress.completedFiles,
            totalCount: progress.totalFiles
        )
    }

    private func markDisconnected(_ error: Error) {
        stopAgent()
        snapshot = NASSetupSnapshot(
            state: .disconnected,
            configuration: snapshot.configuration,
            lastError: error.localizedDescription
        )
        guard !retryScheduled, !stopped else { return }
        retryScheduled = true
        scheduleRetry(retryDelay) { [weak self] in
            guard let self, !self.stopped, self.agent == nil else { return }
            self.retryScheduled = false
            try? self.retry()
        }
    }

    private func loadLocalStatus(from url: URL) -> BackupStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupStatus.self, from: data)
    }
}

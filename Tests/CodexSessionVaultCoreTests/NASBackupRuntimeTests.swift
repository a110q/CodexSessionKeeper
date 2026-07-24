import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
@MainActor
struct NASBackupRuntimeTests {
    @Test
    func unconfiguredStartupDoesNotCreateAnAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.makeRuntime()

        try runtime.initialize()

        #expect(fixture.agentFactory.agents.isEmpty)
        #expect(runtime.setupSnapshot().state == .unconfigured)
    }

    @Test
    func validStartupCreatesAndStartsExactlyOneAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let target = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()

        try runtime.initialize()

        #expect(fixture.agentFactory.agents.count == 1)
        #expect(fixture.agentFactory.agents[0].paths.backupRoot == target.backupRoot)
        #expect(fixture.agentFactory.agents[0].startCount == 1)
        #expect(fixture.agentFactory.agents[0].pollingIntervals == [30])
        #expect(fixture.agentFactory.agents[0].triggers == [.startup])
        #expect(runtime.setupSnapshot().state == .validating)
    }

    @Test
    func startupPerformsOneExplicitWritableProbe() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        fixture.writeProbeCount.reset()
        let runtime = fixture.makeRuntime()

        try runtime.initialize()

        #expect(fixture.writeProbeCount.value == 1)
    }

    @Test
    func disconnectedStartupSchedulesThirtySecondRetryAndReconnectStartsOneAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let configured = try fixture.activateStoredConfiguration()
        fixture.connected = false
        let runtime = fixture.makeRuntime()

        try runtime.initialize()

        #expect(runtime.setupSnapshot().state == .disconnected)
        #expect(runtime.setupSnapshot().configuration == configured.configuration)
        #expect(fixture.agentFactory.agents.isEmpty)
        #expect(fixture.scheduler.delays == [30])

        fixture.connected = true
        fixture.scheduler.fireNext()

        #expect(fixture.agentFactory.agents.count == 1)
        #expect(fixture.agentFactory.agents[0].triggers == [.reconnect])
        #expect(runtime.setupSnapshot().state == .validating)
    }

    @Test
    func staleScheduledReconnectCannotReplaceHealthyManualReconnect() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        fixture.connected = false
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        #expect(fixture.scheduler.delays == [30])

        fixture.connected = true
        try runtime.retry()
        let healthyAgent = try #require(fixture.agentFactory.agents.first)

        fixture.scheduler.fireNext()

        #expect(fixture.agentFactory.agents.count == 1)
        #expect(healthyAgent.stopCount == 0)
        #expect(runtime.setupSnapshot().state == .validating)
        #expect(runtime.setupSnapshot().lastError == nil)
    }

    @Test
    func stopInvalidatesRetryEvenAfterRuntimeStartsAgain() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        fixture.connected = false
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        #expect(fixture.scheduler.delays == [30])

        runtime.stop()
        fixture.connected = true
        try runtime.initialize()
        let healthyAgent = try #require(fixture.agentFactory.agents.first)

        fixture.scheduler.fireNext()

        #expect(fixture.agentFactory.agents.count == 1)
        #expect(healthyAgent.stopCount == 0)
        #expect(runtime.setupSnapshot().state == .validating)
    }

    @Test
    func newerReconnectScheduleInvalidatesOlderAction() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        fixture.connected = false
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        #expect(throws: (any Error).self) {
            try runtime.retry()
        }
        #expect(fixture.scheduler.delays == [30, 30])
        fixture.connected = true

        fixture.scheduler.fireNext()
        #expect(fixture.agentFactory.agents.isEmpty)
        #expect(runtime.setupSnapshot().state == .disconnected)

        fixture.scheduler.fireNext()
        #expect(fixture.agentFactory.agents.count == 1)
        #expect(fixture.agentFactory.agents[0].triggers == [.reconnect])
        #expect(runtime.setupSnapshot().state == .validating)
    }

    @Test
    func markerMismatchDoesNotStartAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let target = try fixture.activateStoredConfiguration()
        try fixture.replaceMarkerDeviceID(at: target.deviceRoot)
        let runtime = fixture.makeRuntime()

        try runtime.initialize()

        #expect(fixture.agentFactory.agents.isEmpty)
        #expect(runtime.setupSnapshot().state == .disconnected)
    }

    @Test
    func setupSnapshotIsPureCachedRead() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        fixture.resetRuntimeIOCounts()
        let agent = fixture.agentFactory.agents[0]
        let requestsBeforeReads = agent.interactionCount

        for _ in 0..<100 {
            _ = runtime.setupSnapshot()
        }

        #expect(agent.interactionCount == requestsBeforeReads)
        #expect(agent.pendingCallCount == 0)
        #expect(fixture.statusReadCount == 0)
    }

    @Test
    func initializationLoadsPersistedStatusOnceAndCachesAuditFields() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let target = try fixture.activateStoredConfiguration()
        try fixture.writeLocalErrorStatus(for: target, message: "NAS volume disappeared")
        let runtime = fixture.makeRuntime()

        try runtime.initialize()

        let snapshot = runtime.setupSnapshot()

        #expect(fixture.statusReadCount == 1)
        #expect(snapshot.state == .error)
        #expect(snapshot.lastError == "NAS volume disappeared")
        #expect(snapshot.lastAuditAt == Date(timeIntervalSince1970: 1_700_000_002))
        #expect(snapshot.lastAuditResult == "completed")
        #expect(snapshot.lastRepairAt == Date(timeIntervalSince1970: 1_700_000_003))
        #expect(snapshot.repairCount == 4)
    }

    @Test
    func agentStatusCallbackUpdatesCachedSnapshotWithoutStatusRead() async throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        fixture.resetRuntimeIOCounts()

        fixture.agentFactory.agents[0].publishStatus(fixture.status(
            health: .error,
            message: "NAS volume disappeared"
        ))
        await Task.yield()

        let snapshot = runtime.setupSnapshot()
        #expect(fixture.statusReadCount == 0)
        #expect(snapshot.state == .error)
        #expect(snapshot.lastError == "NAS volume disappeared")
    }

    @Test
    func verifiedStateRequiresFinalStatusAfterReadbackProgress() async throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        let agent = try #require(fixture.agentFactory.agents.first)

        #expect(runtime.setupSnapshot().state == .validating)
        agent.publishProgress(BackupProgress(
            totalFiles: 1,
            completedFiles: 0,
            pendingFiles: 1,
            phase: .verifying
        ))
        await Task.yield()
        #expect(runtime.setupSnapshot().state == .verifying)

        agent.publishProgress(BackupProgress(
            totalFiles: 1,
            completedFiles: 1,
            pendingFiles: 0,
            phase: .scanning
        ))
        await Task.yield()
        #expect(runtime.setupSnapshot().state == .verifying)

        agent.publishStatus(fixture.status(health: .running, message: nil))
        await Task.yield()
        #expect(runtime.setupSnapshot().state == .running)
    }

    @Test
    func manualRetryAfterReconnectStartsAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        fixture.connected = false
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        fixture.connected = true
        try runtime.retry()

        #expect(fixture.agentFactory.agents.count == 1)
        #expect(fixture.agentFactory.agents[0].triggers == [.reconnect])
        #expect(runtime.setupSnapshot().state == .validating)
    }

    @Test
    func successfulFirstActivationRequestsImmediateActivationScan() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        _ = try runtime.activate(department: "运营部", employee: "陈超")

        #expect(fixture.agentFactory.agents.count == 1)
        #expect(fixture.agentFactory.agents[0].triggers == [.activation])
    }

    @Test
    func lifecycleScanRequestForwardsToActiveAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        runtime.requestImmediateScan(.wake)

        #expect(fixture.agentFactory.agents[0].triggers == [.startup, .wake])
    }

    @Test
    func updatePreparationDrainsTheActiveNASWriterWithinTheRequestedTimeout() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        let agent = try #require(fixture.agentFactory.agents.first)

        let drained = runtime.prepareForUpdate(timeout: 5)

        #expect(drained)
        #expect(agent.quiescenceWaits == [5])
        #expect(agent.stopCount == 1)
        runtime.requestImmediateScan(.wake)
        #expect(agent.triggers == [.startup])
    }

    @Test
    func cancelledUpdateCanRestartNASBackupAfterASuccessfulDrain() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        #expect(runtime.prepareForUpdate(timeout: 5))
        runtime.resumeAfterCancelledUpdate()

        #expect(fixture.agentFactory.agents.count == 2)
        #expect(fixture.agentFactory.agents[1].pollingIntervals == [30])
        #expect(fixture.agentFactory.agents[1].triggers == [.startup])
    }

    @Test
    func failedUpdateDrainImmediatelyResumesTheExistingNASAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        let agent = try #require(fixture.agentFactory.agents.first)
        agent.replacementQuiescenceResult = false

        #expect(!runtime.prepareForUpdate(timeout: 5))

        #expect(agent.quiescenceWaits == [5])
        #expect(agent.pollingIntervals == [30, 30])
    }

    @Test
    func manualRetryRevalidatesAndRestartsAnExistingAgent() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        try runtime.retry()

        #expect(fixture.agentFactory.agents.count == 2)
        #expect(fixture.agentFactory.agents[0].stopCount == 1)
        let restarted = try #require(fixture.agentFactory.agents.dropFirst().first)
        #expect(restarted.startCount == 1)
        #expect(restarted.triggers == [.activation])
    }

    @Test
    func replacementDefersWhenOldWriterCannotQuiesceWithinBoundedWait() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        fixture.agentFactory.writerProbe = ReplacementWriterProbe()
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        let oldAgent = try #require(fixture.agentFactory.agents.first)
        oldAgent.replacementQuiescenceResult = false

        let started = ContinuousClock.now
        #expect(throws: (any Error).self) {
            try runtime.retry()
        }
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .milliseconds(250))
        #expect(fixture.agentFactory.agents.count == 1)
        #expect(fixture.agentFactory.writerProbe?.maximumConcurrentWriters == 1)
        #expect(fixture.scheduler.delays == [30])

        oldAgent.finishCurrentAtomicFile()
        oldAgent.replacementQuiescenceResult = true
        fixture.scheduler.fireNext()

        #expect(fixture.agentFactory.agents.count == 2)
        #expect(fixture.agentFactory.writerProbe?.maximumConcurrentWriters == 1)
        fixture.agentFactory.agents.last?.finishCurrentAtomicFile()
    }

    @Test
    func stoppedAgentStatusCallbackCannotOverwriteReplacementAgentSnapshot() async throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        let stoppedAgent = fixture.agentFactory.agents[0]
        try runtime.retry()

        stoppedAgent.publishStatus(fixture.status(
            health: .error,
            message: "stale stopped agent"
        ))
        await Task.yield()

        #expect(runtime.setupSnapshot().state == .validating)
        #expect(runtime.setupSnapshot().lastError == nil)
    }

    @Test
    func olderProgressCallbackCannotOverwriteNewerErrorStatus() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let deliveries = ControlledCallbackDeliveries()
        let runtime = fixture.makeRuntime(callbackDelivery: { action in
            deliveries.append(action)
        })
        try runtime.initialize()
        let agent = try #require(fixture.agentFactory.agents.first)

        agent.publishProgress(BackupProgress(
            totalFiles: 2,
            completedFiles: 1,
            pendingFiles: 1,
            phase: .scanning
        ))
        agent.publishStatus(fixture.status(health: .error, message: "newer final error"))
        #expect(deliveries.count == 2)

        deliveries.deliverLast()
        deliveries.deliverLast()

        #expect(runtime.setupSnapshot().state == .error)
        #expect(runtime.setupSnapshot().lastError == "newer final error")
    }

    @Test
    func failedProgressCountReachesSnapshotAndFinalStatusRemainsError() async throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()
        let agent = try #require(fixture.agentFactory.agents.first)

        agent.publishProgress(BackupProgress(
            totalFiles: 2,
            completedFiles: 2,
            pendingFiles: 0,
            phase: .scanning,
            failedFiles: 1
        ))
        await Task.yield()
        #expect(runtime.setupSnapshot().completedCount == 2)
        #expect(runtime.setupSnapshot().failedCount == 1)

        agent.publishStatus(fixture.status(health: .error, message: "blocked line detail"))
        await Task.yield()
        #expect(runtime.setupSnapshot().state == .error)
        #expect(runtime.setupSnapshot().failedCount == 1)
        #expect(runtime.setupSnapshot().lastError == "blocked line detail")
    }

    @Test
    func failedReconfigurationRestartsPreviousValidatedTarget() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.activateStoredConfiguration()
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        #expect(throws: (any Error).self) {
            _ = try runtime.activate(department: "运营部", employee: "不存在")
        }

        #expect(fixture.agentFactory.agents.count == 2)
        #expect(fixture.agentFactory.agents[0].stopCount == 1)
        #expect(fixture.agentFactory.agents[1].paths.backupRoot == previous.backupRoot)
        #expect(fixture.agentFactory.agents[1].startCount == 1)
        #expect(fixture.agentFactory.agents[1].triggers == [.activation])
        #expect(runtime.setupSnapshot().state == .validating)
    }

    @Test
    func recoverySourcesListCurrentDeviceFirstAndRejectLinkedDevice() throws {
        let fixture = try NASRuntimeFixture()
        defer { fixture.cleanup() }
        let current = try fixture.activateStoredConfiguration()
        let oldID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        try fixture.createOldDevice(beside: current, deviceID: oldID, directoryName: "old-mac")
        try fixture.createLinkedDevice(beside: current)
        let runtime = fixture.makeRuntime()
        try runtime.initialize()

        let sources = try runtime.recoverySources()

        #expect(sources.map(\.identity.deviceID) == [current.configuration.deviceID, oldID])
        #expect(sources.first?.isCurrentDevice == true)
        #expect(try runtime.paths(for: sources[1].identity).backupRoot.lastPathComponent == "incremental-backups")
    }
}

@MainActor
private final class NASRuntimeFixture {
    let root: URL
    let mountRoot: URL
    let trustedRoot: URL
    let localStateRoot: URL
    let codexRoot: URL
    let store: NASConfigurationStore
    let service: NASConfigurationService
    let agentFactory = RecordingNASAgentFactory()
    let scheduler = RecordingRetryScheduler()
    let writeProbeCount = RuntimeWriteProbeCounter()
    private let connectivity = NASRuntimeConnectivity()
    private(set) var statusReadCount = 0
    var connected: Bool {
        get { connectivity.isConnected }
        set { connectivity.isConnected = newValue }
    }

    private let remountURL = URL(string: "smb://171@192.168.10.99/%E6%96%87%E4%BB%B6%E4%B8%AD%E8%BD%AC%E7%AB%99")!
    private let deviceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASBackupRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        mountRoot = root.appendingPathComponent("文件中转站", isDirectory: true)
        trustedRoot = mountRoot.appendingPathComponent("codex会话备份", isDirectory: true)
        localStateRoot = root.appendingPathComponent("local-state", isDirectory: true)
        codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        store = NASConfigurationStore(fileURL: localStateRoot.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(
            at: trustedRoot.appendingPathComponent("运营部/陈超", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        let selectedMountRoot = mountRoot
        let selectedRemountURL = remountURL
        let selectedConnectivity = connectivity
        let selectedDeviceID = deviceID
        let selectedWriteProbeCount = writeProbeCount
        let locator = CompanyNASLocator(mountedVolumes: {
            guard selectedConnectivity.isConnected else { return [] }
            return [NASMountedVolume(rootURL: selectedMountRoot, remountURL: selectedRemountURL)]
        })
        service = NASConfigurationService(
            locator: locator,
            store: store,
            localStateRoot: localStateRoot,
            deviceName: { "Runtime Mac" },
            deviceID: { selectedDeviceID },
            now: { Date(timeIntervalSince1970: 1_783_824_000) },
            writeProbe: NASWriteProbe { _ in selectedWriteProbeCount.increment() }
        )
    }

    func makeRuntime(
        callbackDelivery: (@Sendable (@escaping @MainActor @Sendable () -> Void) -> Void)? = nil
    ) -> NASBackupRuntime {
        NASBackupRuntime(
            configurationService: service,
            codexRoot: codexRoot,
            agentFactory: { paths, _, _, initialStatus, progressHandler, statusHandler in
                self.agentFactory.make(
                    paths: paths,
                    initialStatus: initialStatus,
                    progressHandler: progressHandler,
                    statusHandler: statusHandler
                )
            },
            loadStatus: { url in
                self.statusReadCount += 1
                guard let data = try? Data(contentsOf: url) else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode(BackupStatus.self, from: data)
            },
            callbackDelivery: callbackDelivery ?? { action in
                Task { @MainActor in action() }
            },
            scheduleRetry: { delay, action in self.scheduler.schedule(delay: delay, action: action) }
        )
    }

    func resetRuntimeIOCounts() {
        statusReadCount = 0
        for agent in agentFactory.agents {
            agent.resetInteractionCounts()
        }
    }

    func activateStoredConfiguration() throws -> NASBackupTarget {
        try service.activate(department: "运营部", employee: "陈超")
    }

    func replaceMarkerDeviceID(at deviceRoot: URL) throws {
        let markerURL = deviceRoot.appendingPathComponent("device.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(NASDeviceMarker.self, from: Data(contentsOf: markerURL))
        let marker = NASDeviceMarker(
            endpoint: old.endpoint,
            department: old.department,
            employee: old.employee,
            deviceID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            deviceName: old.deviceName,
            deviceDirectoryName: old.deviceDirectoryName,
            createdAt: old.createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    func createOldDevice(beside current: NASBackupTarget, deviceID: UUID, directoryName: String) throws {
        let root = current.employeeRoot.appendingPathComponent("devices/\(directoryName)", isDirectory: true)
        let backups = root.appendingPathComponent("incremental-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let marker = NASDeviceMarker(
            endpoint: .production,
            department: current.configuration.department,
            employee: current.configuration.employee,
            deviceID: deviceID,
            deviceName: "Old Mac",
            deviceDirectoryName: directoryName,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: root.appendingPathComponent("device.json"))
    }

    func createLinkedDevice(beside current: NASBackupTarget) throws {
        let outside = root.appendingPathComponent("outside-device", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: current.employeeRoot.appendingPathComponent("devices/linked-device"),
            withDestinationURL: outside
        )
    }

    func writeLocalErrorStatus(for target: NASBackupTarget, message: String) throws {
        let status = status(health: .error, message: message)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: target.localStateRoot, withIntermediateDirectories: true)
        try encoder.encode(status).write(to: target.localStateRoot.appendingPathComponent("status.json"))
    }

    func status(health: BackupHealthStatus, message: String?) -> BackupStatus {
        BackupStatus(
            agentVersion: "2.0.0",
            enabled: true,
            status: health,
            mode: .polling,
            codexRoot: codexRoot.path,
            backupRoot: trustedRoot.path,
            firstRunAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_001),
            lastBackupAt: nil,
            sessionCount: 1,
            lineCount: 1,
            bytesBackedUp: 32,
            autoStartEnabled: false,
            lastError: message,
            lastAuditAt: Date(timeIntervalSince1970: 1_700_000_002),
            lastAuditResult: "completed",
            lastRepairAt: Date(timeIntervalSince1970: 1_700_000_003),
            repairCount: 4
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RuntimeWriteProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }

    func reset() {
        lock.withLock { storedValue = 0 }
    }
}

private final class NASRuntimeConnectivity {
    var isConnected = true
}

@MainActor
private final class RecordingNASAgentFactory {
    private(set) var agents: [RecordingNASAgent] = []
    var writerProbe: ReplacementWriterProbe?

    func make(
        paths: BackupPaths,
        initialStatus: BackupStatus?,
        progressHandler: @escaping (BackupProgress) -> Void,
        statusHandler: @escaping @Sendable (BackupStatus) -> Void
    ) -> RecordingNASAgent {
        let agent = RecordingNASAgent(
            paths: paths,
            initialStatus: initialStatus,
            progressHandler: progressHandler,
            writerProbe: writerProbe,
            statusHandler: statusHandler
        )
        agents.append(agent)
        return agent
    }
}

private final class RecordingNASAgent: NASBackupAgentControlling, @unchecked Sendable {
    let paths: BackupPaths
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pollingIntervals: [UInt64] = []
    private(set) var triggers: [BackupScanTrigger] = []
    private(set) var pendingCallCount = 0
    private(set) var quiescenceWaits: [TimeInterval] = []
    var replacementQuiescenceResult = true
    private let progressHandler: (BackupProgress) -> Void
    private let writerProbe: ReplacementWriterProbe?
    private let statusHandler: @Sendable (BackupStatus) -> Void
    let initialStatus: BackupStatus?
    private var ownsWriter = false

    var interactionCount: Int {
        startCount + stopCount + triggers.count + pendingCallCount
    }

    init(
        paths: BackupPaths,
        initialStatus: BackupStatus?,
        progressHandler: @escaping (BackupProgress) -> Void,
        writerProbe: ReplacementWriterProbe?,
        statusHandler: @escaping @Sendable (BackupStatus) -> Void
    ) {
        self.paths = paths
        self.initialStatus = initialStatus
        self.progressHandler = progressHandler
        self.writerProbe = writerProbe
        self.statusHandler = statusHandler
    }

    func startPolling(intervalSeconds: UInt64) {
        startCount += 1
        pollingIntervals.append(intervalSeconds)
    }

    func requestImmediateScan(_ trigger: BackupScanTrigger) {
        triggers.append(trigger)
        if !ownsWriter {
            ownsWriter = true
            writerProbe?.enter()
        }
    }

    func stop() {
        stopCount += 1
    }

    func stopAndAwaitQuiescence(timeout: TimeInterval) -> Bool {
        quiescenceWaits.append(timeout)
        stop()
        if replacementQuiescenceResult {
            finishCurrentAtomicFile()
        }
        return replacementQuiescenceResult
    }

    func pendingSessionCount() throws -> Int {
        pendingCallCount += 1
        return 0
    }

    func publishStatus(_ status: BackupStatus) {
        statusHandler(status)
    }

    func publishProgress(_ progress: BackupProgress) {
        progressHandler(progress)
    }

    func finishCurrentAtomicFile() {
        guard ownsWriter else { return }
        ownsWriter = false
        writerProbe?.leave()
    }

    func resetInteractionCounts() {
        pendingCallCount = 0
    }
}

private final class ReplacementWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWriters = 0
    private var storedMaximumConcurrentWriters = 0

    var maximumConcurrentWriters: Int {
        lock.withLock { storedMaximumConcurrentWriters }
    }

    func enter() {
        lock.withLock {
            activeWriters += 1
            storedMaximumConcurrentWriters = max(storedMaximumConcurrentWriters, activeWriters)
        }
    }

    func leave() {
        lock.withLock { activeWriters -= 1 }
    }
}

private final class ControlledCallbackDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []

    var count: Int {
        lock.withLock { actions.count }
    }

    func append(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { actions.append(action) }
    }

    @MainActor
    func deliverLast() {
        let action = lock.withLock { actions.popLast() }
        action?()
    }
}

@MainActor
private final class RecordingRetryScheduler {
    private(set) var delays: [TimeInterval] = []
    private var actions: [@MainActor @Sendable () -> Void] = []

    func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        delays.append(delay)
        actions.append(action)
    }

    func fireNext() {
        guard !actions.isEmpty else { return }
        actions.removeFirst()()
    }
}

import SwiftUI
import AppKit
import CryptoKit
import CodexSessionVaultCore

struct SnapshotMeta: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    let codexRoot: String
    let reason: String?
    let kind: String?
    let modelProvider: String
    let model: String
    let accountFingerprint: String
    let sessionCount: Int
    let archivedSessionCount: Int
    let sizeBytes: Int64
    let includedPaths: [String]
    let appVersion: String
}

extension SnapshotMeta {
    var effectiveReason: String {
        if let reason, !reason.isEmpty { return reason }
        let timestampPrefixLength = 15
        if id.count > timestampPrefixLength + 1 {
            let suffixStart = id.index(id.startIndex, offsetBy: timestampPrefixLength + 1)
            return String(id[suffixStart...])
        }
        return "unknown"
    }

    var effectiveKind: String {
        if let kind, !kind.isEmpty { return kind }
        return effectiveReason == "manual" ? "manual" : "system"
    }

    var kindLabel: String {
        effectiveKind == "manual" ? "手动" : "系统自动"
    }

    var isManualSnapshot: Bool {
        effectiveKind == "manual"
    }
}

struct CurrentCodexState: Hashable {
    var codexRoot: String = ""
    var modelProvider: String = "unknown"
    var model: String = "unknown"
    var accountFingerprint: String = "none"
    var sessionCount: Int = 0
    var archivedSessionCount: Int = 0
    var configModified: Date?
    var authModified: Date?
}

struct CodexSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let rolloutPath: String
    let cwd: String
    let modelProvider: String
    let model: String
    let source: String
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
    let sizeBytes: Int64
    let existsOnDisk: Bool

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var displaySource: String {
        source.lowercased() == "vscode" ? "Codex 桌面端" : source
    }
}

struct ConversationMessage: Identifiable, Hashable, Sendable {
    let id: String
    let role: String
    let phase: String?
    let timestamp: Date?
    let text: String
}

private struct SessionDatabaseRow: Decodable {
    let id: String
    let title: String
    let rolloutPath: String
    let cwd: String
    let modelProvider: String
    let model: String?
    let source: String
    let createdAt: Int64
    let updatedAt: Int64
    let archived: Int
}

private struct RolloutFileMetadata {
    var cwd = ""
    var modelProvider = "unknown"
    var model = "unknown"
    var source = "jsonl"
    var title = ""
    var createdAt: Date?
}

private struct SessionRestorePreflight {
    let sessionIDs: Set<String>
    let sourceRoot: URL
    let destinationRoot: URL
    let sourceFiles: [TrustedSessionFile]
    let fingerprints: [SessionFileFingerprint]
    let destinationFingerprints: [SessionFileFingerprint]
    let missingDestinationFiles: [SessionFileAbsenceExpectation]
    let lineMutations: [SessionRestoreLineMutation]

    func validateCurrent() throws {
        for fingerprint in fingerprints { try fingerprint.validateCurrent() }
        for expectation in missingDestinationFiles { try expectation.validateCurrent() }
    }

    func validateDestinationCurrent(_ destination: URL) throws {
        let path = destination.standardizedFileURL.path
        for expectation in missingDestinationFiles where expectation.fileURL.path == path {
            try expectation.validateCurrent()
        }
        for fingerprint in destinationFingerprints
        where fingerprint.fileURL.standardizedFileURL.path == path {
            try fingerprint.validateCurrent()
        }
    }

    func destinationMustRemainMissing(_ destination: URL) -> Bool {
        let path = destination.standardizedFileURL.path
        return missingDestinationFiles.contains { $0.fileURL.path == path }
    }
}

private struct SessionRestoreLineMutation {
    let destinationURL: URL
    let output: Data
}

enum AppSection: String, CaseIterable, Identifiable {
    case sessions = "会话管理"
    case snapshots = "快照恢复"

    var id: String { rawValue }
}

enum RestoreMode: String, Codable, Sendable {
    case conversationsOnly
    case full

    var successMessage: String {
        switch self {
        case .conversationsOnly:
            return "已恢复对话。当前账号、登录态和模型供应商配置已保留。请重启 Codex。"
        case .full:
            return "已完整恢复快照。账号、登录态和配置也已按快照回滚。请重启 Codex。"
        }
    }
}

private enum RestoreProtectionMode: String, Codable, Sendable {
    case lightweight
    case full
}

private struct VaultWorkerCommand: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case createManualSnapshot
        case restoreSnapshot
        case restoreSnapshotSession
        case restoreSnapshotSessions
        case restoreIncrementalBackupSessions
        case deleteSnapshots
        case deleteSessions
        case createAutoProtectionSnapshot
        case autoRestoreSnapshot
    }

    let operation: Operation
    let codexRoot: String
    let vaultRoot: String
    let snapshot: SnapshotMeta?
    let snapshots: [SnapshotMeta]
    let sessions: [CodexSession]
    let snapshotName: String?
    let restoreMode: RestoreMode?
    let protectionMode: RestoreProtectionMode?
    let incrementalRecoverySource: NASRecoverySourceIdentity?
    let cancellationPath: String?

    init(
        operation: Operation,
        codexRoot: String,
        vaultRoot: String,
        snapshot: SnapshotMeta? = nil,
        snapshots: [SnapshotMeta] = [],
        sessions: [CodexSession] = [],
        snapshotName: String? = nil,
        restoreMode: RestoreMode? = nil,
        protectionMode: RestoreProtectionMode? = nil,
        incrementalRecoverySource: NASRecoverySourceIdentity? = nil,
        cancellationPath: String? = nil
    ) {
        self.operation = operation
        self.codexRoot = codexRoot
        self.vaultRoot = vaultRoot
        self.snapshot = snapshot
        self.snapshots = snapshots
        self.sessions = sessions
        self.snapshotName = snapshotName
        self.restoreMode = restoreMode
        self.protectionMode = protectionMode
        self.incrementalRecoverySource = incrementalRecoverySource
        self.cancellationPath = cancellationPath
    }

    func withCancellationPath(_ cancellationPath: String?) -> VaultWorkerCommand {
        VaultWorkerCommand(
            operation: operation,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshot: snapshot,
            snapshots: snapshots,
            sessions: sessions,
            snapshotName: snapshotName,
            restoreMode: restoreMode,
            protectionMode: protectionMode,
            incrementalRecoverySource: incrementalRecoverySource,
            cancellationPath: cancellationPath
        )
    }
}

private struct VaultWorkerResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let snapshot: SnapshotMeta?
    let error: String?

    static func ok(message: String, snapshot: SnapshotMeta? = nil) -> VaultWorkerResponse {
        VaultWorkerResponse(success: true, message: message, snapshot: snapshot, error: nil)
    }

    static func failed(_ error: String) -> VaultWorkerResponse {
        VaultWorkerResponse(success: false, message: "操作失败", snapshot: nil, error: error)
    }
}

private struct VaultWorkerProgress: Codable, Sendable {
    let fraction: Double
    let message: String
    let detail: String?

    init(fraction: Double, message: String, detail: String? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
        self.detail = detail
    }
}

private struct ExternalAttachmentManifest: Codable, Sendable {
    var records: [ExternalAttachmentRestoreRecord]
}

enum SnapshotFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case manual = "手动"
    case system = "系统自动"

    var id: String { rawValue }
}

enum SnapshotRestoreSource: String, CaseIterable, Identifiable {
    case snapshots = "快照"
    case incrementalBackups = "备份恢复"

    var id: String { rawValue }
}

enum VaultError: LocalizedError {
    case codexRootMissing(String)
    case snapshotMissing
    case invalidSnapshot
    case restoreCancelled
    case operationCancelled
    case sqliteUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexRootMissing(let path):
            return "Codex 数据目录不存在：\(path)"
        case .snapshotMissing:
            return "快照不存在或已被移动。"
        case .invalidSnapshot:
            return "快照结构不完整，无法恢复。"
        case .restoreCancelled:
            return "恢复已取消。"
        case .operationCancelled:
            return "操作已取消。"
        case .sqliteUnavailable:
            return "未找到 /usr/bin/sqlite3，无法合并 Codex 会话索引库。"
        case .commandFailed(let message):
            return message
        }
    }
}

@MainActor
final class VaultModel: ObservableObject {
    @Published var codexRoot: String
    @Published var vaultRoot: String
    @Published var selectedSection: AppSection? = .sessions
    @Published var snapshots: [SnapshotMeta] = []
    @Published var selectedID: SnapshotMeta.ID?
    @Published var snapshotSessions: [CodexSession] = []
    @Published var selectedSnapshotSessionID: CodexSession.ID?
    @Published var snapshotSessionSearch = ""
    @Published var sessions: [CodexSession] = [] {
        didSet {
            recomputeVisibleSessions()
        }
    }
    @Published private(set) var visibleSessions: [CodexSession] = []
    @Published var selectedSessionID: CodexSession.ID?
    @Published var checkedSessionIDs: Set<CodexSession.ID> = []
    @Published var checkedSnapshotIDs: Set<SnapshotMeta.ID> = []
    @Published var checkedSnapshotSessionIDs: Set<CodexSession.ID> = []
    @Published var sessionSearchInput = ""
    @Published var sessionSearch = "" {
        didSet {
            recomputeVisibleSessions()
        }
    }
    @Published var showArchivedSessions = true {
        didSet {
            recomputeVisibleSessions()
        }
    }
    @Published var snapshotFilter: SnapshotFilter = .all
    @Published var snapshotRestoreSource: SnapshotRestoreSource = .snapshots
    @Published var incrementalBackupCandidates: [IncrementalRestoreCandidate] = []
    @Published var selectedIncrementalBackupID: IncrementalRestoreCandidate.ID?
    @Published var checkedIncrementalBackupIDs: Set<IncrementalRestoreCandidate.ID> = []
    @Published var incrementalBackupSearch = ""
    @Published var showExistingIncrementalBackups = false
    @Published var incrementalBackupCatalogSummary: IncrementalBackupCatalogResult?
    @Published var conversationViewerSession: CodexSession?
    @Published var conversationMessages: [ConversationMessage] = []
    @Published var isConversationViewerPresented = false
    @Published var isConversationLoading = false
    @Published var conversationViewerError: String?
    @Published var autoRestoreOnLaunch: Bool {
        didSet {
            AutoRestorePreference.save(autoRestoreOnLaunch)
            if autoRestoreOnLaunch, oldValue == false {
                runLaunchAutoRestoreIfNeeded(force: true)
            }
        }
    }
    @Published var currentState = CurrentCodexState()
    @Published var status: String = "就绪"
    @Published var isBusy = false
    @Published var busyProgress: Double?
    @Published var busyDetail: String?
    @Published var canCancelBusyOperation = false
    @Published var isCancellationRequested = false
    @Published var snapshotName = ""
    @Published var lastError: String?
    @Published private(set) var nasSetupSnapshot = NASSetupSnapshot.unconfigured
    @Published private(set) var launchAtLoginSnapshot = LaunchAtLoginSnapshot(enabled: false)
    @Published var nasDepartments: [NASDirectoryOption] = []
    @Published var nasEmployees: [NASDirectoryOption] = []
    @Published var selectedNASDepartment = ""
    @Published var selectedNASEmployee = ""
    @Published var nasRecoverySources: [NASRecoverySource] = []
    @Published var selectedNASRecoverySourceID: UUID?
    @Published var isNASSetupPresented = false
    @Published var isEmployeeHelpPresented = false
    @Published private(set) var isNASCatalogReady = false
    @Published private(set) var onboardingDecision = EmployeeOnboardingPolicy.evaluate(
        snapshot: .unconfigured,
        storedVersion: 0,
        inProgress: false,
        catalogReady: false,
        selectionValid: false
    )

    private static let nasStatusRefreshInterval: UInt64 = 2_000_000_000
    private static let onboardingVersionKey = "employeeOnboardingVersion"
    private static let onboardingInProgressKey = "employeeOnboardingInProgress"
    private let fileManager = FileManager.default
    private let metadataFile = "snapshot.json"
    private let dataDir = "data"
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    private var didRunLaunchAutoRestore = false
    private var conversationLoadID = UUID()
    private var conversationLoadTask: Task<Void, Never>?
    private var sessionSearchTask: Task<Void, Never>?
    private var nasRuntime: NASBackupRuntime!
    private var nasConfigurationService: NASConfigurationService!
    private let launchAtLoginController: MacLaunchAtLoginController
    private var nasStatusTask: Task<Void, Never>?
    private var isNASReconfigurationPresented = false
    private var currentCancellationURL: URL?
    fileprivate var operationCancellationURL: URL?
    private let vaultPreparationFailure: String?

    private var snapshotRootURL: URL {
        URL(fileURLWithPath: vaultRoot).appendingPathComponent("snapshots", isDirectory: true)
    }

    private func snapshotDirectoryURL(_ snapshot: SnapshotMeta) throws -> URL {
        try SnapshotPathValidator.resolve(snapshot.id, under: snapshotRootURL)
    }

    private func snapshotDataURL(_ snapshot: SnapshotMeta) throws -> URL {
        try snapshotDirectoryURL(snapshot).appendingPathComponent(dataDir, isDirectory: true)
    }

    private func attachmentRecoveryRoot(snapshotID: String) throws -> URL {
        let snapshotURL = try SnapshotPathValidator.resolve(snapshotID, under: snapshotRootURL)
        return URL(fileURLWithPath: codexRoot, isDirectory: true)
            .appendingPathComponent("recovered_attachments", isDirectory: true)
            .appendingPathComponent(snapshotURL.lastPathComponent, isDirectory: true)
    }

    var nasSelectionIsValid: Bool {
        nasDepartments.contains { $0.name == selectedNASDepartment }
            && nasEmployees.contains { $0.name == selectedNASEmployee }
    }

    var canActivateSelectedNASIdentity: Bool {
        isNASReconfigurationPresented ? nasSelectionIsValid : onboardingDecision.canActivate
    }

    var displayAppVersion: String { appVersion }
    var isManualNASReconfiguration: Bool { isNASReconfigurationPresented }

    init(codexRoot explicitCodexRoot: String? = nil, vaultRoot explicitVaultRoot: String? = nil, refreshOnInit: Bool = true) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        launchAtLoginController = MacLaunchAtLoginController()
        let resolvedCodexRoot = explicitCodexRoot ?? "\(home)/.codex"
        let resolvedVaultRoot = explicitVaultRoot ?? "\(home)/.codex-session-vault"
        codexRoot = resolvedCodexRoot
        vaultRoot = resolvedVaultRoot
        autoRestoreOnLaunch = AutoRestorePreference.load()
        let vaultURL = URL(fileURLWithPath: resolvedVaultRoot, isDirectory: true)
        do {
            try LocalVaultPermissionHardener().prepareVault(at: vaultURL)
            vaultPreparationFailure = nil
        } catch {
            vaultPreparationFailure = "本地仓库权限加固失败：\(error.localizedDescription)"
        }
        let store = NASConfigurationStore(
            fileURL: vaultURL.appendingPathComponent("nas-backup-settings.json")
        )
        let service = NASConfigurationService(
            store: store,
            localStateRoot: vaultURL.appendingPathComponent("nas-state", isDirectory: true)
        )
        nasConfigurationService = service
        nasRuntime = NASBackupRuntime(
            configurationService: service,
            codexRoot: URL(fileURLWithPath: resolvedCodexRoot, isDirectory: true)
        )
        if let vaultPreparationFailure {
            lastError = vaultPreparationFailure
            status = "本地仓库初始化失败"
            return
        }
        if refreshOnInit {
            refresh()
            initializeNASBackup()
        }
    }

    deinit {
        conversationLoadTask?.cancel()
        sessionSearchTask?.cancel()
        nasStatusTask?.cancel()
    }

    var selectedSnapshot: SnapshotMeta? {
        snapshots.first { $0.id == selectedID }
    }

    var selectedSnapshotSession: CodexSession? {
        snapshotSessions.first { $0.id == selectedSnapshotSessionID }
    }

    var selectedSession: CodexSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var checkedSessions: [CodexSession] {
        sessions.filter { checkedSessionIDs.contains($0.id) }
    }

    var checkedSnapshots: [SnapshotMeta] {
        snapshots.filter { checkedSnapshotIDs.contains($0.id) }
    }

    var checkedSnapshotSessions: [CodexSession] {
        snapshotSessions.filter { checkedSnapshotSessionIDs.contains($0.id) }
    }

    var filteredIncrementalBackupCandidates: [IncrementalRestoreCandidate] {
        let query = incrementalBackupSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return incrementalBackupCandidates.filter { candidate in
            guard showExistingIncrementalBackups || candidate.status != .existing else { return false }
            guard !query.isEmpty else { return true }
            return [
                candidate.sessionId,
                candidate.title,
                candidate.sourcePath,
                candidate.backupPath,
                candidate.error ?? ""
            ].contains { $0.lowercased().contains(query) }
        }
    }

    var checkedRestorableIncrementalBackups: [IncrementalRestoreCandidate] {
        incrementalBackupCandidates.filter { checkedIncrementalBackupIDs.contains($0.id) && $0.isRestorable }
    }

    var nasBackupStatusIsError: Bool {
        nasSetupSnapshot.state == .error || nasSetupSnapshot.state == .disconnected
    }

    var nasBackupStatusLabel: String {
        switch nasSetupSnapshot.state {
        case .unconfigured: return "公司 NAS 会话备份：未配置"
        case .disconnected: return "公司 NAS 会话备份：NAS 未连接"
        case .validating: return "公司 NAS 会话备份：验证中"
        case .seeding: return "公司 NAS 会话备份：正在建立初始备份"
        case .verifying: return "公司 NAS 会话备份：正在校验"
        case .running: return "公司 NAS 会话备份：备份已验证"
        case .pending: return "公司 NAS 会话备份：存在待补传内容"
        case .error: return "公司 NAS 会话备份：失败"
        }
    }

    var nasBackupStatusDetail: String {
        if let error = nasSetupSnapshot.lastError, !error.isEmpty { return Self.shortBackupDetail(error) }
        guard let configuration = nasSetupSnapshot.configuration else { return "请完成部门和姓名配置" }
        let identity = "\(configuration.department)/\(configuration.employee) · \(configuration.deviceName)"
        if nasSetupSnapshot.state == .verifying {
            return "\(identity) · 正在回读校验已上传备份"
        }
        if nasSetupSnapshot.pendingCount > 0 {
            return "\(identity) · 待补传 \(nasSetupSnapshot.pendingCount)"
        }
        let lastBackup = nasSetupSnapshot.lastBackupAt?.formatted(date: .omitted, time: .shortened) ?? "尚无成功备份"
        return "\(identity) · \(lastBackup)"
    }

    var filteredSnapshots: [SnapshotMeta] {
        switch snapshotFilter {
        case .all:
            return snapshots
        case .manual:
            return snapshots.filter(\.isManualSnapshot)
        case .system:
            return snapshots.filter { !$0.isManualSnapshot }
        }
    }

    var filteredSnapshotSessions: [CodexSession] {
        let query = snapshotSessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return snapshotSessions }
        return snapshotSessions.filter { session in
            [
                session.id,
                session.title,
                session.cwd,
                session.modelProvider,
                session.model,
                session.source,
                session.rolloutPath
            ].contains { $0.lowercased().contains(query) }
        }
    }

    var filteredSessions: [CodexSession] {
        visibleSessions
    }

    private func recomputeVisibleSessions() {
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nextSessions = sessions.filter { session in
            sessionMatchesVisibleFilter(session, query: query)
        }
        guard nextSessions != visibleSessions else { return }
        visibleSessions = nextSessions
    }

    private func sessionMatchesVisibleFilter(_ session: CodexSession, query: String) -> Bool {
        guard showArchivedSessions || !session.archived else { return false }
        guard !query.isEmpty else { return true }
        return [
            session.id,
            session.title,
            session.cwd,
            session.modelProvider,
            session.model,
            session.source,
            session.rolloutPath
        ].contains { $0.lowercased().contains(query) }
    }

    func refresh() {
        lastError = nil
        do {
            try ensureVaultPrepared()
            try ensureDirectories()
            currentState = inspectCurrentState()
            sessions = try loadSessions()
            snapshots = try loadSnapshots()
            if selectedSessionID == nil {
                selectedSessionID = visibleSessions.first?.id ?? sessions.first?.id
            } else if !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = visibleSessions.first?.id ?? sessions.first?.id
            }
            selectFirstVisibleSnapshotIfNeeded()
            checkedSessionIDs = checkedSessionIDs.intersection(Set(sessions.map(\.id)))
            checkedSnapshotIDs = checkedSnapshotIDs.intersection(Set(snapshots.map(\.id)))
            refreshSelectedSnapshotSessions()
            status = "已刷新：\(sessions.count) 个会话，\(snapshots.count) 个快照"
        } catch {
            lastError = error.localizedDescription
            status = "刷新失败"
        }
    }

    private func initializeNASBackup() {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            status = "本地仓库初始化失败"
            return
        }
        try? nasRuntime.initialize()
        syncNASSetupSnapshot()
        if nasSetupSnapshot.state == .unconfigured {
            isNASSetupPresented = true
            refreshNASCatalog()
        } else {
            ensureLaunchAtLoginEnabled()
            refreshNASRecoverySources()
        }
        startNASStatusRefreshLoop()
    }

    private func startNASStatusRefreshLoop() {
        nasStatusTask?.cancel()
        nasStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncNASSetupSnapshot()
                do {
                    try await Task.sleep(nanoseconds: Self.nasStatusRefreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func syncNASSetupSnapshot() {
        nasSetupSnapshot = nasRuntime.setupSnapshot()
        reconcileEmployeeOnboarding()
        guard nasSetupSnapshot.configuration != nil else { return }
        let next = launchAtLoginController.currentState()
        if next != launchAtLoginSnapshot {
            launchAtLoginSnapshot = next
        }
    }

    func reconcileEmployeeOnboarding() {
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: Self.onboardingVersionKey)
        let inProgress = defaults.bool(forKey: Self.onboardingInProgressKey)
        let decision = EmployeeOnboardingPolicy.evaluate(
            snapshot: nasSetupSnapshot,
            storedVersion: storedVersion,
            inProgress: inProgress,
            catalogReady: isNASCatalogReady,
            selectionValid: nasSelectionIsValid
        )

        if decision.nextInProgress != inProgress {
            defaults.set(decision.nextInProgress, forKey: Self.onboardingInProgressKey)
        }
        if decision.shouldMarkComplete,
           storedVersion < EmployeeOnboardingPolicy.currentVersion {
            defaults.set(EmployeeOnboardingPolicy.currentVersion, forKey: Self.onboardingVersionKey)
        }

        onboardingDecision = decision
        if decision.presentSetup {
            isNASSetupPresented = true
        } else if !isNASReconfigurationPresented {
            isNASSetupPresented = false
        }
    }

    func dismissNASSetup() {
        guard !onboardingDecision.preventDismissal || isNASReconfigurationPresented else { return }
        isNASReconfigurationPresented = false
        isNASSetupPresented = false
    }

    func refreshNASCatalog() {
        isNASCatalogReady = false
        reconcileEmployeeOnboarding()
        do {
            let departments = try nasConfigurationService.departments()
            nasDepartments = departments
            isNASCatalogReady = true
            if !departments.contains(where: { $0.name == selectedNASDepartment }) {
                let savedDepartment: String? = nasSetupSnapshot.configuration?.department
                selectedNASDepartment = savedDepartment
                    .flatMap { saved in departments.first(where: { $0.name == saved })?.name }
                    ?? departments.first?.name
                    ?? ""
            }
            loadNASEmployees()
            lastError = nil
        } catch {
            nasDepartments = []
            nasEmployees = []
            selectedNASDepartment = ""
            selectedNASEmployee = ""
            isNASCatalogReady = false
            lastError = "检测公司 NAS 失败：\(error.localizedDescription)"
            reconcileEmployeeOnboarding()
        }
    }

    func loadNASEmployees() {
        defer { reconcileEmployeeOnboarding() }
        guard !selectedNASDepartment.isEmpty else {
            nasEmployees = []
            selectedNASEmployee = ""
            return
        }
        do {
            let employees = try nasConfigurationService.employees(in: selectedNASDepartment)
            nasEmployees = employees
            if !employees.contains(where: { $0.name == selectedNASEmployee }) {
                let savedEmployee: String? = nasSetupSnapshot.configuration?.employee
                selectedNASEmployee = savedEmployee
                    .flatMap { saved in employees.first(where: { $0.name == saved })?.name }
                    ?? employees.first?.name
                    ?? ""
            }
            lastError = nil
        } catch {
            nasEmployees = []
            selectedNASEmployee = ""
            lastError = "读取员工目录失败：\(error.localizedDescription)"
        }
    }

    func activateSelectedNASIdentity() {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            status = "NAS 配置失败"
            return
        }
        guard nasDepartments.contains(where: { $0.name == selectedNASDepartment }),
              nasEmployees.contains(where: { $0.name == selectedNASEmployee }) else {
            lastError = "请从当前 NAS 列表选择部门和姓名。"
            return
        }
        if let old = nasSetupSnapshot.configuration,
           old.department != selectedNASDepartment || old.employee != selectedNASEmployee {
            let alert = NSAlert()
            alert.messageText = "更换 NAS 备份身份？"
            alert.informativeText = "当前：\(old.department)/\(old.employee)\n新的：\(selectedNASDepartment)/\(selectedNASEmployee)\n\n旧备份不会迁移或删除，新身份会重新建立初始备份。"
            alert.addButton(withTitle: "确认更换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let wasManualReconfiguration = isNASReconfigurationPresented
        if nasSetupSnapshot.configuration == nil {
            UserDefaults.standard.set(true, forKey: Self.onboardingInProgressKey)
            reconcileEmployeeOnboarding()
        }
        do {
            _ = try nasRuntime.activate(
                department: selectedNASDepartment,
                employee: selectedNASEmployee
            )
            syncNASSetupSnapshot()
            ensureLaunchAtLoginEnabled()
            refreshNASRecoverySources()
            if wasManualReconfiguration {
                isNASReconfigurationPresented = false
                isNASSetupPresented = false
            }
            lastError = nil
        } catch {
            syncNASSetupSnapshot()
            lastError = "NAS 配置失败：\(error.localizedDescription)"
        }
    }

    func retryNASBackup() {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            status = "NAS 重新连接失败"
            return
        }
        do {
            try nasRuntime.retry()
            syncNASSetupSnapshot()
            refreshNASRecoverySources()
            lastError = nil
        } catch {
            syncNASSetupSnapshot()
            lastError = "NAS 重新连接失败：\(error.localizedDescription)"
        }
    }

    func retryLaunchAtLogin() {
        ensureLaunchAtLoginEnabled()
    }

    func openLoginItemSettings() {
        launchAtLoginController.openSystemSettings()
    }

    private func ensureLaunchAtLoginEnabled() {
        launchAtLoginSnapshot = launchAtLoginController.ensureEnabled()
    }

    func presentNASReconfiguration() {
        selectedNASDepartment = nasSetupSnapshot.configuration?.department ?? ""
        selectedNASEmployee = nasSetupSnapshot.configuration?.employee ?? ""
        isNASReconfigurationPresented = true
        isNASSetupPresented = true
        refreshNASCatalog()
    }

    func showEmployeeHelp() {
        isEmployeeHelpPresented = true
    }

    func openRecoveryFromHelp() {
        isEmployeeHelpPresented = false
        selectedSection = .snapshots
    }

    func reconfigureFromHelp() {
        isEmployeeHelpPresented = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.presentNASReconfiguration()
        }
    }

    func stopNASBackup() {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            return
        }
        nasRuntime.stop()
    }

    func prepareForUpdate(timeout: Duration = .seconds(5)) async -> Bool {
        let components = timeout.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return nasRuntime.prepareForUpdate(timeout: max(0, seconds))
    }

    func resumeBackupAfterCancelledUpdate() {
        nasRuntime.resumeAfterCancelledUpdate()
        syncNASSetupSnapshot()
    }

    func requestNASBackupScan(_ trigger: BackupScanTrigger) {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            status = "NAS 备份不可用"
            return
        }
        nasRuntime.requestImmediateScan(trigger)
    }

    func refreshNASRecoverySources() {
        do {
            try ensureVaultPrepared()
            let sources = try nasRuntime.recoverySources()
            nasRecoverySources = sources
            if !sources.contains(where: { $0.id == selectedNASRecoverySourceID }) {
                selectedNASRecoverySourceID = sources.first?.id
            }
        } catch {
            nasRecoverySources = []
            selectedNASRecoverySourceID = nil
        }
    }

    private static func shortBackupDetail(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 64 else { return trimmed.isEmpty ? "未知错误" : trimmed }
        return "\(trimmed.prefix(64))..."
    }

    func clearSessionSearch() {
        sessionSearchTask?.cancel()
        sessionSearchInput = ""
        sessionSearch = ""
        selectFirstVisibleSessionIfNeeded()
    }

    func updateSessionSearchInput(_ value: String) {
        sessionSearchInput = value
        sessionSearchTask?.cancel()
        sessionSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            self.sessionSearch = value
            self.selectFirstVisibleSessionIfNeeded()
        }
    }

    func selectFirstVisibleSessionIfNeeded() {
        if let selectedSessionID, visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        selectedSessionID = visibleSessions.first?.id
    }

    func toggleCheckedSession(_ session: CodexSession) {
        if checkedSessionIDs.contains(session.id) {
            checkedSessionIDs.remove(session.id)
        } else {
            checkedSessionIDs.insert(session.id)
        }
    }

    func checkAllVisibleSessions() {
        checkedSessionIDs.formUnion(visibleSessions.map(\.id))
    }

    func clearCheckedSessions() {
        checkedSessionIDs.removeAll()
    }

    func refreshSelectedSnapshotSessions() {
        guard let snapshot = selectedSnapshot else {
            snapshotSessions = []
            selectedSnapshotSessionID = nil
            checkedSnapshotSessionIDs.removeAll()
            return
        }

        do {
            snapshotSessions = try loadSessions(in: snapshot)
            checkedSnapshotSessionIDs = checkedSnapshotSessionIDs.intersection(Set(snapshotSessions.map(\.id)))
            if let selectedSnapshotSessionID,
               snapshotSessions.contains(where: { $0.id == selectedSnapshotSessionID }) {
                return
            }
            selectedSnapshotSessionID = filteredSnapshotSessions.first?.id ?? snapshotSessions.first?.id
        } catch {
            snapshotSessions = []
            selectedSnapshotSessionID = nil
            checkedSnapshotSessionIDs.removeAll()
            lastError = "读取快照会话失败：\(error.localizedDescription)"
        }
    }

    func selectFirstVisibleSnapshotSessionIfNeeded() {
        if let selectedSnapshotSessionID,
           filteredSnapshotSessions.contains(where: { $0.id == selectedSnapshotSessionID }) {
            return
        }
        selectedSnapshotSessionID = filteredSnapshotSessions.first?.id
    }

    func selectFirstVisibleSnapshotIfNeeded() {
        if let selectedID,
           snapshots.contains(where: { $0.id == selectedID }),
           filteredSnapshots.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = filteredSnapshots.first?.id
    }

    func toggleCheckedSnapshot(_ snapshot: SnapshotMeta) {
        if checkedSnapshotIDs.contains(snapshot.id) {
            checkedSnapshotIDs.remove(snapshot.id)
        } else {
            checkedSnapshotIDs.insert(snapshot.id)
        }
    }

    func checkAllSnapshots() {
        checkedSnapshotIDs.formUnion(filteredSnapshots.map(\.id))
    }

    func clearCheckedSnapshots() {
        checkedSnapshotIDs.removeAll()
    }

    func toggleCheckedSnapshotSession(_ session: CodexSession) {
        if checkedSnapshotSessionIDs.contains(session.id) {
            checkedSnapshotSessionIDs.remove(session.id)
            if selectedSnapshotSessionID == session.id {
                selectedSnapshotSessionID = checkedSnapshotSessions.first?.id ?? filteredSnapshotSessions.first?.id
            }
        } else {
            checkedSnapshotSessionIDs.insert(session.id)
            selectedSnapshotSessionID = session.id
        }
    }

    func checkAllVisibleSnapshotSessions() {
        let ids = filteredSnapshotSessions.filter(\.existsOnDisk).map(\.id)
        checkedSnapshotSessionIDs.formUnion(ids)
        selectedSnapshotSessionID = ids.first ?? selectedSnapshotSessionID
    }

    func clearCheckedSnapshotSessions() {
        checkedSnapshotSessionIDs.removeAll()
    }

    func refreshIncrementalBackupCandidates() {
        do {
            try ensureVaultPrepared()
            guard let source = nasRecoverySources.first(where: { $0.id == selectedNASRecoverySourceID }) else {
                throw VaultError.commandFailed("请先选择一个 NAS 备份设备。")
            }
            let paths = try nasRuntime.paths(for: source.identity)
            let currentIDs = Set((try loadSessions()).map(\.id))
            let result = try IncrementalBackupCatalog(paths: paths).load(currentSessionIDs: currentIDs)
            incrementalBackupCatalogSummary = result
            incrementalBackupCandidates = result.candidates
            checkedIncrementalBackupIDs = checkedIncrementalBackupIDs.intersection(Set(result.candidates.map(\.id)))
            if let selectedIncrementalBackupID,
               filteredIncrementalBackupCandidates.contains(where: { $0.id == selectedIncrementalBackupID }) {
                return
            }
            selectedIncrementalBackupID = filteredIncrementalBackupCandidates.first?.id
        } catch {
            incrementalBackupCatalogSummary = nil
            incrementalBackupCandidates = []
            selectedIncrementalBackupID = nil
            checkedIncrementalBackupIDs.removeAll()
            lastError = "读取增量备份失败：\(error.localizedDescription)"
        }
    }

    func toggleCheckedIncrementalBackup(_ candidate: IncrementalRestoreCandidate) {
        guard candidate.isRestorable else { return }
        if checkedIncrementalBackupIDs.contains(candidate.id) {
            checkedIncrementalBackupIDs.remove(candidate.id)
            if selectedIncrementalBackupID == candidate.id {
                selectedIncrementalBackupID = checkedRestorableIncrementalBackups.first?.id
                    ?? filteredIncrementalBackupCandidates.first?.id
            }
        } else {
            checkedIncrementalBackupIDs.insert(candidate.id)
            selectedIncrementalBackupID = candidate.id
        }
    }

    func checkAllVisibleIncrementalBackups() {
        let ids = filteredIncrementalBackupCandidates.filter(\.isRestorable).map(\.id)
        checkedIncrementalBackupIDs.formUnion(ids)
        selectedIncrementalBackupID = ids.first ?? selectedIncrementalBackupID
    }

    func clearCheckedIncrementalBackups() {
        checkedIncrementalBackupIDs.removeAll()
    }

    func selectFirstVisibleIncrementalBackupIfNeeded() {
        if let selectedIncrementalBackupID,
           filteredIncrementalBackupCandidates.contains(where: { $0.id == selectedIncrementalBackupID }) {
            return
        }
        selectedIncrementalBackupID = filteredIncrementalBackupCandidates.first?.id
    }

    func restoreSnapshotSessionPrimaryAction() {
        if !checkedSnapshotSessionIDs.isEmpty {
            restoreCheckedSnapshotSessions()
        } else {
            restoreSelectedSnapshotSession()
        }
    }

    func runLaunchAutoRestoreIfNeeded(force: Bool = false) {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            status = "自动找回检查失败"
            return
        }
        guard autoRestoreOnLaunch, force || !didRunLaunchAutoRestore else { return }
        didRunLaunchAutoRestore = true

        Task {
            await self.performLaunchAutoRestore()
        }
    }

    private func performLaunchAutoRestore() async {
        do {
            sessions = try loadSessions()
            snapshots = try loadSnapshots()
        } catch {
            lastError = error.localizedDescription
            status = "自动找回检查失败"
            return
        }

        let currentVisibleCount = sessions.count
        guard let latestSnapshot = latestAutoRestoreCandidate() else {
            if currentVisibleCount > 0 {
                let command = VaultWorkerCommand(
                    operation: .createAutoProtectionSnapshot,
                    codexRoot: codexRoot,
                    vaultRoot: vaultRoot
                )
                await runWorker("正在创建首次自动会话保护点...", command: command) { response in
                    self.refresh()
                    self.selectedID = response.snapshot?.id
                    self.status = "已创建首次自动会话保护点：\(currentVisibleCount) 个会话"
                }
            } else {
                status = "启动检查完成：暂无可恢复会话"
            }
            return
        }

        let snapshotCount = recoverableSessionCount(latestSnapshot)
        if snapshotCount > currentVisibleCount {
            let confirmed = confirm(
                title: "发现可找回的 Codex 会话，是否恢复？",
                message: """
                当前检测到 \(currentVisibleCount) 个会话，快照 “\(latestSnapshot.name)” 中有 \(snapshotCount) 个会话。

                选择继续后只会合并恢复对话，不会覆盖当前 auth.json、config.toml、账号登录态或模型供应商配置。
                """
            )
            guard confirmed else {
                status = "已取消自动找回：当前 \(currentVisibleCount) 个会话，快照 \(snapshotCount) 个会话"
                return
            }

            let command = VaultWorkerCommand(
                operation: .autoRestoreSnapshot,
                codexRoot: codexRoot,
                vaultRoot: vaultRoot,
                snapshot: latestSnapshot,
                restoreMode: .conversationsOnly
            )
            await runWorker("正在自动找回会话...", command: command) { response in
                self.refresh()
                self.selectedID = latestSnapshot.id
                self.selectedSection = .sessions
                self.status = response.message
                self.inform(title: "恢复完成", message: "\(response.message)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。")
            }
        } else if currentVisibleCount > snapshotCount {
            let command = VaultWorkerCommand(
                operation: .createAutoProtectionSnapshot,
                codexRoot: codexRoot,
                vaultRoot: vaultRoot
            )
            await runWorker("正在更新自动会话保护点...", command: command) { response in
                self.refresh()
                self.selectedID = response.snapshot?.id
                self.status = "已更新自动会话保护点：\(currentVisibleCount) 个会话"
            }
        } else {
            status = "启动检查完成：会话未丢失"
        }
    }

    func createManualSnapshot() {
        let name = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = VaultWorkerCommand(
            operation: .createManualSnapshot,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshotName: name.isEmpty ? nil : name
        )
        Task {
            await runWorker("正在创建快照...", command: command) { response in
                self.snapshotName = ""
                self.refresh()
                if let meta = response.snapshot {
                    self.selectedID = meta.id
                    self.status = "快照已创建：\(meta.name)"
                } else {
                    self.status = response.message
                }
            }
        }
    }

    func restoreSelectedConversationsOnly() {
        restoreSelected(mode: .conversationsOnly)
    }

    func restoreSelectedFull() {
        restoreSelected(mode: .full)
    }

    func restoreSelectedSnapshotSession() {
        guard let snapshot = selectedSnapshot, let session = selectedSnapshotSession else { return }
        guard session.existsOnDisk else {
            inform(
                title: "不能恢复缺文件会话",
                message: "这个快照里只有会话索引，没有真实会话文件。请选择标记为文件存在的快照或更早的删除前备份，否则 Codex 客户端无法打开恢复后的会话。"
            )
            status = "恢复已取消：快照缺少会话文件"
            return
        }

        guard let protectionMode = chooseRestoreProtectionMode(
            title: "只恢复这个会话？",
            message: """
            将从快照 “\(snapshot.name)” 恢复以下会话：
            \(session.displayTitle)

            只会恢复这一条会话的文件、历史索引和线程记录，不会覆盖当前账号、登录态和模型供应商配置。
            """,
            defaultMode: .lightweight
        ) else { return }

        let command = VaultWorkerCommand(
            operation: .restoreSnapshotSession,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshot: snapshot,
            sessions: [session],
            protectionMode: protectionMode
        )
        Task {
            await runWorker("正在恢复单个会话...", command: command) { response in
                self.refresh()
                self.selectedSection = .sessions
                self.selectedSessionID = session.id
                self.status = response.message
                self.inform(
                    title: "恢复完成",
                    message: "\(response.message)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
                )
            }
        }
    }

    func restoreCheckedSnapshotSessions() {
        guard let snapshot = selectedSnapshot else { return }
        let targets = checkedSnapshotSessions.filter(\.existsOnDisk)
        guard !targets.isEmpty else {
            inform(
                title: "没有可批量恢复的会话",
                message: "请先勾选快照中标记为文件存在的会话。标记为“缺文件”的记录只有数据库索引，无法恢复到 Codex 客户端。"
            )
            return
        }

        let names = targets.prefix(8).map(\.displayTitle).joined(separator: "\n")
        let suffix = targets.count > 8 ? "\n等 \(targets.count) 个会话" : ""
        guard let protectionMode = chooseRestoreProtectionMode(
            title: "批量恢复选中会话？",
            message: """
            将从快照 “\(snapshot.name)” 恢复 \(targets.count) 个会话：

            \(names)\(suffix)

            只会恢复这些会话的文件、历史索引和线程记录，不会覆盖当前账号、登录态和模型供应商配置。
            """,
            defaultMode: .lightweight
        ) else { return }

        let command = VaultWorkerCommand(
            operation: .restoreSnapshotSessions,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshot: snapshot,
            sessions: targets,
            protectionMode: protectionMode
        )
        Task {
            await runWorker("正在批量恢复会话...", command: command) { response in
                self.checkedSnapshotSessionIDs.removeAll()
                self.refresh()
                self.selectedSection = .sessions
                self.selectedSessionID = targets.first?.id
                self.status = response.message
                self.inform(
                    title: "恢复完成",
                    message: "\(response.message)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
                )
            }
        }
    }

    func restoreSelectedIncrementalBackupSessions() {
        let targets: [IncrementalRestoreCandidate]
        let checkedTargets = checkedRestorableIncrementalBackups
        if checkedTargets.isEmpty,
           let selected = incrementalBackupCandidates.first(where: { $0.id == selectedIncrementalBackupID && $0.isRestorable }) {
            targets = [selected]
        } else {
            targets = checkedTargets
        }

        guard !targets.isEmpty else {
            inform(
                title: "没有可恢复的缺失会话",
                message: "请先选择状态为“可恢复”的备份会话。已存在或备份异常的会话不会被恢复。"
            )
            return
        }

        let names = targets.prefix(8).map(\.title).joined(separator: "\n")
        let suffix = targets.count > 8 ? "\n等 \(targets.count) 个会话" : ""
        guard let protectionMode = chooseRestoreProtectionMode(
            title: "从公司 NAS 恢复缺失会话？",
            message: """
            将恢复 \(targets.count) 个当前 Codex 中缺失的会话：

            \(names)\(suffix)

            只恢复会话文件和本地索引，不覆盖当前账号、登录态、config.toml 或凭据。建议先退出 Codex 再恢复。
            """,
            defaultMode: .lightweight
        ) else { return }

        let commandSessions = targets.map { candidate in
            CodexSession(
                id: candidate.sessionId,
                title: candidate.title,
                rolloutPath: candidate.sourcePath,
                cwd: "",
                modelProvider: "unknown",
                model: "unknown",
                source: "incremental-backup",
                createdAt: candidate.firstSeenAt,
                updatedAt: candidate.lastBackedUpAt ?? candidate.firstSeenAt,
                archived: false,
                sizeBytes: candidate.bytesBackedUp,
                existsOnDisk: false
            )
        }

        guard let recoverySource = nasRecoverySources.first(where: { $0.id == selectedNASRecoverySourceID }) else {
            inform(title: "没有选择 NAS 备份设备", message: "请先选择当前设备或旧设备备份。")
            return
        }
        let command = VaultWorkerCommand(
            operation: .restoreIncrementalBackupSessions,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            sessions: commandSessions,
            protectionMode: protectionMode,
            incrementalRecoverySource: recoverySource.identity
        )
        Task {
            await runWorker("正在从公司 NAS 恢复缺失会话...", command: command) { response in
                self.checkedIncrementalBackupIDs.removeAll()
                self.refresh()
                self.refreshIncrementalBackupCandidates()
                self.selectedSection = .snapshots
                self.snapshotRestoreSource = .incrementalBackups
                self.status = response.message
                self.inform(
                    title: "备份恢复完成",
                    message: "\(response.message)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
                )
            }
        }
    }

    func restoreSessionFromLatestSnapshot(_ session: CodexSession) {
        selectedSessionID = session.id
        guard let match = latestSnapshotSession(matching: session.id) else {
            inform(
                title: "没有找到可恢复快照",
                message: "快照库里没有找到同时包含索引和真实会话文件的记录：\(session.displayTitle)"
            )
            status = "没有找到可恢复快照：\(session.displayTitle)"
            return
        }

        guard let protectionMode = chooseRestoreProtectionMode(
            title: "从最近快照恢复这个会话？",
            message: """
            将从快照 “\(match.snapshot.name)” 恢复以下会话：
            \(match.session.displayTitle)

            只恢复这一条会话的文件、历史索引和线程记录，不会覆盖当前账号、登录态和模型供应商配置。
            """,
            defaultMode: .lightweight
        ) else { return }

        let command = VaultWorkerCommand(
            operation: .restoreSnapshotSession,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshot: match.snapshot,
            sessions: [match.session],
            protectionMode: protectionMode
        )
        Task {
            await runWorker("正在从最近快照恢复单个会话...", command: command) { response in
                self.refresh()
                self.selectedSection = .sessions
                self.selectedSessionID = match.session.id
                self.status = response.message
                self.inform(
                    title: "恢复完成",
                    message: "\(response.message)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
                )
            }
        }
    }

    func openConversationViewer(for session: CodexSession) {
        conversationLoadTask?.cancel()
        selectedSessionID = session.id
        conversationViewerSession = session
        conversationMessages = []
        conversationViewerError = nil
        isConversationLoading = true
        isConversationViewerPresented = true
        status = "正在加载对话记录：\(session.displayTitle)"

        let loadID = UUID()
        conversationLoadID = loadID
        let sessionID = session.id
        let preferredPath = session.rolloutPath
        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        let title = session.displayTitle

        conversationLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let trustedFiles = try TrustedSessionFileResolver.resolve(
                    sessionIDs: [sessionID],
                    under: root
                )
                guard let trusted = trustedFiles.first(where: { $0.fileURL.path == preferredPath })
                        ?? trustedFiles.first else {
                    throw VaultError.commandFailed("会话文件不存在或身份校验失败。")
                }
                let messages = try ConversationLogParser.loadMessages(from: trusted).map {
                    ConversationMessage(
                        id: $0.id,
                        role: $0.role,
                        phase: $0.phase,
                        timestamp: $0.timestamp,
                        text: $0.text
                    )
                }
                await MainActor.run { [weak self] in
                    guard let self, self.conversationLoadID == loadID else { return }
                    self.conversationMessages = messages
                    self.isConversationLoading = false
                    self.conversationLoadTask = nil
                    self.status = "已打开对话记录：\(title)"
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.conversationLoadID == loadID else { return }
                    self.isConversationLoading = false
                    self.conversationLoadTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.conversationLoadID == loadID else { return }
                    self.conversationViewerError = error.localizedDescription
                    self.isConversationLoading = false
                    self.conversationLoadTask = nil
                    self.lastError = error.localizedDescription
                    self.status = "打开对话记录失败"
                }
            }
        }
    }

    func dismissConversationViewer() {
        conversationLoadID = UUID()
        conversationLoadTask?.cancel()
        conversationLoadTask = nil
        conversationMessages.removeAll(keepingCapacity: false)
        conversationViewerSession = nil
        conversationViewerError = nil
        isConversationLoading = false
    }

    private func restoreSelected(mode: RestoreMode) {
        guard let snapshot = selectedSnapshot else { return }
        let title: String
        let message: String
        switch mode {
        case .conversationsOnly:
            title = "只恢复 Codex 对话？"
            message = """
            将把选中快照里的对话、会话索引和相关本地会话文件合并恢复到 \(codexRoot)。

            默认不会恢复 auth.json 或 config.toml，因此当前账号、登录态和模型供应商配置会保留。建议先退出 Codex 再恢复。
            """
        case .full:
            title = "完整恢复 Codex 快照？"
            message = """
            将把选中快照完整恢复到 \(codexRoot)，包括 auth.json、config.toml、账号登录态和模型供应商配置。

            这会把当前账号/供应商配置回滚到快照时的状态。建议先退出 Codex 再恢复。
            """
        }
        guard let protectionMode = chooseRestoreProtectionMode(
            title: title,
            message: message,
            defaultMode: mode == .full ? .full : .lightweight
        ) else { return }

        let command = VaultWorkerCommand(
            operation: .restoreSnapshot,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshot: snapshot,
            restoreMode: mode,
            protectionMode: protectionMode
        )
        Task {
            await runWorker("正在恢复快照...", command: command) { response in
                self.refresh()
                self.status = response.message
                self.inform(
                    title: "恢复完成",
                    message: response.message
                )
            }
        }
    }

    func deleteSelected() {
        guard let snapshot = selectedSnapshot else { return }
        let confirmed = confirm(
            title: "删除快照？",
            message: "会删除快照 \(snapshot.name)，该操作不可撤销。"
        )
        guard confirmed else { return }

        let command = VaultWorkerCommand(
            operation: .deleteSnapshots,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshots: [snapshot]
        )
        Task {
            await runWorker("正在删除快照...", command: command) { _ in
                self.refresh()
                self.status = "快照已删除"
            }
        }
    }

    func deleteCheckedSnapshots() {
        let targets = checkedSnapshots
        guard !targets.isEmpty else { return }
        let names = targets.prefix(6).map(\.name).joined(separator: "\n")
        let suffix = targets.count > 6 ? "\n等 \(targets.count) 个快照" : ""
        let confirmed = confirm(
            title: "批量删除快照？",
            message: """
            将删除 \(targets.count) 个快照，该操作不可撤销。不会影响当前 Codex 会话。

            \(names)\(suffix)
            """
        )
        guard confirmed else { return }

        let command = VaultWorkerCommand(
            operation: .deleteSnapshots,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            snapshots: targets
        )
        Task {
            await runWorker("正在批量删除快照...", command: command) { _ in
                self.checkedSnapshotIDs.removeAll()
                self.refresh()
                self.status = "已删除 \(targets.count) 个快照"
            }
        }
    }

    func deleteSelectedSession() {
        guard let session = selectedSession else { return }
        let confirmed = confirm(
            title: "删除这个 Codex 会话？",
            message: """
            将删除会话：
            \(session.displayTitle)

            会同时清理会话文件、history.jsonl、session_index.jsonl、state_5.sqlite 线程记录和相关 shell 快照。删除前会自动创建轻量恢复点，只保存将被删除的会话。
            """
        )
        guard confirmed else { return }

        let command = VaultWorkerCommand(
            operation: .deleteSessions,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            sessions: [session]
        )
        Task {
            await runWorker("正在删除会话...", command: command) { _ in
                self.refresh()
                self.selectedSection = .sessions
                self.status = "会话已删除：\(session.displayTitle)。请重启 Codex 客户端刷新列表。"
            }
        }
    }

    func deleteCheckedSessions() {
        let targets = checkedSessions
        guard !targets.isEmpty else { return }
        let names = targets.prefix(6).map(\.displayTitle).joined(separator: "\n")
        let suffix = targets.count > 6 ? "\n等 \(targets.count) 个会话" : ""
        let confirmed = confirm(
            title: "批量删除 Codex 会话？",
            message: """
            将删除 \(targets.count) 个会话，并清理对应会话文件、history.jsonl、session_index.jsonl、state_5.sqlite 线程记录和相关 shell 快照。

            删除前会自动创建轻量恢复点，只保存将被删除的会话。

            \(names)\(suffix)
            """
        )
        guard confirmed else { return }

        let command = VaultWorkerCommand(
            operation: .deleteSessions,
            codexRoot: codexRoot,
            vaultRoot: vaultRoot,
            sessions: targets
        )
        Task {
            await runWorker("正在批量删除会话...", command: command) { _ in
                self.checkedSessionIDs.removeAll()
                self.refresh()
                self.selectedSection = .sessions
                self.status = "已删除 \(targets.count) 个会话。请重启 Codex 客户端刷新列表。"
            }
        }
    }

    func openSelectedSessionFile() {
        guard let session = selectedSession,
              let trusted = try? TrustedSessionFileResolver.resolve(
                sessionIDs: [session.id],
                under: URL(fileURLWithPath: codexRoot, isDirectory: true)
              ).first else { return }
        NSWorkspace.shared.open(trusted.fileURL)
    }

    func revealSelectedSessionFile() {
        guard let session = selectedSession,
              let trusted = try? TrustedSessionFileResolver.resolve(
                sessionIDs: [session.id],
                under: URL(fileURLWithPath: codexRoot, isDirectory: true)
              ).first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([trusted.fileURL])
    }

    func openCodexRoot() {
        NSWorkspace.shared.open(URL(fileURLWithPath: codexRoot, isDirectory: true))
    }

    func openVaultRoot() {
        NSWorkspace.shared.open(URL(fileURLWithPath: vaultRoot, isDirectory: true))
    }

    func openSelectedSnapshot() {
        guard let snapshot = selectedSnapshot else { return }
        do {
            NSWorkspace.shared.open(try snapshotDirectoryURL(snapshot))
        } catch {
            lastError = error.localizedDescription
            status = "打开快照失败"
        }
    }

    private func runBusy(_ busyStatus: String, operation: @escaping () throws -> Void) async {
        isBusy = true
        busyProgress = nil
        busyDetail = nil
        status = busyStatus
        lastError = nil
        await Task.yield()
        do {
            try operation()
        } catch {
            lastError = error.localizedDescription
            status = "操作失败"
        }
        isBusy = false
        busyProgress = nil
        busyDetail = nil
    }

    private func runBusyInBackground<T>(
        _ busyStatus: String,
        operation: @escaping () throws -> T,
        onSuccess: @escaping (T) -> Void
    ) async {
        isBusy = true
        busyProgress = nil
        busyDetail = nil
        status = busyStatus
        lastError = nil

        // Give SwiftUI one frame to present the centered progress overlay before heavy disk work starts.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)

        do {
            let result = try operation()
            onSuccess(result)
        } catch {
            lastError = error.localizedDescription
            status = "操作失败"
        }

        isBusy = false
        busyProgress = nil
        busyDetail = nil
    }

    private func runWorker(
        _ busyStatus: String,
        command: VaultWorkerCommand,
        onSuccess: @escaping (VaultWorkerResponse) -> Void
    ) async {
        do {
            try ensureVaultPrepared()
        } catch {
            lastError = error.localizedDescription
            status = "操作失败"
            return
        }
        let cancellationURL = fileManager.temporaryDirectory
            .appendingPathComponent("codex-session-vault-cancel-\(UUID().uuidString)")
        currentCancellationURL = cancellationURL
        isBusy = true
        busyProgress = 0
        canCancelBusyOperation = true
        isCancellationRequested = false
        busyDetail = "准备后台任务..."
        status = busyStatus
        lastError = nil
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)

        do {
            let response = try await VaultWorkerProcess.run(command.withCancellationPath(cancellationURL.path)) { progress in
                self.busyProgress = progress.fraction
                self.status = progress.message
                self.busyDetail = progress.detail
            }
            guard response.success else {
                throw VaultError.commandFailed(response.error ?? response.message)
            }
            isBusy = false
            busyProgress = nil
            busyDetail = nil
            canCancelBusyOperation = false
            isCancellationRequested = false
            currentCancellationURL = nil
            try? fileManager.removeItem(at: cancellationURL)
            onSuccess(response)
        } catch VaultError.operationCancelled {
            lastError = nil
            status = "操作已取消"
            isBusy = false
            busyProgress = nil
            busyDetail = nil
            canCancelBusyOperation = false
            isCancellationRequested = false
            currentCancellationURL = nil
            try? fileManager.removeItem(at: cancellationURL)
        } catch {
            lastError = error.localizedDescription
            status = "操作失败"
            isBusy = false
            busyProgress = nil
            busyDetail = nil
            canCancelBusyOperation = false
            isCancellationRequested = false
            currentCancellationURL = nil
            try? fileManager.removeItem(at: cancellationURL)
        }
    }

    func cancelBusyOperation() {
        guard isBusy, canCancelBusyOperation else { return }
        isCancellationRequested = true
        busyDetail = "正在请求取消。当前文件操作会在安全检查点停止，请稍等。"
        status = "正在取消..."
        if let currentCancellationURL {
            fileManager.createFile(atPath: currentCancellationURL.path, contents: Data(), attributes: nil)
        }
    }

    private func ensureVaultPrepared() throws {
        if let vaultPreparationFailure {
            throw VaultError.commandFailed(vaultPreparationFailure)
        }
    }

    private func ensureDirectories() throws {
        try ensureVaultPrepared()
        if !fileManager.fileExists(atPath: codexRoot) {
            throw VaultError.codexRootMissing(codexRoot)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: snapshotRootURL.path)) != nil {
            throw LocalVaultPermissionHardeningError.rootIsSymbolicLink(snapshotRootURL.path)
        }
        try fileManager.createDirectory(
            at: snapshotRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotRootURL.path)
    }

    private func loadSnapshots() throws -> [SnapshotMeta] {
        guard fileManager.fileExists(atPath: snapshotRootURL.path) else { return [] }
        let dirs = try fileManager.contentsOfDirectory(
            at: snapshotRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var result: [SnapshotMeta] = []
        for dir in dirs {
            let values = try dir.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let metaURL = dir.appendingPathComponent(metadataFile)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder.snapshot.decode(SnapshotMeta.self, from: data),
                  meta.id == dir.lastPathComponent,
                  (try? SnapshotPathValidator.resolve(
                    meta.id,
                    under: snapshotRootURL,
                    matching: dir
                  )) != nil else {
                continue
            }
            result.append(meta)
        }

        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func loadSessions() throws -> [CodexSession] {
        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        let database = root.appendingPathComponent("state_5.sqlite")
        if fileManager.fileExists(atPath: database.path),
           let sessions = try? loadSessionsFromStateDatabase(database: database, dataRoot: root),
           !sessions.isEmpty {
            return sessions
        }
        return try loadSessionsFromFiles(root: root)
    }

    private func loadSessions(in snapshot: SnapshotMeta) throws -> [CodexSession] {
        let dataURL = try snapshotDataURL(snapshot)
        let database = dataURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else {
            return try loadSessionsFromFiles(root: dataURL)
        }

        let databaseSessions = (try? loadSessionsFromStateDatabase(
            database: database,
            dataRoot: dataURL
        )) ?? []
        if !databaseSessions.isEmpty, databaseSessions.allSatisfy(\.existsOnDisk) {
            return databaseSessions
        }
        let fileSessions = try loadSessionsFromFiles(root: dataURL)
        return mergedSessions(primary: databaseSessions, fallback: fileSessions)
    }

    private func loadSessionsFromStateDatabase(
        database: URL,
        dataRoot: URL
    ) throws -> [CodexSession] {
        let trustedRollouts = try TrustedSessionFileResolver.index(under: dataRoot)
        return try loadSessionRows(from: database).map { row in
            let normalizedID = SessionJSONLValidator.normalizeSessionID(row.id)
            let snapshotFileURL = normalizedID.flatMap { trustedRollouts[$0]?.first }
            let exists = snapshotFileURL != nil
            return makeSession(
                row: row,
                existsOnDisk: exists,
                sizeBytes: snapshotFileURL.map(fileSize) ?? 0,
                rolloutPathOverride: snapshotFileURL?.path
            )
        }
    }

    private func loadSessionRows(from database: URL) throws -> [SessionDatabaseRow] {
        let sql = """
        SELECT
            id,
            title,
            rollout_path AS rolloutPath,
            cwd,
            model_provider AS modelProvider,
            model,
            source,
            created_at AS createdAt,
            updated_at AS updatedAt,
            archived
        FROM threads
        ORDER BY updated_at DESC, created_at DESC;
        """
        let output = try runCommand(executable: "/usr/bin/sqlite3", arguments: ["-json", database.path, sql])
        return try JSONDecoder().decode([SessionDatabaseRow].self, from: Data(output.utf8))
    }

    private func loadSessionsFromFiles(root: URL) throws -> [CodexSession] {
        let titleMaps = loadTitleMaps(root: root)
        let fileReferences = try TrustedSessionFileResolver.discover(under: root)

        let sessions = fileReferences.compactMap { reference -> CodexSession? in
            let fileURL = reference.fileURL
            let id = reference.sessionID
            let metadata = rolloutFileMetadata(fileURL)
            let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let updatedAt = values?.contentModificationDate ?? metadata.createdAt ?? Date(timeIntervalSince1970: 0)
            let createdAt = values?.creationDate ?? metadata.createdAt ?? updatedAt
            let relPath = relativePath(fileURL, under: root)
            let archived = titleMaps.archived[id] ?? (relPath?.hasPrefix("archived_sessions/") == true)
            return CodexSession(
                id: id,
                title: titleMaps.titles[id] ?? (metadata.title.isEmpty ? id : metadata.title),
                rolloutPath: fileURL.path,
                cwd: metadata.cwd,
                modelProvider: metadata.modelProvider,
                model: metadata.model,
                source: metadata.source,
                createdAt: createdAt,
                updatedAt: updatedAt,
                archived: archived,
                sizeBytes: Int64(values?.fileSize ?? 0),
                existsOnDisk: true
            )
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadTitleMaps(root: URL) -> (titles: [String: String], archived: [String: Bool]) {
        var titles: [String: String] = [:]
        var archived: [String: Bool] = [:]

        for line in (try? readLineData(root.appendingPathComponent("history.jsonl"))) ?? [] {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["session_id"] as? String else {
                continue
            }
            if let firstText = object["first_text"] as? String, !firstText.isEmpty {
                titles[id] = firstText
            }
            if let isArchived = object["is_archived"] as? Bool {
                archived[id] = isArchived
            } else if let isArchived = object["is_archived"] as? NSNumber {
                archived[id] = isArchived.boolValue
            }
        }

        for line in (try? readLineData(root.appendingPathComponent("session_index.jsonl"))) ?? [] {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  !title.isEmpty else {
                continue
            }
            titles[id] = title
        }

        return (titles, archived)
    }

    private func mergedSessions(primary: [CodexSession], fallback: [CodexSession]) -> [CodexSession] {
        var sessionsByID: [String: CodexSession] = [:]
        for session in fallback where !session.id.isEmpty {
            sessionsByID[session.id] = session
        }
        for session in primary where !session.id.isEmpty {
            if let fallbackSession = sessionsByID[session.id],
               !session.existsOnDisk,
               fallbackSession.existsOnDisk {
                sessionsByID[session.id] = CodexSession(
                    id: session.id,
                    title: session.title.isEmpty ? fallbackSession.title : session.title,
                    rolloutPath: fallbackSession.rolloutPath,
                    cwd: session.cwd,
                    modelProvider: session.modelProvider,
                    model: session.model,
                    source: session.source,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    archived: session.archived || fallbackSession.archived,
                    sizeBytes: fallbackSession.sizeBytes,
                    existsOnDisk: true
                )
            } else {
                sessionsByID[session.id] = session
            }
        }
        return sessionsByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func rolloutFileMetadata(_ fileURL: URL) -> RolloutFileMetadata {
        var metadata = RolloutFileMetadata()
        for line in ((try? readLineData(fileURL)) ?? []).prefix(160) {
            guard !line.isWhitespaceOrEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            let objectType = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if objectType == "session_meta", let payload {
                metadata.cwd = (payload["cwd"] as? String) ?? metadata.cwd
                metadata.modelProvider = (payload["model_provider"] as? String) ?? metadata.modelProvider
                metadata.model = (payload["model"] as? String) ?? metadata.model
                metadata.source = (payload["source"] as? String) ?? metadata.source
                if let timestamp = payload["timestamp"] as? String {
                    metadata.createdAt = parseCodexTimestamp(timestamp) ?? metadata.createdAt
                }
            }

            let payloadType = payload?["type"] as? String
            if objectType == "user_message" || payloadType == "user_message" || payload?["role"] as? String == "user" {
                if let title = userMessageTitle(from: payload), !title.isEmpty {
                    metadata.title = title
                    break
                }
            }
        }
        return metadata
    }

    private func userMessageTitle(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        if let message = payload["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = payload["content"] as? [[String: Any]] {
            for item in content {
                if let text = item["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private func makeSession(
        row: SessionDatabaseRow,
        existsOnDisk: Bool,
        sizeBytes: Int64,
        rolloutPathOverride: String? = nil
    ) -> CodexSession {
        CodexSession(
            id: row.id,
            title: row.title,
            rolloutPath: rolloutPathOverride ?? "",
            cwd: row.cwd,
            modelProvider: row.modelProvider,
            model: row.model?.isEmpty == false ? row.model! : "unknown",
            source: row.source,
            createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt)),
            archived: row.archived == 1,
            sizeBytes: sizeBytes,
            existsOnDisk: existsOnDisk
        )
    }

    private func inspectCurrentState() -> CurrentCodexState {
        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        let configURL = root.appendingPathComponent("config.toml")
        let authURL = root.appendingPathComponent("auth.json")
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let auth = (try? Data(contentsOf: authURL)) ?? Data()

        return CurrentCodexState(
            codexRoot: codexRoot,
            modelProvider: parseTomlString(config, key: "model_provider") ?? "unknown",
            model: parseTomlString(config, key: "model") ?? "unknown",
            accountFingerprint: fingerprint(auth),
            sessionCount: countJSONLFiles(root.appendingPathComponent("sessions")),
            archivedSessionCount: countJSONLFiles(root.appendingPathComponent("archived_sessions")),
            configModified: modifiedDate(configURL),
            authModified: modifiedDate(authURL)
        )
    }

    private func createSnapshot(name: String?, reason: String, candidatePaths: [String]? = nil) throws -> SnapshotMeta {
        try checkOperationCancellation()
        try ensureDirectories()
        let now = Date()
        let baseID = "\(Self.timestampID(now))-\(reason)"
        var id = baseID
        var collisionIndex = 2
        while fileManager.fileExists(atPath: snapshotRootURL.appendingPathComponent(id, isDirectory: true).path) {
            id = "\(baseID)-\(collisionIndex)"
            collisionIndex += 1
        }
        let snapshotURL = snapshotRootURL.appendingPathComponent(id, isDirectory: true)
        let dataURL = snapshotURL.appendingPathComponent(dataDir, isDirectory: true)
        try fileManager.createDirectory(
            at: snapshotURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: dataURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        let requestedPaths = candidatePaths ?? backupCandidates
        let rawCopyCandidates = requestedPaths.filter { !stateDatabaseSnapshotPaths.contains($0) }
        var paths = existingBackupPaths(root: root, candidates: rawCopyCandidates)
        for relPath in paths {
            try checkOperationCancellation()
            let src = root.appendingPathComponent(relPath)
            let dst = dataURL.appendingPathComponent(relPath)
            try copyReplacing(src: src, dst: dst)
        }

        try checkOperationCancellation()
        if requestedPaths.contains("state_5.sqlite"),
           try copyConsistentStateDatabase(from: root, to: dataURL) {
            paths.append("state_5.sqlite")
        }

        var snapshotSessionCount: Int?
        var snapshotArchivedSessionCount: Int?
        var restorableIDsForAttachments = Set<String>()
        if paths.contains("state_5.sqlite") {
            try checkOperationCancellation()
            let restorableIDs = try sanitizeSnapshotData(dataURL: dataURL, snapshotCodexRoot: codexRoot)
            restorableIDsForAttachments = restorableIDs
            let counts = try snapshotSessionCounts(dataURL: dataURL, sessionIDs: restorableIDs)
            snapshotSessionCount = counts.active
            snapshotArchivedSessionCount = counts.archived
        }
        try checkOperationCancellation()
        if try copyExternalAttachments(sessionIDs: restorableIDsForAttachments, from: dataURL) {
            paths.append("external_attachments")
        }

        let state = inspectCurrentState()
        let meta = SnapshotMeta(
            id: id,
            name: name ?? defaultSnapshotName(reason: reason, state: state),
            createdAt: now,
            codexRoot: codexRoot,
            reason: reason,
            kind: snapshotKind(for: reason),
            modelProvider: state.modelProvider,
            model: state.model,
            accountFingerprint: state.accountFingerprint,
            sessionCount: snapshotSessionCount ?? state.sessionCount,
            archivedSessionCount: snapshotArchivedSessionCount ?? state.archivedSessionCount,
            sizeBytes: directorySize(dataURL),
            includedPaths: paths,
            appVersion: appVersion
        )

        let encoded = try JSONEncoder.snapshot.encode(meta)
        try checkOperationCancellation()
        do {
            try LocalVaultPermissionHardener().hardenTree(at: snapshotURL)
            try DurableAtomicWriter().write(
                encoded,
                to: snapshotURL.appendingPathComponent(metadataFile),
                permissions: 0o600,
                parentDirectoryPermissions: 0o700,
                createParentDirectories: false
            )
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
        return meta
    }

    @discardableResult
    private func createSystemSnapshot(name: String?, reason: String, candidatePaths: [String]? = nil) throws -> SnapshotMeta {
        let meta = try createSnapshot(name: name, reason: reason, candidatePaths: candidatePaths)
        try enforceAutomaticSnapshotRetention()
        return meta
    }

    @discardableResult
    private func createSessionProtectionSnapshot(
        name: String,
        reason: String,
        sessions: [CodexSession],
        extraCandidatePaths: [String] = []
    ) throws -> SnapshotMeta {
        try checkOperationCancellation()
        let targetIDs = Set(sessions.map(\.id))
        guard !targetIDs.isEmpty || !extraCandidatePaths.isEmpty else {
            throw VaultError.commandFailed("没有可备份的会话。")
        }
        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        let now = Date()
        let baseID = "\(Self.timestampID(now))-\(reason)"
        var id = baseID
        var collisionIndex = 2
        while fileManager.fileExists(atPath: snapshotRootURL.appendingPathComponent(id, isDirectory: true).path) {
            id = "\(baseID)-\(collisionIndex)"
            collisionIndex += 1
        }

        let snapshotURL = snapshotRootURL.appendingPathComponent(id, isDirectory: true)
        let dataURL = snapshotURL.appendingPathComponent(dataDir, isDirectory: true)
        let protectionPlan = try SessionProtectionSnapshotPlan.preflight(
            sessionIDs: targetIDs,
            codexRoot: root,
            destinationRoot: dataURL,
            fileManager: fileManager
        )
        try ensureDirectories()

        var snapshotCreated = false
        let meta: SnapshotMeta
        do {
            try fileManager.createDirectory(
                at: snapshotURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            snapshotCreated = true
            try fileManager.createDirectory(
                at: dataURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )

            var includedPaths = try protectionPlan.materialize()
            for relPath in extraCandidatePaths {
                try checkOperationCancellation()
                guard !stateDatabaseSnapshotPaths.contains(relPath),
                      !conversationLineMergePaths.contains(relPath) else {
                    continue
                }
                let src = root.appendingPathComponent(relPath)
                guard fileManager.fileExists(atPath: src.path) else { continue }
                try copyReplacing(src: src, dst: dataURL.appendingPathComponent(relPath))
                includedPaths.insert(relPath)
            }

            try checkOperationCancellation()
            if try copyConsistentStateDatabase(from: root, to: dataURL) {
                includedPaths.insert("state_5.sqlite")
            }

            try checkOperationCancellation()
            let restorableIDs = try sanitizeSnapshotData(dataURL: dataURL, snapshotCodexRoot: codexRoot)
            var finalIncludedPaths = includedPaths
            try checkOperationCancellation()
            if try copyExternalAttachments(sessionIDs: restorableIDs, from: dataURL) {
                finalIncludedPaths.insert("external_attachments")
            }
            let counts = try snapshotSessionCounts(dataURL: dataURL, sessionIDs: restorableIDs)
            let state = inspectCurrentState()
            meta = SnapshotMeta(
                id: id,
                name: name,
                createdAt: now,
                codexRoot: codexRoot,
                reason: reason,
                kind: snapshotKind(for: reason),
                modelProvider: state.modelProvider,
                model: state.model,
                accountFingerprint: state.accountFingerprint,
                sessionCount: counts.active,
                archivedSessionCount: counts.archived,
                sizeBytes: directorySize(dataURL),
                includedPaths: finalIncludedPaths.sorted(),
                appVersion: appVersion
            )

            let encoded = try JSONEncoder.snapshot.encode(meta)
            try checkOperationCancellation()
            try LocalVaultPermissionHardener().hardenTree(at: snapshotURL)
            try DurableAtomicWriter().write(
                encoded,
                to: snapshotURL.appendingPathComponent(metadataFile),
                permissions: 0o600,
                parentDirectoryPermissions: 0o700,
                createParentDirectories: false
            )
        } catch {
            if snapshotCreated { try? fileManager.removeItem(at: snapshotURL) }
            throw error
        }
        try enforceAutomaticSnapshotRetention()
        return meta
    }

    private func validatedRestorePaths(for snapshot: SnapshotMeta) throws -> [ValidatedRestorePath] {
        let snapshotURL = try snapshotDirectoryURL(snapshot)
        let dataURL = snapshotURL.appendingPathComponent(dataDir, isDirectory: true)
        guard fileManager.fileExists(atPath: snapshotURL.path) else { throw VaultError.snapshotMissing }
        guard fileManager.fileExists(atPath: dataURL.path) else { throw VaultError.invalidSnapshot }

        let restorePaths = try RestorePathValidator.validate(
            snapshot.includedPaths,
            sourceRoot: dataURL,
            destinationRoot: URL(fileURLWithPath: codexRoot, isDirectory: true)
        )
        try RestoreFilesystemValidator.validate(
            restorePaths,
            sourceRoot: dataURL,
            destinationRoot: URL(fileURLWithPath: codexRoot, isDirectory: true)
        )
        return restorePaths
    }

    private func preflightSessionRestore(
        snapshot: SnapshotMeta,
        sessionIDs requestedSessionIDs: Set<String>? = nil,
        checkDatabaseConflicts: Bool = true,
        replaceIndexes: Bool = false
    ) throws -> SessionRestorePreflight {
        _ = try validatedRestorePaths(for: snapshot)
        let sourceRoot = try snapshotDataURL(snapshot)
        let destinationRoot = URL(fileURLWithPath: codexRoot, isDirectory: true)
        let sessionIDs: Set<String>
        if let requestedSessionIDs {
            sessionIDs = requestedSessionIDs
        } else {
            sessionIDs = Set(try loadSessions(in: snapshot).filter(\.existsOnDisk).map(\.id))
        }
        let sourceFiles = try TrustedSessionFileResolver.resolve(
            sessionIDs: sessionIDs,
            under: sourceRoot
        )
        let found = Set(sourceFiles.map(\.sessionID))
        let missing = sessionIDs.subtracting(found)
        guard missing.isEmpty else {
            throw VaultError.commandFailed("快照缺少可信会话文件：\(missing.sorted().joined(separator: ", "))")
        }

        var fingerprints = sourceFiles.map(\.fingerprint)
        var destinationFingerprints: [SessionFileFingerprint] = []
        var missingDestinationFiles: [SessionFileAbsenceExpectation] = []
        var lineMutations: [SessionRestoreLineMutation] = []
        let canonicalSourceRoot = sourceRoot.resolvingSymlinksInPath()
        for sourceFile in sourceFiles {
            guard let relative = relativePath(sourceFile.fileURL, under: canonicalSourceRoot) else {
                throw VaultError.commandFailed("可信会话文件越出快照目录：\(sourceFile.fileURL.path)")
            }
            let destination = destinationRoot.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: destination.path) {
                let fingerprint = try TrustedSessionFileResolver.validate(
                    destination,
                    expectedSessionID: sourceFile.sessionID,
                    under: destinationRoot
                )
                fingerprints.append(fingerprint)
                destinationFingerprints.append(fingerprint)
            } else {
                missingDestinationFiles.append(
                    try SessionFileAbsenceExpectation.requireMissing(destination)
                )
            }
        }
        for (name, kind) in [
            ("history.jsonl", SessionJSONLKind.history),
            ("history.jsonl.bak", SessionJSONLKind.historyBackup),
            ("session_index.jsonl", SessionJSONLKind.sessionIndex)
        ] {
            let source = sourceRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let sourceDocument = try SessionJSONLValidator.parse(source, kind: kind)
            fingerprints.append(sourceDocument.fingerprint)
            let destination = destinationRoot.appendingPathComponent(name)
            let destinationDocument: SessionJSONLDocument?
            if fileManager.fileExists(atPath: destination.path) {
                let document = try SessionJSONLValidator.parse(destination, kind: kind)
                destinationDocument = document
                let fingerprint = document.fingerprint
                fingerprints.append(fingerprint)
                destinationFingerprints.append(fingerprint)
            } else {
                destinationDocument = nil
                missingDestinationFiles.append(
                    try SessionFileAbsenceExpectation.requireMissing(destination)
                )
            }
            lineMutations.append(SessionRestoreLineMutation(
                destinationURL: destination,
                output: SessionJSONLRestoreOutput.build(
                    source: sourceDocument.records,
                    destination: destinationDocument?.records ?? [],
                    sessionIDs: sessionIDs,
                    uniqueBySessionID: kind == .sessionIndex,
                    replace: replaceIndexes
                )
            ))
        }
        if checkDatabaseConflicts,
           snapshot.includedPaths.contains("state_5.sqlite") {
            let sourceDatabase = sourceRoot.appendingPathComponent("state_5.sqlite")
            let destinationDatabase = destinationRoot.appendingPathComponent("state_5.sqlite")
            if fileManager.fileExists(atPath: sourceDatabase.path),
               fileManager.fileExists(atPath: destinationDatabase.path) {
                try RestoreFilesystemValidator.validateSource(sourceDatabase, under: sourceRoot)
                try RestoreFilesystemValidator.validateDestination(destinationDatabase, under: destinationRoot)
                _ = try StateDatabaseRestoreService().preflightMerge(
                    source: sourceDatabase,
                    destination: destinationDatabase,
                    sessionIDs: sessionIDs
                )
            }
        }
        return SessionRestorePreflight(
            sessionIDs: sessionIDs,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceFiles: sourceFiles,
            fingerprints: fingerprints,
            destinationFingerprints: destinationFingerprints,
            missingDestinationFiles: missingDestinationFiles,
            lineMutations: lineMutations
        )
    }

    private func publishSessionRestore(
        _ preflight: SessionRestorePreflight
    ) throws {
        try preflight.validateCurrent()
        let canonicalSourceRoot = preflight.sourceRoot.resolvingSymlinksInPath()
        for trusted in preflight.sourceFiles {
            try checkOperationCancellation()
            guard let relPath = relativePath(trusted.fileURL, under: canonicalSourceRoot) else {
                throw VaultError.commandFailed("可信会话文件越出快照目录：\(trusted.fileURL.path)")
            }
            let destination = preflight.destinationRoot.appendingPathComponent(relPath)
            try RestoreFilesystemValidator.validateSource(trusted.fileURL, under: canonicalSourceRoot)
            try RestoreFilesystemValidator.validateDestination(destination, under: preflight.destinationRoot)
            try preflight.validateDestinationCurrent(destination)
            let writeContents: (FileHandle) throws -> Void = { destinationHandle in
                let sourceHandle = try FileHandle(forReadingFrom: trusted.fileURL)
                defer { try? sourceHandle.close() }
                while let chunk = try sourceHandle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    try destinationHandle.write(contentsOf: chunk)
                }
            }
            let writer = DurableAtomicWriter()
            if preflight.destinationMustRemainMissing(destination) {
                try writer.writeIfAbsent(
                    at: destination,
                    permissions: 0o600,
                    createParentDirectories: true,
                    verifyTemporary: { temporary in
                        try trusted.fingerprint.validateContent(at: temporary)
                    },
                    writer: writeContents
                )
            } else {
                try writer.replace(
                    at: destination,
                    permissions: 0o600,
                    createParentDirectories: true,
                    verifyTemporary: { temporary in
                        try trusted.fingerprint.validateContent(at: temporary)
                    },
                    writer: writeContents
                )
            }
        }

        for mutation in preflight.lineMutations {
            try checkOperationCancellation()
            let destination = mutation.destinationURL
            try preflight.validateDestinationCurrent(destination)
            let destinationMustRemainMissing = preflight.destinationMustRemainMissing(destination)
            let writer = DurableAtomicWriter()
            if destinationMustRemainMissing {
                try writer.writeIfAbsent(
                    mutation.output,
                    to: destination,
                    permissions: 0o600,
                    createParentDirectories: true
                )
            } else {
                try writer.write(
                    mutation.output,
                    to: destination,
                    permissions: 0o600,
                    createParentDirectories: true
                )
            }
        }
    }

    private func rolloutPathUpdates(
        for preflight: SessionRestorePreflight
    ) throws -> [StateDatabaseRolloutPathUpdate] {
        let canonicalSourceRoot = preflight.sourceRoot.resolvingSymlinksInPath()
        return try preflight.sourceFiles.map { trusted in
            guard let relPath = relativePath(trusted.fileURL, under: canonicalSourceRoot) else {
                throw VaultError.commandFailed("可信会话文件越出快照目录：\(trusted.fileURL.path)")
            }
            return StateDatabaseRolloutPathUpdate(
                sessionID: trusted.sessionID,
                rolloutPath: preflight.destinationRoot.appendingPathComponent(relPath).path
            )
        }
    }

    private func restore(
        snapshot: SnapshotMeta,
        mode: RestoreMode,
        sessionPreflight: SessionRestorePreflight
    ) throws {
        try checkOperationCancellation()
        let dataURL = try snapshotDataURL(snapshot)
        let validatedPaths = try validatedRestorePaths(for: snapshot)

        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        switch mode {
        case .conversationsOnly:
            try checkOperationCancellation()
            try restoreConversationsOnly(
                from: dataURL,
                to: root,
                includedPaths: snapshot.includedPaths,
                snapshotCodexRoot: snapshot.codexRoot,
                attachmentSnapshotID: snapshot.id,
                sessionPreflight: sessionPreflight
            )
        case .full:
            try checkOperationCancellation()
            try restoreFull(
                from: dataURL,
                to: root,
                validatedPaths: validatedPaths,
                snapshotCodexRoot: snapshot.codexRoot,
                attachmentSnapshotID: snapshot.id,
                sessionPreflight: sessionPreflight
            )
        }
    }

    private func restoreFull(
        from dataURL: URL,
        to root: URL,
        validatedPaths: [ValidatedRestorePath],
        snapshotCodexRoot: String,
        attachmentSnapshotID: String,
        sessionPreflight: SessionRestorePreflight
    ) throws {
        try checkOperationCancellation()
        let included = Set(validatedPaths.map(\.relativePath))

        for restorePath in validatedPaths {
            try checkOperationCancellation()
            let relPath = restorePath.relativePath
            guard relPath != "external_attachments",
                  !stateDatabaseSnapshotPaths.contains(relPath),
                  !conversationLineMergePaths.contains(relPath),
                  relPath != "sessions",
                  relPath != "archived_sessions" else { continue }
            let src = restorePath.sourceURL
            let dst = restorePath.destinationURL
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try copyReplacing(src: src, dst: dst, sourceRoot: dataURL, destinationRoot: root)
        }

        try publishSessionRestore(sessionPreflight)

        guard included.contains("state_5.sqlite") else { return }

        try checkOperationCancellation()
        let restorableSessionIDs = sessionPreflight.sessionIDs
        let sourceDatabase = dataURL.appendingPathComponent("state_5.sqlite")
        let database = root.appendingPathComponent("state_5.sqlite")
        try RestoreFilesystemValidator.validateSource(sourceDatabase, under: dataURL)
        try RestoreFilesystemValidator.validateDestination(database, under: root)
        try StateDatabaseRestoreService().replace(
            source: sourceDatabase,
            destination: database,
            sessionIDs: restorableSessionIDs,
            rolloutPathUpdates: try rolloutPathUpdates(for: sessionPreflight)
        )
        try checkOperationCancellation()
        try restoreExternalAttachments(
            sessionIDs: restorableSessionIDs,
            from: dataURL,
            snapshotID: attachmentSnapshotID
        )
    }

    private func restoreConversationsOnly(
        from dataURL: URL,
        to root: URL,
        includedPaths: [String],
        snapshotCodexRoot: String,
        attachmentSnapshotID: String? = nil,
        sessionPreflight: SessionRestorePreflight
    ) throws {
        try checkOperationCancellation()
        let included = Set(includedPaths)
        let restorableSessionIDs: Set<String>? = included.contains("state_5.sqlite")
            ? sessionPreflight.sessionIDs
            : nil

        for relPath in conversationDirectoryPaths where included.contains(relPath) {
            if relPath == "sessions" || relPath == "archived_sessions" { continue }
            try checkOperationCancellation()
            let src = dataURL.appendingPathComponent(relPath)
            let dst = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try mergeDirectory(src: src, dst: dst, sourceRoot: dataURL, destinationRoot: root)
        }
        try publishSessionRestore(sessionPreflight)

        if included.contains("state_5.sqlite") {
            try checkOperationCancellation()
            let src = dataURL.appendingPathComponent("state_5.sqlite")
            let dst = root.appendingPathComponent("state_5.sqlite")
            if fileManager.fileExists(atPath: src.path) {
                try RestoreFilesystemValidator.validateSource(src, under: dataURL)
                try RestoreFilesystemValidator.validateDestination(dst, under: root)
                try StateDatabaseRestoreService().merge(
                    source: src,
                    destination: dst,
                    sessionIDs: restorableSessionIDs ?? [],
                    rolloutPathUpdates: try rolloutPathUpdates(for: sessionPreflight)
                )
                try checkOperationCancellation()
            }
        }
        try checkOperationCancellation()
        if let attachmentSnapshotID {
            try restoreExternalAttachments(
                sessionIDs: restorableSessionIDs,
                from: dataURL,
                snapshotID: attachmentSnapshotID
            )
        }
    }

    private func restoreSingleSession(
        snapshot: SnapshotMeta,
        preflight: SessionRestorePreflight
    ) throws {
        try restoreSessions(snapshot: snapshot, preflight: preflight)
    }

    private func restoreSessions(
        snapshot: SnapshotMeta,
        preflight: SessionRestorePreflight
    ) throws {
        try checkOperationCancellation()
        let dataURL = try snapshotDataURL(snapshot)
        guard fileManager.fileExists(atPath: dataURL.path) else { throw VaultError.invalidSnapshot }

        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try publishSessionRestore(preflight)

        let srcDB = dataURL.appendingPathComponent("state_5.sqlite")
        let dstDB = root.appendingPathComponent("state_5.sqlite")
        if fileManager.fileExists(atPath: srcDB.path) {
            try RestoreFilesystemValidator.validateSource(srcDB, under: dataURL)
            try RestoreFilesystemValidator.validateDestination(dstDB, under: root)
            try checkOperationCancellation()
            try StateDatabaseRestoreService().merge(
                source: srcDB,
                destination: dstDB,
                sessionIDs: preflight.sessionIDs,
                rolloutPathUpdates: try rolloutPathUpdates(for: preflight)
            )
        }
        try checkOperationCancellation()
        try restoreExternalAttachments(
            sessionIDs: preflight.sessionIDs,
            from: dataURL,
            snapshotID: snapshot.id
        )
    }

    private func relativePath(_ fileURL: URL, under root: URL) -> String? {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func autoRestoreLostConversationsOnLaunch() throws {
        try ensureDirectories()
        sessions = try loadSessions()
        snapshots = try loadSnapshots()

        let currentVisibleCount = sessions.count
        guard let latestSnapshot = latestAutoRestoreCandidate() else {
            if currentVisibleCount > 0 {
                let meta = try createSystemSnapshot(
                    name: "Auto Conversation Backup",
                    reason: "auto-protect",
                    candidatePaths: autoProtectionCandidates
                )
                refresh()
                selectedID = meta.id
                status = "已创建首次自动会话保护点：\(currentVisibleCount) 个会话"
            } else {
                status = "启动检查完成：暂无可恢复会话"
            }
            return
        }

        let snapshotCount = recoverableSessionCount(latestSnapshot)
        if snapshotCount > currentVisibleCount {
            let confirmed = confirm(
                title: "发现可找回的 Codex 会话，是否恢复？",
                message: """
                当前检测到 \(currentVisibleCount) 个会话，快照 “\(latestSnapshot.name)” 中有 \(snapshotCount) 个会话。

                选择继续后只会合并恢复对话，不会覆盖当前 auth.json、config.toml、账号登录态或模型供应商配置。
                """
            )
            guard confirmed else {
                status = "已取消自动找回：当前 \(currentVisibleCount) 个会话，快照 \(snapshotCount) 个会话"
                return
            }
            let sessionPreflight = try preflightSessionRestore(snapshot: latestSnapshot)
            _ = try createSystemSnapshot(
                name: "Pre-Auto-Restore Backup",
                reason: "pre-auto-restore",
                candidatePaths: autoProtectionCandidates
            )
            try restore(
                snapshot: latestSnapshot,
                mode: .conversationsOnly,
                sessionPreflight: sessionPreflight
            )
            refresh()
            selectedID = latestSnapshot.id
            selectedSection = .sessions
            status = "已自动找回会话：从 \(latestSnapshot.name) 合并恢复，保留当前账号和模型供应商配置"
        } else if currentVisibleCount > snapshotCount {
            let meta = try createSystemSnapshot(
                name: "Auto Conversation Backup",
                reason: "auto-protect",
                candidatePaths: autoProtectionCandidates
            )
            refresh()
            selectedID = meta.id
            status = "已更新自动会话保护点：\(currentVisibleCount) 个会话"
        } else {
            status = "启动检查完成：会话未丢失"
        }
    }

    private func latestAutoRestoreCandidate() -> SnapshotMeta? {
        snapshots
            .filter { snapshot in
                (snapshot.isManualSnapshot || snapshot.effectiveReason == "auto-protect")
                    && recoverableSessionCount(snapshot) > 0
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func latestSnapshotSession(matching sessionID: String) -> (snapshot: SnapshotMeta, session: CodexSession)? {
        let candidates = ((try? loadSnapshots()) ?? snapshots).sorted { $0.createdAt > $1.createdAt }

        for snapshot in candidates {
            guard let session = try? loadSessions(in: snapshot).first(where: { $0.id == sessionID }) else {
                continue
            }
            if session.existsOnDisk {
                return (snapshot, session)
            }
        }

        return nil
    }

    private func recoverableSessionCount(_ snapshot: SnapshotMeta) -> Int {
        let indexedCount = (try? loadSessions(in: snapshot).filter(\.existsOnDisk).count) ?? 0
        return indexedCount > 0 ? indexedCount : conversationTotal(snapshot)
    }

    private func conversationTotal(_ snapshot: SnapshotMeta) -> Int {
        snapshot.sessionCount + snapshot.archivedSessionCount
    }

    private func deleteSessionDatabaseRows(sessionID: String, root: URL) throws {
        let database = root.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return }

        var statements = [
            "PRAGMA foreign_keys = OFF;",
            "BEGIN IMMEDIATE;"
        ]
        if try sqliteTableExists(database: database, table: "thread_dynamic_tools") {
            statements.append("DELETE FROM thread_dynamic_tools WHERE thread_id = \(sqliteStringLiteral(sessionID));")
        }
        if try sqliteTableExists(database: database, table: "thread_goals") {
            statements.append("DELETE FROM thread_goals WHERE thread_id = \(sqliteStringLiteral(sessionID));")
        }
        if try sqliteTableExists(database: database, table: "thread_spawn_edges") {
            statements.append("DELETE FROM thread_spawn_edges WHERE parent_thread_id = \(sqliteStringLiteral(sessionID)) OR child_thread_id = \(sqliteStringLiteral(sessionID));")
        }
        if try sqliteTableExists(database: database, table: "stage1_outputs") {
            statements.append("DELETE FROM stage1_outputs WHERE thread_id = \(sqliteStringLiteral(sessionID));")
        }
        if try sqliteTableExists(database: database, table: "agent_job_items") {
            statements.append("DELETE FROM agent_job_items WHERE assigned_thread_id = \(sqliteStringLiteral(sessionID));")
        }
        if try sqliteTableExists(database: database, table: "threads") {
            statements.append("DELETE FROM threads WHERE id = \(sqliteStringLiteral(sessionID));")
        }
        statements.append(contentsOf: [
            "COMMIT;",
            "PRAGMA foreign_keys = ON;"
        ])
        let sql = statements.joined(separator: "\n")
        try runCommand(executable: "/usr/bin/sqlite3", arguments: [database.path, sql])
    }

    private func deleteAppDatabaseRows(sessionID: String, root: URL) throws {
        let database = root.appendingPathComponent("sqlite/codex-dev.db")
        guard fileManager.fileExists(atPath: database.path) else { return }

        let sql = """
        BEGIN IMMEDIATE;
        DELETE FROM automation_runs WHERE thread_id = \(sqliteStringLiteral(sessionID));
        DELETE FROM inbox_items WHERE thread_id = \(sqliteStringLiteral(sessionID));
        COMMIT;
        """
        try runCommand(executable: "/usr/bin/sqlite3", arguments: [database.path, sql])
    }

    private func restorableSessionIDs(from dataURL: URL) throws -> Set<String> {
        let database = dataURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return [] }

        let trustedRollouts = try TrustedSessionFileResolver.index(under: dataURL)
        let rows = try loadSessionRows(from: database)
        let ids = rows.compactMap { row -> String? in
            guard let normalizedID = SessionJSONLValidator.normalizeSessionID(row.id),
                  trustedRollouts[normalizedID]?.isEmpty == false else {
                return nil
            }
            return row.id
        }
        return Set(ids)
    }

    private func removeEmptyParents(startingAt url: URL, stopAt root: URL) throws {
        var current = url.standardizedFileURL
        let stop = root.standardizedFileURL.path

        while current.path.hasPrefix(stop), current.path != stop {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path),
                  contents.isEmpty else {
                return
            }
            try fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private func copyReplacing(
        src: URL,
        dst: URL,
        sourceRoot: URL? = nil,
        destinationRoot: URL? = nil
    ) throws {
        try checkOperationCancellation()
        if let sourceRoot, let destinationRoot {
            try RestoreFilesystemValidator.validateSource(src, under: sourceRoot, recursive: true)
            try RestoreFilesystemValidator.validateDestination(dst, under: destinationRoot, recursive: true)
        }
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: dst.path) {
            try fileManager.removeItem(at: dst)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: src.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try copyDirectoryContents(
                src: src,
                dst: dst,
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
        } else {
            if let sourceRoot, let destinationRoot {
                try RestoreFilesystemValidator.validateSource(src, under: sourceRoot)
                try RestoreFilesystemValidator.validateDestination(dst, under: destinationRoot)
            }
            try fileManager.copyItem(at: src, to: dst)
        }
        try checkOperationCancellation()
    }

    private func copyDirectoryContents(
        src: URL,
        dst: URL,
        sourceRoot: URL? = nil,
        destinationRoot: URL? = nil
    ) throws {
        try fileManager.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for case let itemURL as URL in enumerator {
            try checkOperationCancellation()
            let relPath = String(itemURL.path.dropFirst(src.path.count + 1))
            let targetURL = dst.appendingPathComponent(relPath)
            if let sourceRoot, let destinationRoot {
                try RestoreFilesystemValidator.validateSource(itemURL, under: sourceRoot)
                try RestoreFilesystemValidator.validateDestination(targetURL, under: destinationRoot)
            }
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: itemURL, to: targetURL)
            }
        }
    }

    private func mergeDirectory(
        src: URL,
        dst: URL,
        sourceRoot: URL? = nil,
        destinationRoot: URL? = nil
    ) throws {
        try checkOperationCancellation()
        if let sourceRoot, let destinationRoot {
            try RestoreFilesystemValidator.validateSource(src, under: sourceRoot, recursive: true)
            try RestoreFilesystemValidator.validateDestination(dst, under: destinationRoot, recursive: true)
        }
        if !fileManager.fileExists(atPath: dst.path) {
            try copyReplacing(
                src: src,
                dst: dst,
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for case let itemURL as URL in enumerator {
            try checkOperationCancellation()
            let relPath = String(itemURL.path.dropFirst(src.path.count + 1))
            let targetURL = dst.appendingPathComponent(relPath)
            if let sourceRoot, let destinationRoot {
                try RestoreFilesystemValidator.validateSource(itemURL, under: sourceRoot)
                try RestoreFilesystemValidator.validateDestination(targetURL, under: destinationRoot)
            }
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try copyReplacing(
                    src: itemURL,
                    dst: targetURL,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot
                )
            }
        }
    }

    private func writeFilteredLineFile(
        src: URL,
        dst: URL,
        uniqueKey: String?,
        allowedSessionIDs: Set<String>,
        destinationMustRemainMissing: Bool = false
    ) throws {
        try checkOperationCancellation()
        let source = try SessionJSONLValidator.parse(src, kind: sessionJSONLKind(for: dst))
        let allowed = Set(allowedSessionIDs.compactMap(SessionJSONLValidator.normalizeSessionID))
        var output = Data()
        var seen = Set<String>()

        for record in source.records {
            try checkOperationCancellation()
            guard allowed.contains(record.sessionID) else { continue }
            let identity = uniqueKey == nil ? record.rawData.base64EncodedString() : record.sessionID
            guard seen.insert(identity).inserted else { continue }
            output.append(record.rawData)
            output.append(0x0A)
        }

        let writer = DurableAtomicWriter()
        if destinationMustRemainMissing {
            try writer.writeIfAbsent(
                output,
                to: dst,
                permissions: 0o600,
                createParentDirectories: true
            )
        } else {
            try writer.write(
                output,
                to: dst,
                permissions: 0o600,
                createParentDirectories: true
            )
        }
    }

    private func sessionJSONLKind(for url: URL) -> SessionJSONLKind {
        switch url.lastPathComponent {
        case "session_index.jsonl": .sessionIndex
        case "history.jsonl.bak": .historyBackup
        default: .history
        }
    }

    private func parseCodexTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private func readLineData(_ url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        var lines: [Data] = []
        var line = Data()
        for byte in data {
            if byte == 0x0A {
                lines.append(line)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        lines.append(line)
        return lines
    }

    private func jsonLineIdentity(_ line: Data, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let value = object[key] else {
            return nil
        }
        return "\(key):\(value)"
    }

    private func updateThreadRolloutPath(database: URL, sessionID: String, rolloutPath: String, archived: Bool? = nil) throws {
        let archivedAssignment = archived.map { ", archived = \($0 ? 1 : 0)" } ?? ""
        let sql = """
        UPDATE threads
        SET rollout_path = \(sqliteStringLiteral(rolloutPath))\(archivedAssignment)
        WHERE id = \(sqliteStringLiteral(sessionID));
        """
        try runCommand(executable: "/usr/bin/sqlite3", arguments: [database.path, sql])
    }

    private func purgeAccountBindings(database: URL, sqlite: String) throws {
        var statements: [String] = []
        if try sqliteTableExists(database: database, table: "device_key_bindings") {
            statements.append("DELETE FROM device_key_bindings;")
        }
        if try sqliteTableExists(database: database, table: "remote_control_enrollments") {
            statements.append("DELETE FROM remote_control_enrollments;")
        }
        let sql = statements.joined(separator: "\n")
        guard !sql.isEmpty else { return }
        _ = try? runCommand(executable: sqlite, arguments: [database.path, sql])
    }

    private func pruneStateDatabase(database: URL, sqlite: String, allowedSessionIDs: Set<String>) throws {
        let existingTables = Set(try conversationStateTables.filter { try sqliteTableExists(database: database, table: $0) })
        if allowedSessionIDs.isEmpty {
            var statements = [
                "PRAGMA foreign_keys = OFF;",
                "BEGIN IMMEDIATE;"
            ]
            for table in conversationStateTables where existingTables.contains(table) {
                statements.append("DELETE FROM \(sqliteIdentifier(table));")
            }
            statements.append(contentsOf: [
                "COMMIT;",
                "PRAGMA foreign_keys = ON;"
            ])
            let sql = statements.joined(separator: "\n")
            try runCommand(executable: sqlite, arguments: [database.path, sql])
            return
        }

        let ids = allowedSessionIDs.map(sqliteStringLiteral).joined(separator: ", ")
        var statements = [
            "PRAGMA foreign_keys = OFF;",
            "BEGIN IMMEDIATE;"
        ]
        for table in conversationStateTables where existingTables.contains(table) {
            let whereClause = stateDatabasePruneWhereClause(table: table, ids: ids)
            statements.append("DELETE FROM \(sqliteIdentifier(table)) WHERE \(whereClause);")
        }
        statements.append(contentsOf: [
            "COMMIT;",
            "PRAGMA foreign_keys = ON;"
        ])
        let sql = statements.joined(separator: "\n")
        try runCommand(executable: sqlite, arguments: [database.path, sql])
    }

    private func stateDatabasePruneWhereClause(table: String, ids: String) -> String {
        switch table {
        case "thread_spawn_edges":
            return "parent_thread_id NOT IN (\(ids)) AND child_thread_id NOT IN (\(ids))"
        case "agent_job_items":
            return "assigned_thread_id IS NOT NULL AND assigned_thread_id NOT IN (\(ids))"
        case "threads":
            return "id NOT IN (\(ids))"
        default:
            return "thread_id NOT IN (\(ids))"
        }
    }

    private func sqliteTableExists(database: URL, table: String) throws -> Bool {
        !((try? sqliteTableColumns(database: database, table: table)) ?? []).isEmpty
    }

    private func sqliteTableColumns(database: URL, table: String) throws -> [String] {
        let output = try runCommand(
            executable: "/usr/bin/sqlite3",
            arguments: [database.path, "PRAGMA table_info(\(sqliteIdentifier(table)));"]
        )
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count > 1 else { return nil }
            return String(parts[1])
        }
    }

    @discardableResult
    private func runCommand(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("codex-session-manager-\(UUID().uuidString)-stdout")
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("codex-session-manager-\(UUID().uuidString)-stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            while process.isRunning {
                do {
                    try checkOperationCancellation()
                } catch {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.2)
                    if process.isRunning {
                        process.interrupt()
                    }
                    process.waitUntilExit()
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
        } catch {
            if case VaultError.operationCancelled = error {
                throw error
            }
            throw VaultError.commandFailed("命令执行失败：\(error.localizedDescription)")
        }

        try stdout.close()
        try stderr.close()
        let output = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        let errorOutput = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw VaultError.commandFailed(errorOutput.isEmpty ? "命令执行失败，退出码：\(process.terminationStatus)" : errorOutput)
        }
        return output
    }

    private func sqliteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func sqliteStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func existingBackupPaths(root: URL, candidates: [String]) -> [String] {
        candidates.filter { relPath in
            fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path)
        }
    }

    private func copyRolloutFiles(
        sessionIDs: Set<String>,
        from root: URL,
        to dataURL: URL,
        includedPaths: inout Set<String>
    ) throws {
        let trustedFiles = try TrustedSessionFileResolver.resolve(sessionIDs: sessionIDs, under: root)
        for trusted in trustedFiles {
            try checkOperationCancellation()
            guard let relPath = relativePath(trusted.fileURL, under: root) else { continue }
            try copyReplacing(src: trusted.fileURL, dst: dataURL.appendingPathComponent(relPath))
            includedPaths.insert(relPath.split(separator: "/").first.map(String.init) ?? "sessions")
        }
    }

    @discardableResult
    private func copyExternalAttachments(sessionIDs: Set<String>, from dataURL: URL) throws -> Bool {
        guard !sessionIDs.isEmpty else { return false }
        try checkOperationCancellation()
        let trustedRollouts = try TrustedSessionFileResolver.index(under: dataURL)
        var records: [ExternalAttachmentRestoreRecord] = []
        var seen = Set<String>()

        for sessionID in sessionIDs {
            try checkOperationCancellation()
            guard let normalizedID = SessionJSONLValidator.normalizeSessionID(sessionID),
                  let rolloutURL = trustedRollouts[normalizedID]?.first else {
                continue
            }
            let paths = try localAttachmentPaths(in: rolloutURL)
            for path in paths {
                try checkOperationCancellation()
                guard seen.insert(path).inserted else { continue }
                let src = URL(fileURLWithPath: path)
                guard fileManager.fileExists(atPath: src.path) else { continue }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: src.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }

                let storedRelativePath = "external_attachments/\(sessionID)/\(SHA256.hash(data: Data(path.utf8)).compactMap { String(format: "%02x", $0) }.joined())-\(src.lastPathComponent)"
                let dst = dataURL.appendingPathComponent(storedRelativePath)
                try copyReplacing(src: src, dst: dst)
                records.append(
                    ExternalAttachmentRestoreRecord(
                        sessionID: sessionID,
                        originalPath: path,
                        storedRelativePath: storedRelativePath,
                        sizeBytes: fileSize(src)
                    )
                )
            }
        }

        guard !records.isEmpty else { return false }
        let manifest = ExternalAttachmentManifest(records: records)
        let manifestURL = dataURL.appendingPathComponent("external_attachments/manifest.json")
        try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.snapshot.encode(manifest).write(to: manifestURL, options: .atomic)
        return true
    }

    private func validatedExternalAttachmentRestorePaths(
        sessionIDs: Set<String>?,
        from dataURL: URL,
        snapshotID: String
    ) throws -> [ValidatedExternalAttachmentRestore] {
        try checkOperationCancellation()
        let manifestURL = dataURL.appendingPathComponent("external_attachments/manifest.json")
        try RestoreFilesystemValidator.validateSource(
            manifestURL,
            under: dataURL,
            allowMissing: true
        )
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        try RestoreFilesystemValidator.validateSource(manifestURL, under: dataURL)
        let manifest = try JSONDecoder.snapshot.decode(
            ExternalAttachmentManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        let destinationRoot = try attachmentRecoveryRoot(snapshotID: snapshotID)
        let paths = try ExternalAttachmentRestoreValidator.validate(
            records: manifest.records,
            sourceRoot: dataURL,
            destinationRoot: destinationRoot,
            selectedSessionIDs: sessionIDs
        )
        for path in paths {
            try RestoreFilesystemValidator.validateSource(
                path.sourceURL,
                under: dataURL,
                allowMissing: true
            )
            try RestoreFilesystemValidator.validateDestination(
                path.destinationURL,
                under: destinationRoot
            )
        }
        return paths
    }

    private func preflightExternalAttachmentRestore(
        for snapshot: SnapshotMeta,
        sessionIDs: Set<String>?
    ) throws {
        let dataURL = try snapshotDataURL(snapshot)
        guard fileManager.fileExists(atPath: dataURL.path) else {
            throw VaultError.invalidSnapshot
        }
        _ = try validatedExternalAttachmentRestorePaths(
            sessionIDs: sessionIDs,
            from: dataURL,
            snapshotID: snapshot.id
        )
    }

    private func restoreExternalAttachments(
        sessionIDs: Set<String>?,
        from dataURL: URL,
        snapshotID: String
    ) throws {
        let paths = try validatedExternalAttachmentRestorePaths(
            sessionIDs: sessionIDs,
            from: dataURL,
            snapshotID: snapshotID
        )
        let destinationRoot = try attachmentRecoveryRoot(snapshotID: snapshotID)
        for path in paths {
            try checkOperationCancellation()
            guard fileManager.fileExists(atPath: path.sourceURL.path),
                  !fileManager.fileExists(atPath: path.destinationURL.path) else {
                continue
            }
            do {
                try RestoreFilesystemValidator.validateSource(path.sourceURL, under: dataURL)
                try RestoreFilesystemValidator.validateDestination(
                    path.destinationURL,
                    under: destinationRoot
                )
                try fileManager.createDirectory(
                    at: path.destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try RestoreFilesystemValidator.validateDestination(
                    path.destinationURL,
                    under: destinationRoot
                )
                try fileManager.copyItem(at: path.sourceURL, to: path.destinationURL)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
    }

    private func localAttachmentPaths(in rolloutURL: URL) throws -> Set<String> {
        try checkOperationCancellation()
        let lines = try readLineData(rolloutURL)
        var paths = Set<String>()

        for line in lines {
            try checkOperationCancellation()
            guard !line.isWhitespaceOrEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }
            if let images = payload["images"] as? [Any] {
                collectLocalAttachmentPaths(from: images, into: &paths)
            }
            if let localImages = payload["local_images"] as? [Any] {
                collectLocalAttachmentPaths(from: localImages, into: &paths)
            }
            if let textElements = payload["text_elements"] as? [Any] {
                collectLocalAttachmentPaths(from: textElements, into: &paths)
            }
            if let content = payload["content"] as? [Any] {
                collectInputAttachmentPaths(from: content, into: &paths)
            }
        }

        return paths
    }

    private func collectInputAttachmentPaths(from value: Any, into paths: inout Set<String>) {
        if let array = value as? [Any] {
            for item in array {
                collectInputAttachmentPaths(from: item, into: &paths)
            }
            return
        }

        guard let object = value as? [String: Any] else { return }
        let type = (object["type"] as? String ?? "").lowercased()
        guard ["input_image", "local_image", "input_file", "file", "attachment"].contains(type) else {
            return
        }
        collectLocalAttachmentPaths(from: object, into: &paths)
    }

    private func collectLocalAttachmentPaths(from value: Any, into paths: inout Set<String>) {
        if let text = value as? String {
            if isLocalAttachmentPath(text) {
                paths.insert(URL(fileURLWithPath: text).standardizedFileURL.path)
            }
            return
        }

        if let array = value as? [Any] {
            for item in array {
                collectLocalAttachmentPaths(from: item, into: &paths)
            }
            return
        }

        guard let object = value as? [String: Any] else { return }
        let type = (object["type"] as? String ?? "").lowercased()
        let attachmentLike = [
            "input_image",
            "local_image",
            "input_file",
            "file",
            "attachment"
        ].contains(type)

        for key in ["path", "file_path", "local_path", "image_path", "filename", "absolute_path"] {
            if let path = object[key] as? String,
               isLocalAttachmentPath(path),
               (attachmentLike || key != "filename" || path.hasPrefix("/")) {
                paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }

        for key in ["image_url", "url"] {
            if let path = object[key] as? String,
               path.hasPrefix("file://"),
               let url = URL(string: path) {
                paths.insert(url.standardizedFileURL.path)
            }
        }

        if attachmentLike {
            for nested in object.values {
                collectLocalAttachmentPaths(from: nested, into: &paths)
            }
        }
    }

    private func isLocalAttachmentPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        let lower = value.lowercased()
        let allowedExtensions = [
            ".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".heif", ".tiff", ".bmp",
            ".pdf", ".txt", ".md", ".csv", ".json", ".yaml", ".yml", ".doc", ".docx",
            ".xls", ".xlsx", ".ppt", ".pptx", ".zip"
        ]
        return allowedExtensions.contains { lower.hasSuffix($0) }
    }

    private var stateDatabaseSnapshotPaths: Set<String> {
        [
            "state_5.sqlite",
            "state_5.sqlite-shm",
            "state_5.sqlite-wal"
        ]
    }

    private func copyConsistentStateDatabase(from root: URL, to dataURL: URL) throws -> Bool {
        try checkOperationCancellation()
        let src = root.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: src.path) else { return false }

        let sqlite = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: sqlite) else { throw VaultError.sqliteUnavailable }

        let dst = dataURL.appendingPathComponent("state_5.sqlite")
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: dst.path) {
            try fileManager.removeItem(at: dst)
        }
        try checkOperationCancellation()
        try runCommand(executable: sqlite, arguments: [src.path, "VACUUM INTO \(sqliteStringLiteral(dst.path));"])
        try checkOperationCancellation()
        return true
    }

    @discardableResult
    private func sanitizeSnapshotData(dataURL: URL, snapshotCodexRoot: String) throws -> Set<String> {
        try checkOperationCancellation()
        let database = dataURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return [] }

        let restorableIDs = try restorableSessionIDs(from: dataURL)
        try checkOperationCancellation()
        try pruneStateDatabase(database: database, sqlite: "/usr/bin/sqlite3", allowedSessionIDs: restorableIDs)
        try checkOperationCancellation()
        try repairSnapshotStateDatabaseRolloutPaths(
            database: database,
            dataRoot: dataURL,
            snapshotCodexRoot: snapshotCodexRoot,
            sessionIDs: restorableIDs
        )

        for relPath in conversationLineMergePaths {
            try checkOperationCancellation()
            let fileURL = dataURL.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            try writeFilteredLineFile(
                src: fileURL,
                dst: fileURL,
                uniqueKey: relPath == "session_index.jsonl" ? "id" : nil,
                allowedSessionIDs: restorableIDs
            )
        }

        try removeStateDatabaseSidecars(from: dataURL)
        return restorableIDs
    }

    private func repairSnapshotStateDatabaseRolloutPaths(
        database: URL,
        dataRoot: URL,
        snapshotCodexRoot: String,
        sessionIDs: Set<String>
    ) throws {
        let root = URL(fileURLWithPath: snapshotCodexRoot, isDirectory: true)
        let trustedRollouts = try TrustedSessionFileResolver.index(under: dataRoot)
        for sessionID in sessionIDs {
            try checkOperationCancellation()
            guard let normalizedID = SessionJSONLValidator.normalizeSessionID(sessionID),
                  let rolloutURL = trustedRollouts[normalizedID]?.first,
                  let relPath = relativePath(rolloutURL, under: dataRoot) else {
                continue
            }
            let archived = relPath.hasPrefix("archived_sessions/")
            let snapshotRolloutPath = root.appendingPathComponent(relPath).path
            try updateThreadRolloutPath(
                database: database,
                sessionID: sessionID,
                rolloutPath: snapshotRolloutPath,
                archived: archived
            )
        }
    }

    private func snapshotSessionCounts(dataURL: URL, sessionIDs: Set<String>) throws -> (active: Int, archived: Int) {
        var active = 0
        var archived = 0
        let trustedRollouts = try TrustedSessionFileResolver.index(under: dataURL)

        for sessionID in sessionIDs {
            guard let normalizedID = SessionJSONLValidator.normalizeSessionID(sessionID),
                  let rolloutURL = trustedRollouts[normalizedID]?.first,
                  let relPath = relativePath(rolloutURL, under: dataURL) else {
                continue
            }
            if relPath.hasPrefix("archived_sessions/") {
                archived += 1
            } else {
                active += 1
            }
        }

        return (active, archived)
    }

    private func removeStateDatabaseSidecars(from dataURL: URL) throws {
        for relPath in ["state_5.sqlite-shm", "state_5.sqlite-wal"] {
            let url = dataURL.appendingPathComponent(relPath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func snapshotKind(for reason: String) -> String {
        reason == "manual" ? "manual" : "system"
    }

    private func enforceAutomaticSnapshotRetention(maxSystemSnapshots: Int = 24, maxAutoProtectSnapshots: Int = 3) throws {
        try checkOperationCancellation()
        try pruneSnapshots(
            (try loadSnapshots()).filter { $0.effectiveReason == "auto-protect" },
            keeping: maxAutoProtectSnapshots
        )
        try pruneSnapshots(
            (try loadSnapshots()).filter { !$0.isManualSnapshot },
            keeping: maxSystemSnapshots
        )
    }

    private func pruneSnapshots(_ targets: [SnapshotMeta], keeping limit: Int) throws {
        guard limit >= 0 else { return }
        let sorted = targets.sorted { $0.createdAt > $1.createdAt }
        let snapshotURLs = try sorted.dropFirst(limit).map(snapshotDirectoryURL)
        for url in snapshotURLs {
            try checkOperationCancellation()
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private var backupCandidates: [String] {
        [
            "config.toml",
            "auth.json",
            ".codex-global-state.json",
            ".codex-global-state.json.bak",
            "history.jsonl",
            "history.jsonl.bak",
            "session_index.jsonl",
            "sessions",
            "archived_sessions",
            "state_5.sqlite",
            "state_5.sqlite-shm",
            "state_5.sqlite-wal",
            "logs_2.sqlite",
            "logs_2.sqlite-shm",
            "logs_2.sqlite-wal",
            "sqlite",
            "shell_snapshots",
            "ambient-suggestions"
        ]
    }

    private var autoProtectionCandidates: [String] {
        [
            "history.jsonl",
            "history.jsonl.bak",
            "session_index.jsonl",
            "sessions",
            "archived_sessions",
            "state_5.sqlite",
            "shell_snapshots",
            "ambient-suggestions"
        ]
    }

    private var conversationDirectoryPaths: [String] {
        [
            "sessions",
            "archived_sessions",
            "shell_snapshots",
            "ambient-suggestions"
        ]
    }

    private var conversationLineMergePaths: [String] {
        [
            "history.jsonl",
            "history.jsonl.bak",
            "session_index.jsonl"
        ]
    }

    private var conversationStateTables: [String] {
        [
            "threads",
            "thread_goals",
            "thread_dynamic_tools",
            "thread_spawn_edges",
            "stage1_outputs",
            "agent_job_items"
        ]
    }

    private func defaultSnapshotName(reason: String, state: CurrentCodexState) -> String {
        switch reason {
        case "manual":
            return "手动快照 · \(state.modelProvider)/\(state.model)"
        case "auto-protect":
            return "自动会话保护点 · \(state.modelProvider)/\(state.model)"
        case "pre-restore":
            return "恢复前自动备份 · \(state.modelProvider)/\(state.model)"
        case "pre-auto-restore":
            return "自动找回前备份 · \(state.modelProvider)/\(state.model)"
        case "pre-delete-session":
            return "删除前自动备份 · \(state.modelProvider)/\(state.model)"
        case "pre-single-session-restore":
            return "单会话恢复前备份 · \(state.modelProvider)/\(state.model)"
        case "pre-batch-session-restore":
            return "批量会话恢复前备份 · \(state.modelProvider)/\(state.model)"
        default:
            return "Codex · \(state.modelProvider)/\(state.model)"
        }
    }

    private func parseTomlString(_ text: String, key: String) -> String? {
        let pattern = #"(?m)^\s*\#(key)\s*=\s*"([^"]*)"\s*$"#
            .replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func fingerprint(_ data: Data) -> String {
        guard !data.isEmpty else { return "none" }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private func countJSONLFiles(_ url: URL) -> Int {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return 0
        }
        var count = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            count += 1
        }
        return count
    }

    private func modifiedDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func timestampID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func chooseRestoreProtectionMode(
        title: String,
        message: String,
        defaultMode: RestoreProtectionMode
    ) -> RestoreProtectionMode? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = """
        \(message)

        恢复会改动 Codex 的会话文件、history.jsonl、session_index.jsonl 和 state_5.sqlite 线程记录。保护点用于恢复失败或选错快照时回退当前状态。

        轻量保护点只备份本次目标会话和相关索引，速度快，推荐日常单个/批量会话恢复。

        完整保护点会备份更完整的 Codex 状态，最稳妥，但如果 sessions 目录很大，创建时间会明显变长。
        """
        alert.alertStyle = .warning
        switch defaultMode {
        case .lightweight:
            alert.addButton(withTitle: "轻量保护点，推荐")
            alert.addButton(withTitle: "完整保护点")
        case .full:
            alert.addButton(withTitle: "完整保护点")
            alert.addButton(withTitle: "轻量保护点，推荐")
        }
        alert.addButton(withTitle: "取消恢复")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return defaultMode
        case .alertSecondButtonReturn:
            return defaultMode == .lightweight ? .full : .lightweight
        default:
            return nil
        }
    }

    private func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func checkOperationCancellation() throws {
        guard let operationCancellationURL else { return }
        if fileManager.fileExists(atPath: operationCancellationURL.path) {
            throw VaultError.operationCancelled
        }
    }

    fileprivate func performWorkerCommand(
        _ command: VaultWorkerCommand,
        progress: (VaultWorkerProgress) throws -> Void = { _ in }
    ) throws -> VaultWorkerResponse {
        try ensureVaultPrepared()

        func checkCancellation() throws {
            guard let cancellationPath = command.cancellationPath else { return }
            if FileManager.default.fileExists(atPath: cancellationPath) {
                throw VaultError.operationCancelled
            }
        }

        func report(_ fraction: Double, _ message: String, _ detail: String? = nil) throws {
            try checkCancellation()
            try progress(VaultWorkerProgress(fraction: fraction, message: message, detail: detail))
        }

        func selectedProtectionMode(default defaultMode: RestoreProtectionMode) -> RestoreProtectionMode {
            command.protectionMode ?? defaultMode
        }

        func attachmentRestoreNote(for snapshot: SnapshotMeta) throws -> String {
            let root = try attachmentRecoveryRoot(snapshotID: snapshot.id)
            return "外部附件（如有）已安全恢复到 \(root.path)，未写回原绝对路径。"
        }

        func reportProtectionStart(
            fraction: Double,
            mode: RestoreProtectionMode,
            title: String
        ) throws {
            switch mode {
            case .lightweight:
                try report(fraction, title, "正在创建轻量保护点：只备份本次目标会话和相关索引，不复制整个 sessions 目录。")
            case .full:
                try report(fraction, title, "正在创建完整保护点：会复制更完整的 Codex 状态，sessions 目录较大时会较慢。")
            }
        }

        func createRestoreProtection(
            name: String,
            reason: String,
            mode: RestoreProtectionMode,
            sessions: [CodexSession],
            fullCandidatePaths: [String],
            lightweightExtraPaths: [String] = []
        ) throws {
            try checkCancellation()
            switch mode {
            case .lightweight:
                guard !sessions.isEmpty else {
                    _ = try createSystemSnapshot(
                        name: name,
                        reason: reason,
                        candidatePaths: fullCandidatePaths
                    )
                    return
                }
                _ = try createSessionProtectionSnapshot(
                    name: name,
                    reason: reason,
                    sessions: sessions,
                    extraCandidatePaths: lightweightExtraPaths
                )
            case .full:
                _ = try createSystemSnapshot(
                    name: name,
                    reason: reason,
                    candidatePaths: fullCandidatePaths
                )
            }
            try checkCancellation()
        }

        try report(0.02, "准备后台任务...", "正在初始化恢复任务。")

        switch command.operation {
        case .createManualSnapshot:
            try report(0.08, "正在创建快照...", "正在扫描 Codex 数据目录。")
            let meta = try createSnapshot(name: command.snapshotName, reason: "manual")
            try report(1.0, "快照已创建：\(meta.name)", "已完成快照写入和索引校验。")
            return .ok(message: "快照已创建：\(meta.name)", snapshot: meta)

        case .restoreSnapshot:
            guard let snapshot = command.snapshot,
                  let mode = command.restoreMode else {
                throw VaultError.invalidSnapshot
            }
            _ = try validatedRestorePaths(for: snapshot)
            let sessionPreflight = try preflightSessionRestore(
                snapshot: snapshot,
                checkDatabaseConflicts: mode != .full,
                replaceIndexes: mode == .full
            )
            try preflightExternalAttachmentRestore(for: snapshot, sessionIDs: nil)
            let protectionMode = selectedProtectionMode(default: mode == .full ? .full : .lightweight)
            let protectionSessions: [CodexSession]
            if mode == .full && protectionMode == .lightweight {
                protectionSessions = (try? loadSessions().filter(\.existsOnDisk)) ?? []
            } else {
                protectionSessions = (try? loadSessions(in: snapshot).filter(\.existsOnDisk)) ?? []
            }
            let extraPaths = mode == .full
                ? ["config.toml", "auth.json", ".codex-global-state.json", ".codex-global-state.json.bak"]
                : []
            try reportProtectionStart(
                fraction: 0.08,
                mode: protectionMode,
                title: protectionMode == .lightweight ? "正在创建轻量恢复前保护点..." : "正在创建完整恢复前保护点..."
            )
            try createRestoreProtection(
                name: protectionMode == .lightweight ? "Pre-Restore Lightweight Backup" : "Pre-Restore Backup",
                reason: protectionMode == .lightweight ? "pre-restore-lightweight" : "pre-restore",
                mode: protectionMode,
                sessions: protectionSessions,
                fullCandidatePaths: backupCandidates,
                lightweightExtraPaths: extraPaths
            )
            try report(0.45, "正在恢复快照...", "正在复制快照内容并合并 Codex 索引。")
            try checkCancellation()
            try restore(snapshot: snapshot, mode: mode, sessionPreflight: sessionPreflight)
            let attachmentNote = try attachmentRestoreNote(for: snapshot)
            try report(1.0, "恢复完成", "\(mode.successMessage) \(attachmentNote)")
            return .ok(message: "\(snapshot.name)：\(mode.successMessage) \(attachmentNote)")

        case .restoreSnapshotSession:
            guard let snapshot = command.snapshot,
                  let session = command.sessions.first else {
                throw VaultError.invalidSnapshot
            }
            _ = try validatedRestorePaths(for: snapshot)
            let sessionPreflight = try preflightSessionRestore(
                snapshot: snapshot,
                sessionIDs: [session.id]
            )
            try preflightExternalAttachmentRestore(for: snapshot, sessionIDs: [session.id])
            let protectionMode = selectedProtectionMode(default: .lightweight)
            try reportProtectionStart(
                fraction: 0.12,
                mode: protectionMode,
                title: protectionMode == .lightweight ? "正在创建轻量恢复点..." : "正在创建完整恢复点..."
            )
            try createRestoreProtection(
                name: "Pre-Single-Session Restore Backup",
                reason: "pre-single-session-restore",
                mode: protectionMode,
                sessions: [session],
                fullCandidatePaths: autoProtectionCandidates
            )
            try report(0.55, "正在恢复会话：\(session.displayTitle)", "正在复制会话文件、附件并合并历史索引。")
            try checkCancellation()
            try restoreSingleSession(snapshot: snapshot, preflight: sessionPreflight)
            let attachmentNote = try attachmentRestoreNote(for: snapshot)
            try report(1.0, "恢复完成：\(session.displayTitle)", "会话文件、历史索引和线程记录已合并。\(attachmentNote)")
            return .ok(message: "已恢复单个会话：\(session.displayTitle)。\(attachmentNote)")

        case .restoreSnapshotSessions:
            guard let snapshot = command.snapshot,
                  !command.sessions.isEmpty else {
                throw VaultError.invalidSnapshot
            }
            _ = try validatedRestorePaths(for: snapshot)
            let selectedSessionIDs = Set(command.sessions.map(\.id))
            let sessionPreflight = try preflightSessionRestore(
                snapshot: snapshot,
                sessionIDs: selectedSessionIDs
            )
            try preflightExternalAttachmentRestore(
                for: snapshot,
                sessionIDs: selectedSessionIDs
            )
            let protectionMode = selectedProtectionMode(default: .lightweight)
            try reportProtectionStart(
                fraction: 0.08,
                mode: protectionMode,
                title: protectionMode == .lightweight ? "正在创建批量轻量恢复点..." : "正在创建批量完整恢复点..."
            )
            try createRestoreProtection(
                name: "Pre-Batch-Session Restore Backup",
                reason: "pre-batch-session-restore",
                mode: protectionMode,
                sessions: command.sessions,
                fullCandidatePaths: autoProtectionCandidates
            )
            try report(0.35, "正在批量恢复 \(command.sessions.count) 个会话...", "正在原子发布会话文件并在单个事务中合并 Codex 本地索引。")
            try checkCancellation()
            try restoreSessions(
                snapshot: snapshot,
                preflight: sessionPreflight
            )
            let attachmentNote = try attachmentRestoreNote(for: snapshot)
            try report(1.0, "批量恢复完成", "已恢复 \(command.sessions.count) 个会话。\(attachmentNote)")
            return .ok(message: "已从 \(snapshot.name) 批量恢复 \(command.sessions.count) 个会话。\(attachmentNote)")

        case .restoreIncrementalBackupSessions:
            let requestedIDs = Set(command.sessions.map(\.id))
            guard !requestedIDs.isEmpty else {
                throw VaultError.commandFailed("没有选择要从 NAS 恢复的会话。")
            }
            guard let recoverySource = command.incrementalRecoverySource else {
                throw VaultError.commandFailed("缺少 NAS 恢复设备身份。")
            }
            let vaultURL = URL(fileURLWithPath: command.vaultRoot, isDirectory: true)
            let service = NASConfigurationService(
                store: NASConfigurationStore(
                    fileURL: vaultURL.appendingPathComponent("nas-backup-settings.json")
                ),
                localStateRoot: vaultURL.appendingPathComponent("nas-state", isDirectory: true)
            )
            let target = try service.resolveRecoveryTarget(recoverySource)
            let paths = BackupPaths(
                codexRoot: URL(fileURLWithPath: command.codexRoot, isDirectory: true),
                backupRoot: target.backupRoot,
                stateRoot: target.localStateRoot
            )
            let currentIDs = Set((try? loadSessions().map(\.id)) ?? [])
            let restorer = IncrementalRecoveryRestorer(paths: paths)
            let plan = try restorer.preflight(
                sessionIDs: Array(requestedIDs),
                currentSessionIDs: currentIDs
            )
            guard !plan.items.isEmpty else { throw VaultError.commandFailed("选中的 NAS 会话都已存在。") }
            let destinationRoot = URL(fileURLWithPath: command.codexRoot, isDirectory: true)

            let protectionMode = selectedProtectionMode(default: .lightweight)
            try reportProtectionStart(
                fraction: 0.08,
                mode: protectionMode,
                title: protectionMode == .lightweight ? "正在创建备份恢复前轻量保护点..." : "正在创建备份恢复前完整保护点..."
            )
            switch protectionMode {
            case .lightweight:
                _ = try createSystemSnapshot(
                    name: "Pre-Incremental-Backup-Restore Lightweight Backup",
                    reason: "pre-incremental-backup-restore-lightweight",
                    candidatePaths: autoProtectionCandidates
                )
            case .full:
                _ = try createSystemSnapshot(
                    name: "Pre-Incremental-Backup-Restore Backup",
                    reason: "pre-incremental-backup-restore",
                    candidatePaths: backupCandidates
                )
            }

            try report(0.60, "正在恢复 NAS 缺失会话...", "正在直接原子写入 recovered 会话并合并 session_index.jsonl。")
            let result = try restorer.restore(plan, to: destinationRoot)
            let manifest = try BackupManifestStore(
                manifestURL: paths.manifestURL,
                createParentDirectories: false
            ).loadOrCreate(codexRoot: paths.codexRoot.path, backupRoot: paths.backupRoot.path)
            let threadEntries = try result.threadRecords.compactMap { thread -> RecoveredThreadIndexEntry? in
                guard let record = manifest.sessions[thread.sessionID] else { return nil }
                return try makeRecoveredThreadIndexEntry(
                    record: record,
                    recoveredURL: URL(fileURLWithPath: thread.rolloutPath),
                    codexRoot: destinationRoot
                )
            }
            let indexResult: RecoveredThreadIndexResult
            do {
                indexResult = try RecoveredThreadIndexWriter().ensureThreads(
                    entries: threadEntries,
                    databaseURL: destinationRoot.appendingPathComponent("state_5.sqlite")
                )
            } catch {
                indexResult = RecoveredThreadIndexResult(
                    insertedCount: 0,
                    skippedCount: 0,
                    warning: "SQLite 索引未写入：\(error.localizedDescription)"
                )
            }
            try report(1.0, "NAS 恢复完成", "已恢复 \(result.restoredSessionIDs.count) 个缺失会话。\(indexResult.message)")
            return .ok(message: "已从公司 NAS 恢复 \(result.restoredSessionIDs.count) 个缺失会话。\(indexResult.message) 请重启 Codex 后查看。")

        case .deleteSnapshots:
            let snapshotURLs = try command.snapshots.map(snapshotDirectoryURL)
            let total = max(command.snapshots.count, 1)
            for (index, pair) in zip(command.snapshots, snapshotURLs).enumerated() {
                let (snapshot, url) = pair
                try checkCancellation()
                try report(
                    0.05 + (0.90 * Double(index) / Double(total)),
                    "正在删除快照 \(index + 1)/\(total)...",
                    snapshot.name
                )
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
            try report(1.0, "快照删除完成", "已删除 \(command.snapshots.count) 个快照。")
            return .ok(message: "已删除 \(command.snapshots.count) 个快照")

        case .deleteSessions:
            guard !command.sessions.isEmpty else {
                throw VaultError.commandFailed("没有可删除的会话。")
            }
            let deletionRoot = URL(fileURLWithPath: codexRoot, isDirectory: true)
            let deletionPlan = try SessionDeletionPlan.preflight(
                sessionIDs: Set(command.sessions.map(\.id)),
                codexRoot: deletionRoot
            )
            try report(0.08, "正在创建删除前恢复点...", "只保存即将删除的会话。")
            _ = try createSessionProtectionSnapshot(
                name: command.sessions.count == 1 ? "Pre-Delete Session Backup" : "Pre-Delete Sessions Backup",
                reason: "pre-delete-session",
                sessions: command.sessions
            )
            let deletionWarning = try deletionPlan.commit()
            let total = max(command.sessions.count, 1)
            for (index, session) in command.sessions.enumerated() {
                try checkCancellation()
                try report(
                    0.25 + (0.70 * Double(index) / Double(total)),
                    "正在删除会话 \(index + 1)/\(total)：\(session.displayTitle)",
                    "正在清理会话文件、history.jsonl、session_index.jsonl 和 SQLite 线程记录。"
                )
                try deleteSessionDatabaseRows(sessionID: session.id, root: deletionRoot)
                try deleteAppDatabaseRows(sessionID: session.id, root: deletionRoot)
            }
            let warningSuffix = deletionWarning.map { " \($0)" } ?? ""
            try report(1.0, "会话删除完成", "已删除 \(command.sessions.count) 个会话。\(warningSuffix)")
            return .ok(message: "已删除 \(command.sessions.count) 个会话。\(warningSuffix)")

        case .createAutoProtectionSnapshot:
            let sessions = try loadSessions()
            try report(0.10, "正在创建自动会话保护点...", "正在备份当前可恢复会话。")
            let meta = try createSystemSnapshot(
                name: "Auto Conversation Backup",
                reason: "auto-protect",
                candidatePaths: autoProtectionCandidates
            )
            try report(1.0, "自动会话保护点已更新", "已记录 \(sessions.count) 个会话。")
            return .ok(message: "已更新自动会话保护点：\(sessions.count) 个会话", snapshot: meta)

        case .autoRestoreSnapshot:
            guard let snapshot = command.snapshot else {
                throw VaultError.invalidSnapshot
            }
            _ = try validatedRestorePaths(for: snapshot)
            let sessionPreflight = try preflightSessionRestore(snapshot: snapshot)
            try preflightExternalAttachmentRestore(for: snapshot, sessionIDs: nil)
            try report(0.08, "正在创建自动找回前备份...", "正在保护当前 Codex 会话状态。")
            _ = try createSystemSnapshot(
                name: "Pre-Auto-Restore Backup",
                reason: "pre-auto-restore",
                candidatePaths: autoProtectionCandidates
            )
            try report(0.50, "正在自动找回会话...", "正在合并快照里的会话文件和索引。")
            try checkCancellation()
            try restore(
                snapshot: snapshot,
                mode: .conversationsOnly,
                sessionPreflight: sessionPreflight
            )
            let attachmentNote = try attachmentRestoreNote(for: snapshot)
            try report(1.0, "自动找回完成", "已从 \(snapshot.name) 合并恢复。\(attachmentNote)")
            return .ok(message: "已自动找回会话：从 \(snapshot.name) 合并恢复，保留当前账号和模型供应商配置。\(attachmentNote)")
        }
    }
}

extension JSONDecoder {
    static var snapshot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var snapshot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension Data {
    var isWhitespaceOrEmpty: Bool {
        allSatisfy { byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
        }
    }
}

private enum VaultWorkerProcess {
    static func run(
        _ command: VaultWorkerCommand,
        onProgress: @escaping @MainActor (VaultWorkerProgress) -> Void
    ) async throws -> VaultWorkerResponse {
        try await Task.detached(priority: .userInitiated) {
            let requestURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-session-vault-worker-\(UUID().uuidString)-request.json")
            let responseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-session-vault-worker-\(UUID().uuidString)-response.json")
            let progressURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-session-vault-worker-\(UUID().uuidString)-progress.json")
            defer {
                try? FileManager.default.removeItem(at: requestURL)
                try? FileManager.default.removeItem(at: responseURL)
                try? FileManager.default.removeItem(at: progressURL)
            }

            let requestData = try JSONEncoder.snapshot.encode(command)
            try requestData.write(to: requestURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--worker", requestURL.path, responseURL.path, progressURL.path]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdoutReader = stdoutPipe.fileHandleForReading
            let stderrReader = stderrPipe.fileHandleForReading
            defer {
                try? stdoutReader.close()
                try? stderrReader.close()
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            var lastProgressSignature = ""
            while process.isRunning {
                if let cancellationPath = command.cancellationPath,
                   FileManager.default.fileExists(atPath: cancellationPath) {
                    process.terminate()
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if process.isRunning {
                        process.interrupt()
                    }
                    break
                }
                if let progress = readProgress(progressURL, lastSignature: &lastProgressSignature) {
                    await MainActor.run {
                        onProgress(progress)
                    }
                }
                try await Task.sleep(nanoseconds: 120_000_000)
            }
            process.waitUntilExit()

            if let progress = readProgress(progressURL, lastSignature: &lastProgressSignature) {
                await MainActor.run {
                    onProgress(progress)
                }
            }

            let stderr = String(decoding: stderrReader.readDataToEndOfFile(), as: UTF8.self)
            _ = stdoutReader.readDataToEndOfFile()

            if let cancellationPath = command.cancellationPath,
               FileManager.default.fileExists(atPath: cancellationPath) {
                throw VaultError.operationCancelled
            }

            guard process.terminationStatus == 0 else {
                throw VaultError.commandFailed(stderr.isEmpty ? "后台任务失败，退出码：\(process.terminationStatus)" : stderr)
            }

            let data = try Data(contentsOf: responseURL)
            return try JSONDecoder.snapshot.decode(VaultWorkerResponse.self, from: data)
        }.value
    }

    private static func readProgress(_ url: URL, lastSignature: inout String) -> VaultWorkerProgress? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let signature = data.base64EncodedString()
        guard signature != lastSignature else { return nil }
        lastSignature = signature
        return try? JSONDecoder.snapshot.decode(VaultWorkerProgress.self, from: data)
    }

    @MainActor
    static func runFromCommandLine(arguments: [String]) -> Bool {
        guard arguments.count >= 2, arguments[1] == "--worker" else { return false }
        guard arguments.count == 5 else {
            fputs("worker 参数错误\n", stderr)
            Foundation.exit(64)
        }

        let requestURL = URL(fileURLWithPath: arguments[2])
        let responseURL = URL(fileURLWithPath: arguments[3])
        let progressURL = URL(fileURLWithPath: arguments[4])

        do {
            let command = try JSONDecoder.snapshot.decode(
                VaultWorkerCommand.self,
                from: Data(contentsOf: requestURL)
            )
            let model = VaultModel(
                codexRoot: command.codexRoot,
                vaultRoot: command.vaultRoot,
                refreshOnInit: false
            )
            if let cancellationPath = command.cancellationPath {
                model.operationCancellationURL = URL(fileURLWithPath: cancellationPath)
            }
            let response = try model.performWorkerCommand(command) { progress in
                try JSONEncoder.snapshot.encode(progress).write(to: progressURL, options: .atomic)
            }
            try JSONEncoder.snapshot.encode(response).write(to: responseURL, options: .atomic)
            Foundation.exit(0)
        } catch {
            let response = VaultWorkerResponse.failed(error.localizedDescription)
            try? JSONEncoder.snapshot.encode(response).write(to: responseURL, options: .atomic)
            fputs(error.localizedDescription + "\n", stderr)
            Foundation.exit(1)
        }
    }
}

@main
struct CodexSessionVaultApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @StateObject private var model: VaultModel
    @StateObject private var updateCoordinator: MacUpdateCoordinator

    init() {
        _ = VaultWorkerProcess.runFromCommandLine(arguments: CommandLine.arguments)
        let model = VaultModel(refreshOnInit: CommandLine.arguments.dropFirst().first != "--worker")
        _model = StateObject(wrappedValue: model)
        _updateCoordinator = StateObject(wrappedValue: MacUpdateCoordinator(model: model))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(updateCoordinator)
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear { appDelegate.model = model }
                .sheet(
                    isPresented: Binding(
                        get: { updateCoordinator.isPresented },
                        set: { presented in
                            if !presented { updateCoordinator.remindLater() }
                        }
                    )
                ) {
                    UpdatePromptView()
                        .environmentObject(updateCoordinator)
                }
                .task { updateCoordinator.start() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("创建快照") { model.createManualSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command])
                Divider()
                Button("检查更新…") { updateCoordinator.checkNow() }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: VaultModel

    private var sectionBinding: Binding<AppSection> {
        Binding(
            get: { model.selectedSection ?? .sessions },
            set: { model.selectedSection = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
        } detail: {
            ZStack {
                auroraBackground

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spark Workspace")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 0.31, green: 0.43, blue: 0.67))
                            Picker("功能", selection: sectionBinding) {
                                ForEach(AppSection.allCases) { section in
                                    Text(section.rawValue).tag(section)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("打开时自动找回")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.18, green: 0.26, blue: 0.44))
                                Text("默认关闭，仅在需要自动补回丢失对话时开启")
                                    .font(.caption2)
                                    .foregroundStyle(Color(red: 0.42, green: 0.50, blue: 0.66))
                            }
                            Toggle("", isOn: $model.autoRestoreOnLaunch)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .help("启动 app 时自动从最新会话保护点找回丢失的对话，不覆盖账号和模型供应商配置")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.52))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(0.82), lineWidth: 1)
                        )
                        .shadow(color: Color(red: 0.18, green: 0.37, blue: 0.74).opacity(0.08), radius: 18, x: 0, y: 10)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 16)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.95),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)

                    switch model.selectedSection ?? .sessions {
                    case .sessions:
                        SessionsPane()
                    case .snapshots:
                        SnapshotPane()
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.showEmployeeHelp()
                } label: {
                    Label("使用帮助", systemImage: "questionmark.circle")
                }
                Button {
                    model.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                    .disabled(model.isBusy)
                Menu {
                    Button("打开 Codex 数据目录") { model.openCodexRoot() }
                    Button("打开快照库目录") { model.openVaultRoot() }
                } label: {
                    Text("打开目录")
                }
            }
        }
        .overlay(alignment: .bottom) {
            StatusBar()
        }
        .overlay {
            if model.isBusy {
                BusyOverlay(
                    status: model.status,
                    progress: model.busyProgress,
                    detailOverride: model.busyDetail,
                    canCancel: model.canCancelBusyOperation,
                    isCancelling: model.isCancellationRequested,
                    onCancel: { model.cancelBusyOperation() }
                )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.isBusy)
        .sheet(
            isPresented: $model.isConversationViewerPresented,
            onDismiss: { model.dismissConversationViewer() }
        ) {
            if let session = model.conversationViewerSession {
                ConversationViewer(session: session, messages: model.conversationMessages)
                    .environmentObject(model)
                    .frame(minWidth: 760, minHeight: 620)
            } else {
                ContentUnavailableView("没有会话内容", systemImage: "bubble.left")
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
        .sheet(isPresented: $model.isNASSetupPresented) {
            NASSetupView()
                .environmentObject(model)
                .interactiveDismissDisabled(
                    model.onboardingDecision.preventDismissal
                        && !model.isManualNASReconfiguration
                )
        }
        .sheet(isPresented: $model.isEmployeeHelpPresented) {
            EmployeeHelpView(
                version: model.displayAppVersion,
                retryNAS: { model.retryNASBackup() },
                reconfigure: { model.reconfigureFromHelp() },
                openRecovery: { model.openRecoveryFromHelp() }
            )
            .frame(minWidth: 620, minHeight: 520)
        }
        .onAppear {
            model.clearSessionSearch()
            model.runLaunchAutoRestoreIfNeeded()
        }
    }

    private var auroraBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.985, blue: 1.0),
                    Color(red: 0.92, green: 0.96, blue: 1.0),
                    Color(red: 0.92, green: 0.99, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color(red: 0.24, green: 0.59, blue: 1.0).opacity(0.16),
                    .clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    Color(red: 0.27, green: 0.91, blue: 0.78).opacity(0.12),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: VaultModel? {
        didSet {
            if pendingActivation, let model {
                pendingActivation = false
                model.requestNASBackupScan(.activation)
            }
            if pendingWake, let model {
                pendingWake = false
                model.requestNASBackupScan(.wake)
            }
        }
    }
    private var observesWorkspaceWake = false
    private var pendingActivation = false
    private var pendingWake = false
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = NSAppleEventManager.shared()
            .currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?
            .booleanValue ?? false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !observesWorkspaceWake else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        observesWorkspaceWake = true
        if launchedAsLoginItem {
            DispatchQueue.main.async {
                NSApp.hide(nil)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else {
            pendingActivation = true
            return
        }
        model.requestNASBackupScan(.activation)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        guard let model else {
            pendingWake = true
            return
        }
        model.requestNASBackupScan(.wake)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model,
              model.nasSetupSnapshot.state == .seeding
                || model.nasSetupSnapshot.state == .pending
                || model.nasSetupSnapshot.state == .verifying else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "NAS 备份尚未完成，仍要退出吗？"
        alert.informativeText = "仍有会话正在建立初始备份、等待补传或执行回读校验。退出不会创建本地会话缓存，下次连接 NAS 后会继续。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeWorkspaceObservers()
        model?.stopNASBackup()
    }

    private func removeWorkspaceObservers() {
        guard observesWorkspaceWake else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        observesWorkspaceWake = false
    }
}

struct NASSetupView: View {
    @EnvironmentObject private var model: VaultModel

    private var isBackupBusy: Bool {
        [.validating, .seeding, .verifying].contains(model.nasSetupSnapshot.state)
    }

    private var diagnosticDetail: String? {
        let detail = model.nasSetupSnapshot.lastError ?? model.lastError
        guard let detail, !detail.isEmpty else { return nil }
        return detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.isManualNASReconfiguration ? "更换 NAS 备份身份" : "配置公司 NAS 备份")
                        .font(.title2.bold())
                    Text("只需选择部门和姓名，软件会验证固定服务器、共享盘和目标目录。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isManualNASReconfiguration {
                    Button("关闭") { model.dismissNASSetup() }
                }
            }

            EmployeeOnboardingStepsView(currentStep: model.onboardingDecision.step)

            EmployeeStateCard(snapshot: model.nasSetupSnapshot)

            DisclosureGroup("如何连接 NAS") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 在 Finder 中选择“前往”→“连接服务器”。")
                    Text("2. 输入 smb://192.168.10.99，并连接“文件中转站”。")
                    Text("3. 返回本软件，点击“重新检测 NAS”。")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }

            if let diagnosticDetail {
                DisclosureGroup("查看错误详情") {
                    Text(diagnosticDetail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }

            GroupBox("备份身份") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("部门", selection: $model.selectedNASDepartment) {
                        Text("请选择部门").tag("")
                        ForEach(model.nasDepartments) { option in
                            Text(option.name).tag(option.name)
                        }
                    }
                    .onChange(of: model.selectedNASDepartment) { _, _ in model.loadNASEmployees() }

                    Picker("姓名", selection: $model.selectedNASEmployee) {
                        Text("请选择姓名").tag("")
                        ForEach(model.nasEmployees) { option in
                            Text(option.name).tag(option.name)
                        }
                    }
                    .onChange(of: model.selectedNASEmployee) { _, _ in
                        model.reconcileEmployeeOnboarding()
                    }

                    LabeledContent("固定目标") {
                        Text("公司 NAS / \(model.selectedNASDepartment) / \(model.selectedNASEmployee)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .disabled(isBackupBusy)
            }

            HStack {
                Button("重新检测 NAS") { model.refreshNASCatalog() }
                    .disabled(isBackupBusy)
                if [.disconnected, .pending, .error].contains(model.nasSetupSnapshot.state) {
                    Button("立即重试") { model.retryNASBackup() }
                }
                Spacer()
                Button("验证并开始备份") { model.activateSelectedNASIdentity() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canActivateSelectedNASIdentity || isBackupBusy)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear { model.refreshNASCatalog() }
    }
}

struct AppSidebar: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.84),
                    Color(red: 0.93, green: 0.96, blue: 1.0).opacity(0.92),
                    Color(red: 0.93, green: 0.99, blue: 0.97).opacity(0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("codex_会话管理")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color(red: 0.14, green: 0.24, blue: 0.42))
                    Text("管理、删除、备份和恢复 Codex 对话。")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.39, green: 0.50, blue: 0.65))
                    CurrentStateCard(state: model.currentState)
                }
                .padding(18)

                List(selection: $model.selectedSection) {
                    Section("功能") {
                        Label("会话管理", systemImage: "bubble.left.and.bubble.right")
                            .tag(AppSection.sessions)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill((model.selectedSection ?? .sessions) == .sessions ? Color(red: 0.19, green: 0.54, blue: 1.0).opacity(0.18) : Color.clear)
                                    .padding(.vertical, 2)
                            )
                        Label("快照恢复", systemImage: "archivebox")
                            .tag(AppSection.snapshots)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill((model.selectedSection ?? .sessions) == .snapshots ? Color(red: 0.19, green: 0.54, blue: 1.0).opacity(0.18) : Color.clear)
                                    .padding(.vertical, 2)
                            )
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct CurrentStateCard: View {
    let state: CurrentCodexState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("当前 Codex 状态", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(Color(red: 0.16, green: 0.28, blue: 0.48))
            InfoLine("Provider", state.modelProvider)
            InfoLine("Model", state.model)
            InfoLine("Account", state.accountFingerprint)
            InfoLine("Sessions", "\(state.sessionCount) active / \(state.archivedSessionCount) archived")
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    .white.opacity(0.7),
                    Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.62)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.86), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.16, green: 0.37, blue: 0.84).opacity(0.07), radius: 22, x: 0, y: 12)
    }
}

struct ResizableSplitView<Leading: View, Trailing: View>: View {
    let minLeadingWidth: CGFloat
    let minTrailingWidth: CGFloat
    let initialLeadingWidth: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var leadingWidth: CGFloat?
    @State private var isDragging = false

    private let dividerWidth: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let resolvedLeadingWidth = currentLeadingWidth(totalWidth: totalWidth)

            HStack(spacing: 0) {
                leading()
                    .frame(width: resolvedLeadingWidth)

                ZStack {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(isDragging ? Color(red: 0.19, green: 0.54, blue: 1.0).opacity(0.16) : Color.clear)
                        .frame(width: 12)
                    RoundedRectangle(cornerRadius: 999)
                        .fill(isDragging ? Color(red: 0.19, green: 0.54, blue: 1.0).opacity(0.75) : Color(red: 0.56, green: 0.65, blue: 0.78).opacity(0.36))
                        .frame(width: 3)
                }
                .frame(width: dividerWidth)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            isDragging = true
                            leadingWidth = clampedLeadingWidth(value.location.x, totalWidth: totalWidth)
                        }
                        .onEnded { value in
                            leadingWidth = clampedLeadingWidth(value.location.x, totalWidth: totalWidth)
                            isDragging = false
                        }
                )

                trailing()
                    .frame(width: max(minTrailingWidth, totalWidth - resolvedLeadingWidth - dividerWidth))
            }
            .animation(.easeInOut(duration: 0.14), value: isDragging)
        }
    }

    private func currentLeadingWidth(totalWidth: CGFloat) -> CGFloat {
        clampedLeadingWidth(leadingWidth ?? initialLeadingWidth, totalWidth: totalWidth)
    }

    private func clampedLeadingWidth(_ proposed: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let maximumLeadingWidth = max(minLeadingWidth, totalWidth - minTrailingWidth - dividerWidth)
        return min(max(proposed, minLeadingWidth), maximumLeadingWidth)
    }
}

struct SnapshotRow: View {
    let snapshot: SnapshotMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(snapshot.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(snapshot.isManualSnapshot ? Color(red: 0.26, green: 0.66, blue: 1.0).opacity(0.20) : Color(red: 1.0, green: 0.72, blue: 0.42).opacity(0.18), in: Capsule())
            }
            Text("\(snapshot.modelProvider) / \(snapshot.model)")
                .font(.caption)
                .foregroundStyle(Color(red: 0.39, green: 0.50, blue: 0.66))
            Text(snapshot.createdAt.formatted(date: .numeric, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Color(red: 0.50, green: 0.60, blue: 0.74))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.86),
                    Color(red: 0.93, green: 0.97, blue: 1.0).opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.86), lineWidth: 1)
        )
    }
}

struct SessionsPane: View {
    @EnvironmentObject private var model: VaultModel
    @State private var leadingPaneWidth: CGFloat = 520

    var body: some View {
        ResizableSplitView(
            minLeadingWidth: 430,
            minTrailingWidth: 520,
            initialLeadingWidth: leadingPaneWidth
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("会话列表")
                            .font(.largeTitle.bold())
                        Text("单击选中会话；双击查看对话记录；右键可从快照恢复指定会话。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CountBadge(value: "\(model.visibleSessions.count) / \(model.sessions.count)")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField(
                            "搜索标题、目录、模型、ID",
                            text: Binding(
                                get: { model.sessionSearchInput },
                                set: { model.updateSessionSearchInput($0) }
                            )
                        )
                            .textFieldStyle(.roundedBorder)
                        if !model.sessionSearchInput.isEmpty {
                            Button("清空") { model.clearSessionSearch() }
                        }
                        Toggle("归档", isOn: $model.showArchivedSessions)
                            .toggleStyle(.switch)
                            .font(.caption)
                            .help("显示或隐藏已归档会话")
                    }
                    HStack(spacing: 10) {
                        Text("批量操作")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !model.checkedSessionIDs.isEmpty {
                            Button("清空选择") { model.clearCheckedSessions() }
                        }
                        Button("全选可见") { model.checkAllVisibleSessions() }
                            .disabled(model.visibleSessions.isEmpty)
                        if !model.checkedSessionIDs.isEmpty {
                            Button("删除选中 \(model.checkedSessionIDs.count)", role: .destructive) {
                                model.deleteCheckedSessions()
                            }
                            .frame(minWidth: 126)
                            .disabled(model.isBusy)
                        }
                    }
                }
                .padding(12)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.68),
                            Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.66),
                            Color(red: 0.92, green: 0.99, blue: 0.97).opacity(0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 1)
                )

                if model.visibleSessions.isEmpty {
                    ContentUnavailableView(
                        "没有匹配会话",
                        systemImage: "magnifyingglass",
                        description: Text("换个关键词，或清空搜索条件。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedSessionID) {
                        ForEach(model.visibleSessions) { session in
                            HStack(spacing: 10) {
                                Button {
                                    model.toggleCheckedSession(session)
                                } label: {
                                    Image(systemName: model.checkedSessionIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.checkedSessionIDs.contains(session.id) ? .blue : .secondary)
                                }
                                .buttonStyle(.plain)

                                SessionRow(session: session)
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        TapGesture(count: 1).onEnded {
                                            model.selectedSessionID = session.id
                                        }
                                    )
                                    .onTapGesture(count: 2) {
                                        model.selectedSessionID = session.id
                                        model.openConversationViewer(for: session)
                                    }
                                    .contextMenu {
                                        Button("查看对话记录") {
                                            model.openConversationViewer(for: session)
                                        }
                                        Button("从最近快照恢复此会话") {
                                            model.restoreSessionFromLatestSnapshot(session)
                                        }
                                        .disabled(model.isBusy)
                                        Divider()
                                        Button("打开会话文件") {
                                            model.selectedSessionID = session.id
                                            model.openSelectedSessionFile()
                                        }
                                        .disabled(!session.existsOnDisk)
                                        Button("在 Finder 中显示") {
                                            model.selectedSessionID = session.id
                                            model.revealSelectedSessionFile()
                                        }
                                        .disabled(!session.existsOnDisk)
                                    }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tag(session.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .padding(24)
            .onChange(of: model.sessionSearch) { _, _ in
                model.selectFirstVisibleSessionIfNeeded()
            }
            .onChange(of: model.showArchivedSessions) { _, _ in
                model.selectFirstVisibleSessionIfNeeded()
            }
        } trailing: {
            VStack(alignment: .leading, spacing: 18) {
                if let session = model.selectedSession {
                    SessionDetail(session: session)
                } else {
                    ContentUnavailableView(
                        "没有选中会话",
                        systemImage: "bubble.left",
                        description: Text("从左侧选择一个会话，或调整搜索条件。")
                    )
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct SessionRow: View {
    let session: CodexSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                if session.archived {
                    Text("归档")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 1.0, green: 0.72, blue: 0.42).opacity(0.18), in: Capsule())
                }
                if !session.existsOnDisk {
                    Text("缺文件")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 1.0, green: 0.52, blue: 0.58).opacity(0.16), in: Capsule())
                }
            }
            Text("\(session.modelProvider) / \(session.model) · \(session.displaySource)")
                .font(.caption)
                .foregroundStyle(Color(red: 0.39, green: 0.50, blue: 0.66))
                .lineLimit(1)
            Text(session.updatedAt.formatted(date: .numeric, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Color(red: 0.50, green: 0.60, blue: 0.74))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.86),
                    Color(red: 0.93, green: 0.97, blue: 1.0).opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.86), lineWidth: 1)
        )
    }
}

struct SessionDetail: View {
    @EnvironmentObject private var model: VaultModel
    let session: CodexSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.displayTitle)
                            .font(.largeTitle.bold())
                            .lineLimit(3)
                        Text(session.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        CountBadge(value: ByteCountFormatter.string(fromByteCount: session.sizeBytes, countStyle: .file))
                        Text(session.archived ? "已归档" : "活跃")
                            .font(.caption)
                            .foregroundStyle(session.archived ? .orange : .green)
                    }
                }

                PrimaryActionCard {
                    Button("查看对话记录") { model.openConversationViewer(for: session) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.existsOnDisk)
                    Button("打开会话文件") { model.openSelectedSessionFile() }
                        .disabled(!session.existsOnDisk)
                    Button("在 Finder 中显示") { model.revealSelectedSessionFile() }
                        .disabled(!session.existsOnDisk)
                    Spacer()
                } footer: {
                    Text(session.existsOnDisk ? "常用操作放在这里：先打开文件或定位文件，再决定是否清理。" : "这个会话在索引中存在，但本地会话文件已经缺失。")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 12) {
                    MetricCard(title: "模型供应商", value: session.modelProvider, systemImage: "network")
                    MetricCard(title: "模型", value: session.model, systemImage: "cpu")
                    MetricCard(title: "来源", value: session.displaySource, systemImage: "terminal")
                    MetricCard(title: "文件状态", value: session.existsOnDisk ? "存在" : "缺失", systemImage: "doc.text")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DetailCard(title: "位置和时间", systemImage: "clock") {
                    InfoLine("创建时间", session.createdAt.formatted(date: .complete, time: .standard))
                    InfoLine("更新时间", session.updatedAt.formatted(date: .complete, time: .standard))
                    InfoLine("工作目录", session.cwd)
                    InfoLine("会话文件", session.rolloutPath)
                }
                .textSelection(.enabled)

                DangerZoneCard(
                    title: "删除会话",
                    message: "会自动创建快照备份，然后清理会话文件、索引和线程记录。建议先退出 Codex，再删除当前正在使用的会话。"
                ) {
                    Button("删除会话", role: .destructive) { model.deleteSelectedSession() }
                        .disabled(model.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConversationViewer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: VaultModel
    let session: CodexSession
    let messages: [ConversationMessage]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.displayTitle)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text(model.isConversationLoading ? "正在加载消息..." : "\(messages.count) 条消息 · \(session.updatedAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if model.isConversationLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在读取并解析会话记录")
                        .font(.headline)
                    Text("大文件会在后台处理，窗口不会卡死。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.conversationViewerError {
                ContentUnavailableView(
                    "打开失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "没有解析到对话内容",
                    systemImage: "text.bubble",
                    description: Text("这个会话文件存在，但没有找到用户或助手消息。可以从右上角关闭后打开原始会话文件查看。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ConversationMessageRow(message: message)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack {
                Button("打开原始文件") { model.openSelectedSessionFile() }
                    .disabled(!session.existsOnDisk)
                Button("在 Finder 中显示") { model.revealSelectedSessionFile() }
                    .disabled(!session.existsOnDisk)
                Spacer()
                Text("双击会话行可再次打开此窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }
}

struct ConversationMessageRow: View {
    let message: ConversationMessage
    @State private var isExpanded = false

    private let previewLimit = 12_000

    private var isLongMessage: Bool {
        message.text.count > previewLimit
    }

    private var visibleText: String {
        guard isLongMessage, !isExpanded else { return message.text }
        return String(message.text.prefix(previewLimit))
    }

    private var roleColor: Color {
        switch message.role {
        case "用户":
            return .blue
        case "助手":
            return .green
        default:
            return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .center, spacing: 4) {
                Text(message.role)
                    .font(.caption.bold())
                    .foregroundStyle(roleColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(roleColor.opacity(0.12), in: Capsule())
                if let phase = message.phase, !phase.isEmpty {
                    Text(phase)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 70)

            VStack(alignment: .leading, spacing: 6) {
                if let timestamp = message.timestamp {
                    Text(timestamp.formatted(date: .numeric, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(visibleText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLongMessage {
                    Button(isExpanded ? "收起长消息" : "展开完整消息") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SnapshotPane: View {
    @EnvironmentObject private var model: VaultModel
    @State private var leadingPaneWidth: CGFloat = 560

    @ViewBuilder
    private var snapshotCreationControls: some View {
        HStack(spacing: 10) {
            TextField("快照备注，可留空", text: $model.snapshotName)
                .textFieldStyle(.roundedBorder)
            Button("创建快照") {
                model.createManualSnapshot()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.isBusy)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var snapshotFilterControls: some View {
        HStack(spacing: 10) {
            Picker("类型", selection: $model.snapshotFilter) {
                ForEach(SnapshotFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        ResizableSplitView(
            minLeadingWidth: 470,
            minTrailingWidth: 540,
            initialLeadingWidth: leadingPaneWidth
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("快照恢复")
                            .font(.largeTitle.bold())
                        Text(model.snapshotRestoreSource == .snapshots ? "用于切换账号后找回或回滚对话。" : "从公司 NAS 设备备份恢复当前缺失的对话。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.snapshotRestoreSource == .snapshots {
                        CountBadge(value: "\(model.filteredSnapshots.count) / \(model.snapshots.count)")
                    } else {
                        CountBadge(value: "\(model.incrementalBackupCatalogSummary?.missingCount ?? 0) / \(model.incrementalBackupCatalogSummary?.totalCount ?? 0)")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("恢复来源", selection: $model.snapshotRestoreSource) {
                        ForEach(SnapshotRestoreSource.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    if model.snapshotRestoreSource == .snapshots {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                snapshotCreationControls
                                snapshotFilterControls
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                snapshotCreationControls
                                snapshotFilterControls
                            }
                        }
                        HStack(spacing: 10) {
                            Text("批量操作")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !model.checkedSnapshotIDs.isEmpty {
                                Button("清空选择") { model.clearCheckedSnapshots() }
                            }
                            Button("全选") { model.checkAllSnapshots() }
                                .disabled(model.filteredSnapshots.isEmpty)
                            if !model.checkedSnapshotIDs.isEmpty {
                                Button("删除选中 \(model.checkedSnapshotIDs.count)", role: .destructive) {
                                    model.deleteCheckedSnapshots()
                                }
                                .frame(minWidth: 126)
                                .disabled(model.isBusy)
                            }
                        }
                    } else {
                        IncrementalBackupRestoreControls()
                    }
                }
                .padding(12)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.68),
                            Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.66),
                            Color(red: 0.92, green: 0.99, blue: 0.97).opacity(0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 1)
                )

                if model.snapshotRestoreSource == .snapshots {
                    if model.filteredSnapshots.isEmpty {
                        ContentUnavailableView(
                            "没有匹配快照",
                            systemImage: "archivebox",
                            description: Text("切换筛选条件，或创建一个手动快照。")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $model.selectedID) {
                            ForEach(model.filteredSnapshots) { snapshot in
                                HStack(spacing: 10) {
                                    Button {
                                        model.toggleCheckedSnapshot(snapshot)
                                    } label: {
                                        Image(systemName: model.checkedSnapshotIDs.contains(snapshot.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.checkedSnapshotIDs.contains(snapshot.id) ? .blue : .secondary)
                                    }
                                    .buttonStyle(.plain)

                                    SnapshotRow(snapshot: snapshot)
                                        .contentShape(Rectangle())
                                        .simultaneousGesture(
                                            TapGesture(count: 1).onEnded {
                                                model.selectedID = snapshot.id
                                            }
                                        )
                                }
                                .tag(snapshot.id)
                            }
                        }
                        .listStyle(.inset)
                    }
                } else {
                    IncrementalBackupRestoreList()
                }
            }
            .padding(24)
            .onAppear {
                model.refreshSelectedSnapshotSessions()
                if model.snapshotRestoreSource == .incrementalBackups {
                    model.refreshIncrementalBackupCandidates()
                }
            }
            .onChange(of: model.selectedID) { _, _ in
                model.clearCheckedSnapshotSessions()
                model.refreshSelectedSnapshotSessions()
            }
            .onChange(of: model.snapshotRestoreSource) { _, source in
                if source == .incrementalBackups {
                    model.refreshIncrementalBackupCandidates()
                }
            }
            .onChange(of: model.snapshotFilter) { _, _ in
                model.selectFirstVisibleSnapshotIfNeeded()
                model.clearCheckedSnapshotSessions()
                model.refreshSelectedSnapshotSessions()
            }
        } trailing: {
            VStack(alignment: .leading, spacing: 18) {
                if model.snapshotRestoreSource == .snapshots {
                    if let snapshot = model.selectedSnapshot {
                        SnapshotDetail(snapshot: snapshot)
                    } else {
                        ContentUnavailableView(
                            "没有选中快照",
                            systemImage: "archivebox",
                            description: Text("先创建一个快照，或从左侧选择已有快照。")
                        )
                    }
                } else {
                    IncrementalBackupRestoreDetail()
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct IncrementalBackupRestoreControls: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("NAS 备份设备", selection: $model.selectedNASRecoverySourceID) {
                    ForEach(model.nasRecoverySources) { source in
                        Text(source.isCurrentDevice
                            ? "当前设备 · \(source.deviceName)"
                            : "旧设备 · \(source.deviceName) · \(source.lastBackupAt?.formatted(date: .numeric, time: .shortened) ?? "无时间")")
                            .tag(Optional(source.id))
                    }
                }
                .frame(minWidth: 280)
                .onChange(of: model.selectedNASRecoverySourceID) { _, _ in
                    model.refreshIncrementalBackupCandidates()
                }
                Button("刷新设备") { model.refreshNASRecoverySources() }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchAndToggles
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 10) {
                    searchAndToggles
                    actionButtons
                }
            }

            if let summary = model.incrementalBackupCatalogSummary {
                Text("备份目录：\(summary.backupRoot) · 缺失 \(summary.missingCount) · 已存在 \(summary.existingCount) · 异常 \(summary.errorCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("读取所选公司 NAS 设备备份后，只列出当前 Codex 中缺失的会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.incrementalBackupSearch) { _, _ in
            model.selectFirstVisibleIncrementalBackupIfNeeded()
        }
        .onChange(of: model.showExistingIncrementalBackups) { _, _ in
            model.selectFirstVisibleIncrementalBackupIfNeeded()
        }
    }

    private var searchAndToggles: some View {
        HStack(spacing: 10) {
            TextField("搜索标题、路径、ID", text: $model.incrementalBackupSearch)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
            Toggle("显示已存在", isOn: $model.showExistingIncrementalBackups)
                .toggleStyle(.checkbox)
                .fixedSize()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button("刷新备份") { model.refreshIncrementalBackupCandidates() }
                .disabled(model.isBusy)
            Button("全选缺失") { model.checkAllVisibleIncrementalBackups() }
                .disabled(model.filteredIncrementalBackupCandidates.filter(\.isRestorable).isEmpty)
            if !model.checkedIncrementalBackupIDs.isEmpty {
                Button("清空选择") { model.clearCheckedIncrementalBackups() }
            }
        }
    }
}

struct IncrementalBackupRestoreList: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        if model.filteredIncrementalBackupCandidates.isEmpty {
            ContentUnavailableView(
                "没有可显示的备份会话",
                systemImage: "arrow.counterclockwise.circle",
                description: Text(model.showExistingIncrementalBackups ? "所选 NAS 设备备份为空，或搜索条件没有匹配。" : "当前没有缺失会话；打开“显示已存在”可排查全部备份记录。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.filteredIncrementalBackupCandidates) { candidate in
                        IncrementalBackupRestoreRow(
                            candidate: candidate,
                            isSelected: model.selectedIncrementalBackupID == candidate.id,
                            isChecked: model.checkedIncrementalBackupIDs.contains(candidate.id)
                        )
                        .onTapGesture {
                            model.selectedIncrementalBackupID = candidate.id
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct IncrementalBackupRestoreRow: View {
    @EnvironmentObject private var model: VaultModel
    let candidate: IncrementalRestoreCandidate
    let isSelected: Bool
    let isChecked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleCheckedIncrementalBackup(candidate)
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!candidate.isRestorable)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(candidate.title)
                        .font(.headline)
                        .lineLimit(2)
                    IncrementalBackupStatusBadge(status: candidate.status)
                }
                Text("\(candidate.sessionId) · \(ByteCountFormatter.string(fromByteCount: candidate.bytesBackedUp, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(candidate.backupPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text((candidate.lastBackedUpAt ?? candidate.firstSeenAt).formatted(date: .numeric, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.blue.opacity(0.14) : Color.white.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.42) : Color.white.opacity(0.75), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct IncrementalBackupRestoreDetail: View {
    @EnvironmentObject private var model: VaultModel

    private var selected: IncrementalRestoreCandidate? {
        model.incrementalBackupCandidates.first { $0.id == model.selectedIncrementalBackupID }
    }

    var body: some View {
        if let candidate = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(candidate.title)
                                .font(.largeTitle.bold())
                                .lineLimit(3)
                            Text(candidate.sessionId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        CountBadge(value: ByteCountFormatter.string(fromByteCount: candidate.bytesBackedUp, countStyle: .file))
                    }

                    PrimaryActionCard {
                        Button(model.checkedRestorableIncrementalBackups.isEmpty ? "恢复这个缺失会话" : "恢复选中 \(model.checkedRestorableIncrementalBackups.count)") {
                            model.restoreSelectedIncrementalBackupSessions()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || (!candidate.isRestorable && model.checkedRestorableIncrementalBackups.isEmpty))
                        Button("刷新备份") { model.refreshIncrementalBackupCandidates() }
                            .disabled(model.isBusy)
                        Spacer()
                    } footer: {
                        Text("只恢复当前 Codex 中缺失的会话；已存在会话不会覆盖。恢复完成后请重启 Codex。")
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 12) {
                        MetricCard(title: "状态", value: incrementalStatusLabel(candidate.status), systemImage: "checkmark.seal")
                        MetricCard(title: "备份行数", value: "\(candidate.lineCount)", systemImage: "list.bullet.rectangle")
                        MetricCard(title: "首次备份", value: candidate.firstSeenAt.formatted(date: .numeric, time: .shortened), systemImage: "calendar")
                        MetricCard(title: "最近备份", value: (candidate.lastBackedUpAt ?? candidate.firstSeenAt).formatted(date: .numeric, time: .shortened), systemImage: "clock")
                    }

                    DetailCard(title: "路径", systemImage: "folder") {
                        VStack(alignment: .leading, spacing: 8) {
                            pathLine(title: "备份文件", value: candidate.backupPath)
                            pathLine(title: "原始路径", value: candidate.sourcePath)
                            if !candidate.backupFilePath.isEmpty {
                                pathLine(title: "本机备份", value: candidate.backupFilePath)
                            }
                        }
                    }

                    if let error = candidate.error, !error.isEmpty {
                        DetailCard(title: "备份异常", systemImage: "exclamationmark.triangle") {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "没有选中备份会话",
                systemImage: "arrow.counterclockwise.circle",
                description: Text("从左侧选择一个缺失会话，或刷新所选 NAS 设备备份。")
            )
        }
    }

    private func pathLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

struct IncrementalBackupStatusBadge: View {
    let status: IncrementalRestoreStatus

    var body: some View {
        Text(incrementalStatusLabel(status))
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch status {
        case .missing:
            return .green
        case .existing:
            return .secondary
        case .invalidBackup, .backupFileMissing:
            return .red
        }
    }
}

private func incrementalStatusLabel(_ status: IncrementalRestoreStatus) -> String {
    switch status {
    case .missing:
        return "可恢复"
    case .existing:
        return "已存在"
    case .invalidBackup:
        return "备份异常"
    case .backupFileMissing:
        return "文件缺失"
    }
}

struct SnapshotDetail: View {
    @EnvironmentObject private var model: VaultModel
    let snapshot: SnapshotMeta

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.name)
                            .font(.largeTitle.bold())
                            .lineLimit(3)
                        HStack(spacing: 8) {
                            Text(snapshot.kindLabel)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(snapshot.isManualSnapshot ? .blue.opacity(0.14) : .orange.opacity(0.14), in: Capsule())
                            Text(snapshot.createdAt.formatted(date: .complete, time: .standard))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    CountBadge(value: ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file))
                }

                PrimaryActionCard {
                    Button("只恢复对话") { model.restoreSelectedConversationsOnly() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    Button("打开快照目录") { model.openSelectedSnapshot() }
                    Spacer()
                } footer: {
                    Text("推荐操作：只恢复对话会保留当前账号、登录态和模型供应商配置。")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 12) {
                    MetricCard(title: "类型", value: snapshot.kindLabel, systemImage: "tag")
                    MetricCard(title: "模型供应商", value: snapshot.modelProvider, systemImage: "network")
                    MetricCard(title: "模型", value: snapshot.model, systemImage: "cpu")
                    MetricCard(title: "账号指纹", value: snapshot.accountFingerprint, systemImage: "person.crop.circle.badge.checkmark")
                    MetricCard(title: "会话", value: "\(snapshot.sessionCount) / \(snapshot.archivedSessionCount)", systemImage: "bubble.left.and.bubble.right")
                }

                DetailCard(title: "包含内容", systemImage: "doc.on.doc") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(snapshot.includedPaths, id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }

                SnapshotSessionRestoreCard()

                DetailCard(title: "高级恢复", systemImage: "exclamationmark.triangle") {
                    HStack(alignment: .center, spacing: 12) {
                        Text("完整恢复会把账号、登录态和 config.toml 一起回滚到快照状态。只有明确需要回滚配置时再用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("完整恢复") { model.restoreSelectedFull() }
                            .disabled(model.isBusy)
                    }
                }

                DangerZoneCard(
                    title: "删除快照",
                    message: "删除后无法从这个快照恢复。不会影响当前 Codex 会话。"
                ) {
                    Button("删除快照", role: .destructive) { model.deleteSelected() }
                        .disabled(model.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SnapshotSessionRestoreCard: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        DetailCard(title: "快照内会话恢复", systemImage: "arrow.down.doc") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("搜索快照内会话", text: $model.snapshotSessionSearch)
                        .textFieldStyle(.roundedBorder)
                    if !model.snapshotSessionSearch.isEmpty {
                        Button("清空") {
                            model.snapshotSessionSearch = ""
                            model.selectFirstVisibleSnapshotSessionIfNeeded()
                        }
                    }
                    CountBadge(value: "\(model.filteredSnapshotSessions.count)")
                }

                HStack(spacing: 10) {
                    Button("全选可恢复") { model.checkAllVisibleSnapshotSessions() }
                        .disabled(model.filteredSnapshotSessions.filter(\.existsOnDisk).isEmpty)
                    if !model.checkedSnapshotSessionIDs.isEmpty {
                        Button("清空选择") { model.clearCheckedSnapshotSessions() }
                        Button("批量恢复选中 \(model.checkedSnapshotSessions.filter(\.existsOnDisk).count)") {
                            model.restoreCheckedSnapshotSessions()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.checkedSnapshotSessions.filter(\.existsOnDisk).isEmpty || model.isBusy)
                    }
                    Spacer()
                    Button("恢复本快照全部对话") { model.restoreSelectedConversationsOnly() }
                        .disabled(model.isBusy)
                }

                if model.snapshotSessions.isEmpty {
                    Text("这个快照里没有可读取的会话文件或索引。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.filteredSnapshotSessions.isEmpty {
                    ContentUnavailableView(
                        "没有匹配会话",
                        systemImage: "magnifyingglass",
                        description: Text("换个关键词，或清空搜索条件。")
                    )
                    .frame(height: 130)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.filteredSnapshotSessions) { session in
                                HStack(spacing: 8) {
                                    Button {
                                        model.toggleCheckedSnapshotSession(session)
                                    } label: {
                                        Image(systemName: model.checkedSnapshotSessionIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.checkedSnapshotSessionIDs.contains(session.id) ? .blue : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!session.existsOnDisk)

                                    Button {
                                        model.selectedSnapshotSessionID = session.id
                                    } label: {
                                        SnapshotSessionPickRow(
                                            session: session,
                                            isSelected: model.selectedSnapshotSessionID == session.id
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                .contextMenu {
                                    Button("恢复这个会话") {
                                        model.selectedSnapshotSessionID = session.id
                                        model.restoreSelectedSnapshotSession()
                                    }
                                    .disabled(model.isBusy || !session.existsOnDisk)
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                }

                HStack {
                    if !model.checkedSnapshotSessionIDs.isEmpty {
                        Text("已勾选：\(model.checkedSnapshotSessions.filter(\.existsOnDisk).count) 个可恢复会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let session = model.selectedSnapshotSession {
                        Text("已选：\(session.displayTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("先从上面选择一个会话。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.checkedSnapshotSessionIDs.isEmpty ? "恢复高亮会话" : "恢复勾选会话") {
                        model.restoreSnapshotSessionPrimaryAction()
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isBusy
                                || (
                                    model.checkedSnapshotSessionIDs.isEmpty
                                        ? (model.selectedSnapshotSession == nil || model.selectedSnapshotSession?.existsOnDisk == false)
                                        : model.checkedSnapshotSessions.filter(\.existsOnDisk).isEmpty
                                )
                        )
                }

                Text("单个或批量恢复都只合并会话文件、历史索引和线程记录，不覆盖当前账号、登录态和模型供应商配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: model.snapshotSessionSearch) { _, _ in
                model.selectFirstVisibleSnapshotSessionIfNeeded()
            }
        }
    }
}

struct SnapshotSessionPickRow: View {
    let session: CodexSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(session.modelProvider) / \(session.model) · \(session.updatedAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !session.existsOnDisk {
                Text("缺文件")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.86, green: 0.31, blue: 0.39))
            }
        }
        .padding(10)
        .background(
            isSelected
                ? AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.15, green: 0.48, blue: 1.0).opacity(0.16),
                            Color(red: 0.24, green: 0.83, blue: 0.78).opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                : AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color(red: 0.93, green: 0.97, blue: 1.0).opacity(0.68)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color(red: 0.30, green: 0.63, blue: 1.0).opacity(0.55) : .white.opacity(0.84), lineWidth: 1)
        )
    }
}

struct CountBadge: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.title3.monospacedDigit())
            .foregroundStyle(Color(red: 0.17, green: 0.32, blue: 0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(.white.opacity(0.64))
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.85), lineWidth: 1)
            )
    }
}

struct PrimaryActionCard<Actions: View, Footer: View>: View {
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                actions()
            }
            footer()
                .font(.caption)
                .foregroundStyle(Color(red: 0.34, green: 0.46, blue: 0.63))
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.47, blue: 1.0).opacity(0.14),
                    Color.white.opacity(0.82),
                    Color(red: 0.90, green: 0.98, blue: 0.97).opacity(0.75)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.17, green: 0.36, blue: 0.92).opacity(0.10), radius: 24, x: 0, y: 14)
    }
}

struct DetailCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color(red: 0.16, green: 0.28, blue: 0.48))
            content()
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.76),
                    Color(red: 0.94, green: 0.97, blue: 1.0).opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.88), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.20, green: 0.34, blue: 0.68).opacity(0.05), radius: 18, x: 0, y: 10)
    }
}

struct DangerZoneCard<Action: View>: View {
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.62, green: 0.20, blue: 0.28))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.53, green: 0.38, blue: 0.41))
            }
            Spacer()
            action()
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.95, blue: 0.96).opacity(0.88),
                    Color.white.opacity(0.76)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(red: 0.96, green: 0.78, blue: 0.81).opacity(0.8), lineWidth: 1)
        )
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color(red: 0.10, green: 0.49, blue: 1.0))
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.39, green: 0.50, blue: 0.65))
                Text(value)
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.16, green: 0.27, blue: 0.46))
                    .lineLimit(1)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.78),
                    Color(red: 0.93, green: 0.97, blue: 1.0).opacity(0.68)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.18, green: 0.39, blue: 0.82).opacity(0.05), radius: 12, x: 0, y: 8)
    }
}

struct InfoLine: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .font(.system(.caption, design: .monospaced))
        }
        .font(.caption)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        HStack {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.lastError ?? model.status)
                .foregroundStyle(model.lastError == nil ? Color(red: 0.29, green: 0.42, blue: 0.58) : Color(red: 0.76, green: 0.24, blue: 0.31))
                Spacer()
                HStack(spacing: 4) {
                    Text(model.nasBackupStatusLabel)
                        .foregroundStyle(model.nasBackupStatusIsError ? Color(red: 0.76, green: 0.24, blue: 0.31) : Color(red: 0.29, green: 0.42, blue: 0.58))
                    Text(model.nasBackupStatusDetail)
                        .foregroundStyle(Color(red: 0.46, green: 0.56, blue: 0.69))
                        .truncationMode(.middle)
                    Button("更换 NAS 备份身份") { model.presentNASReconfiguration() }
                        .buttonStyle(.plain)
                    if model.nasSetupSnapshot.state == .disconnected || model.nasSetupSnapshot.state == .error {
                        Button("立即重试") { model.retryNASBackup() }
                            .buttonStyle(.plain)
                    }
                    if model.nasSetupSnapshot.configuration != nil,
                       !model.launchAtLoginSnapshot.enabled {
                        Text(model.launchAtLoginSnapshot.message ?? "开机自启未启用")
                            .foregroundStyle(Color(red: 0.76, green: 0.24, blue: 0.31))
                        Button("修复开机自启") { model.retryLaunchAtLogin() }
                            .buttonStyle(.plain)
                        if model.launchAtLoginSnapshot.requiresApproval {
                            Button("打开登录项设置") { model.openLoginItemSettings() }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .lineLimit(1)
                Text(model.codexRoot)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(red: 0.46, green: 0.56, blue: 0.69))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.autoRestoreOnLaunch {
                    Text("自动找回：关闭")
                        .foregroundStyle(Color(red: 0.46, green: 0.56, blue: 0.69))
                        .lineLimit(1)
                }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.68),
                    Color(red: 0.93, green: 0.97, blue: 1.0).opacity(0.62)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

struct BusyOverlay: View {
    let status: String
    let progress: Double?
    let detailOverride: String?
    let canCancel: Bool
    let isCancelling: Bool
    let onCancel: () -> Void

    private var detail: String {
        if isCancelling {
            return "正在请求取消。当前文件操作会在安全检查点停止，请等待弹窗关闭。"
        }
        if let detailOverride, !detailOverride.isEmpty {
            return detailOverride
        }
        let lower = status.lowercased()
        if status.contains("删除") {
            return "正在创建轻量恢复点并清理 Codex 会话文件、索引和 SQLite 线程记录。会话文件多时会慢一些，请耐心等待，不是卡住。"
        }
        if status.contains("恢复") || status.contains("找回") {
            return "正在复制会话文件并合并 Codex 本地索引。大快照或归档会话较多时需要更久，请不要关闭应用。"
        }
        if status.contains("快照") || lower.contains("snapshot") {
            return "正在扫描 Codex 数据目录、复制必要文件并校验会话索引。数据目录较大时需要一些时间。"
        }
        if status.contains("刷新") {
            return "正在重新读取 Codex 会话列表和快照目录，文件较多时会稍慢。"
        }
        return "正在处理本地 Codex 数据。文件较多或磁盘较忙时会需要一些时间，请耐心等待。"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    if progress == nil {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(progress.map { "进度 \((Int(($0 * 100).rounded())))%" } ?? "正在执行本地文件操作")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let progress {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("请等待完成后再切换或关闭应用，避免快照和索引写入中断。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if canCancel {
                    HStack {
                        Spacer()
                        Button(isCancelling ? "正在取消..." : "取消") {
                            onCancel()
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isCancelling)
                    }
                }
            }
            .padding(22)
            .frame(width: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 28, x: 0, y: 18)
        }
        .contentShape(Rectangle())
    }
}

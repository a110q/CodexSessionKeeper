import SwiftUI
import AppKit
import CryptoKit

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
    var records: [ExternalAttachmentRecord]
}

private struct ExternalAttachmentRecord: Codable, Sendable {
    let sessionID: String
    let originalPath: String
    let storedRelativePath: String
    let sizeBytes: Int64
}

enum SnapshotFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case manual = "手动"
    case system = "系统自动"

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
    @Published var sessions: [CodexSession] = []
    @Published var selectedSessionID: CodexSession.ID?
    @Published var checkedSessionIDs: Set<CodexSession.ID> = []
    @Published var checkedSnapshotIDs: Set<SnapshotMeta.ID> = []
    @Published var checkedSnapshotSessionIDs: Set<CodexSession.ID> = []
    @Published var sessionSearchInput = ""
    @Published var sessionSearch = ""
    @Published var showArchivedSessions = true
    @Published var snapshotFilter: SnapshotFilter = .all
    @Published var conversationViewerSession: CodexSession?
    @Published var conversationMessages: [ConversationMessage] = []
    @Published var isConversationViewerPresented = false
    @Published var isConversationLoading = false
    @Published var conversationViewerError: String?
    @Published var autoRestoreOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoRestoreOnLaunch, forKey: Self.autoRestoreDefaultsKey)
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

    private static let autoRestoreDefaultsKey = "autoRestoreOnLaunch"
    private static let autoRestoreDefaultOffMigrationKey = "autoRestoreDefaultOffMigration.v1"
    private let fileManager = FileManager.default
    private let metadataFile = "snapshot.json"
    private let dataDir = "data"
    private let appVersion = "1.0.10"
    private var didRunLaunchAutoRestore = false
    private var conversationLoadID = UUID()
    private var sessionSearchTask: Task<Void, Never>?
    private var currentCancellationURL: URL?
    fileprivate var operationCancellationURL: URL?

    private var snapshotRootURL: URL {
        URL(fileURLWithPath: vaultRoot).appendingPathComponent("snapshots", isDirectory: true)
    }

    private func snapshotDataURL(_ snapshot: SnapshotMeta) -> URL {
        snapshotRootURL.appendingPathComponent(snapshot.id, isDirectory: true).appendingPathComponent(dataDir, isDirectory: true)
    }

    init(codexRoot explicitCodexRoot: String? = nil, vaultRoot explicitVaultRoot: String? = nil, refreshOnInit: Bool = true) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        codexRoot = explicitCodexRoot ?? "\(home)/.codex"
        vaultRoot = explicitVaultRoot ?? "\(home)/.codex-session-vault"
        if UserDefaults.standard.bool(forKey: Self.autoRestoreDefaultOffMigrationKey) {
            autoRestoreOnLaunch = UserDefaults.standard.object(forKey: Self.autoRestoreDefaultsKey) as? Bool ?? false
        } else {
            autoRestoreOnLaunch = false
            UserDefaults.standard.set(false, forKey: Self.autoRestoreDefaultsKey)
            UserDefaults.standard.set(true, forKey: Self.autoRestoreDefaultOffMigrationKey)
        }
        if refreshOnInit {
            refresh()
        }
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
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.filter { session in
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
    }

    func refresh() {
        lastError = nil
        do {
            try ensureDirectories()
            currentState = inspectCurrentState()
            sessions = try loadSessions()
            snapshots = try loadSnapshots()
            if selectedSessionID == nil {
                selectedSessionID = filteredSessions.first?.id ?? sessions.first?.id
            } else if !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = filteredSessions.first?.id ?? sessions.first?.id
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
        if let selectedSessionID, filteredSessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        selectedSessionID = filteredSessions.first?.id
    }

    func toggleCheckedSession(_ session: CodexSession) {
        if checkedSessionIDs.contains(session.id) {
            checkedSessionIDs.remove(session.id)
        } else {
            checkedSessionIDs.insert(session.id)
        }
    }

    func checkAllVisibleSessions() {
        checkedSessionIDs.formUnion(filteredSessions.map(\.id))
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

    func restoreSnapshotSessionPrimaryAction() {
        if !checkedSnapshotSessionIDs.isEmpty {
            restoreCheckedSnapshotSessions()
        } else {
            restoreSelectedSnapshotSession()
        }
    }

    func runLaunchAutoRestoreIfNeeded(force: Bool = false) {
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
            await runWorker("正在自动找回会话...", command: command) { _ in
                self.refresh()
                self.selectedID = latestSnapshot.id
                self.selectedSection = .sessions
                self.status = "已自动找回会话：从 \(latestSnapshot.name) 合并恢复，保留当前账号和模型供应商配置"
                self.inform(title: "恢复完成", message: "已自动找回会话：从 \(latestSnapshot.name) 合并恢复。\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。")
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
            await runWorker("正在恢复单个会话...", command: command) { _ in
                self.refresh()
                self.selectedSection = .sessions
                self.selectedSessionID = session.id
                self.status = "已恢复单个会话：\(session.displayTitle)"
                self.inform(
                    title: "恢复完成",
                    message: "已恢复会话：\(session.displayTitle)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
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
            await runWorker("正在批量恢复会话...", command: command) { _ in
                self.checkedSnapshotSessionIDs.removeAll()
                self.refresh()
                self.selectedSection = .sessions
                self.selectedSessionID = targets.first?.id
                self.status = "已从 \(snapshot.name) 批量恢复 \(targets.count) 个会话"
                self.inform(
                    title: "恢复完成",
                    message: "已从快照 “\(snapshot.name)” 批量恢复 \(targets.count) 个会话。\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
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
            await runWorker("正在从最近快照恢复单个会话...", command: command) { _ in
                self.refresh()
                self.selectedSection = .sessions
                self.selectedSessionID = match.session.id
                self.status = "已从 \(match.snapshot.name) 恢复：\(match.session.displayTitle)"
                self.inform(
                    title: "恢复完成",
                    message: "已从快照 “\(match.snapshot.name)” 恢复会话：\(match.session.displayTitle)\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。"
                )
            }
        }
    }

    func openConversationViewer(for session: CodexSession) {
        selectedSessionID = session.id
        conversationViewerSession = session
        conversationMessages = []
        conversationViewerError = nil
        isConversationLoading = true
        isConversationViewerPresented = true
        status = "正在加载对话记录：\(session.displayTitle)"

        let loadID = UUID()
        conversationLoadID = loadID
        let rolloutPath = session.rolloutPath
        let title = session.displayTitle

        Task.detached(priority: .userInitiated) {
            do {
                let messages = try ConversationLogParser.loadMessages(rolloutPath: rolloutPath)
                await MainActor.run {
                    guard self.conversationLoadID == loadID else { return }
                    self.conversationMessages = messages
                    self.isConversationLoading = false
                    self.status = "已打开对话记录：\(title)"
                }
            } catch {
                await MainActor.run {
                    guard self.conversationLoadID == loadID else { return }
                    self.conversationViewerError = error.localizedDescription
                    self.isConversationLoading = false
                    self.lastError = error.localizedDescription
                    self.status = "打开对话记录失败"
                }
            }
        }
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
            await runWorker("正在恢复快照...", command: command) { _ in
                self.refresh()
                self.status = "\(snapshot.name)：\(mode.successMessage)"
                self.inform(
                    title: "恢复完成",
                    message: "\(snapshot.name)：\(mode.successMessage)"
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
        guard let session = selectedSession, !session.rolloutPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.rolloutPath))
    }

    func revealSelectedSessionFile() {
        guard let session = selectedSession, !session.rolloutPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.rolloutPath)])
    }

    func openCodexRoot() {
        NSWorkspace.shared.open(URL(fileURLWithPath: codexRoot, isDirectory: true))
    }

    func openVaultRoot() {
        NSWorkspace.shared.open(URL(fileURLWithPath: vaultRoot, isDirectory: true))
    }

    func openSelectedSnapshot() {
        guard let snapshot = selectedSnapshot else { return }
        NSWorkspace.shared.open(snapshotRootURL.appendingPathComponent(snapshot.id, isDirectory: true))
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

    private func ensureDirectories() throws {
        if !fileManager.fileExists(atPath: codexRoot) {
            throw VaultError.codexRootMissing(codexRoot)
        }
        try fileManager.createDirectory(at: snapshotRootURL, withIntermediateDirectories: true)
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
                  let meta = try? JSONDecoder.snapshot.decode(SnapshotMeta.self, from: data) else {
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
           let sessions = try? loadSessionsFromStateDatabase(database: database, dataRoot: root, snapshotCodexRoot: codexRoot),
           !sessions.isEmpty {
            return sessions
        }
        return try loadSessionsFromFiles(root: root)
    }

    private func loadSessions(in snapshot: SnapshotMeta) throws -> [CodexSession] {
        let dataURL = snapshotDataURL(snapshot)
        let database = dataURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else {
            return try loadSessionsFromFiles(root: dataURL)
        }

        let databaseSessions = (try? loadSessionsFromStateDatabase(
            database: database,
            dataRoot: dataURL,
            snapshotCodexRoot: snapshot.codexRoot
        )) ?? []
        if !databaseSessions.isEmpty, databaseSessions.allSatisfy(\.existsOnDisk) {
            return databaseSessions
        }
        let fileSessions = try loadSessionsFromFiles(root: dataURL)
        return mergedSessions(primary: databaseSessions, fallback: fileSessions)
    }

    private func loadSessionsFromStateDatabase(
        database: URL,
        dataRoot: URL,
        snapshotCodexRoot: String
    ) throws -> [CodexSession] {
        try loadSessionRows(from: database).map { row in
            let snapshotFileURL = resolvedRolloutFileURL(
                sessionID: row.id,
                rolloutPath: row.rolloutPath,
                dataRoot: dataRoot,
                snapshotCodexRoot: snapshotCodexRoot
            )
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
        var fileURLs: [URL] = []
        for directory in ["sessions", "archived_sessions"] {
            let dirURL = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                fileURLs.append(fileURL)
            }
        }

        let sessions = fileURLs.compactMap { fileURL -> CodexSession? in
            let id = extractSessionID(from: fileURL)
            guard !id.isEmpty else { return nil }
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

    private func extractSessionID(from fileURL: URL) -> String {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let text = fileURL.lastPathComponent
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let idRange = Range(match.range, in: text) else {
            return ""
        }
        return String(text[idRange]).lowercased()
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
            rolloutPath: rolloutPathOverride ?? row.rolloutPath,
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
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

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
            let counts = snapshotSessionCounts(dataURL: dataURL, sessionIDs: restorableIDs)
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
        try encoded.write(to: snapshotURL.appendingPathComponent(metadataFile), options: .atomic)
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
        try ensureDirectories()
        let targetIDs = Set(sessions.map(\.id))
        guard !targetIDs.isEmpty || !extraCandidatePaths.isEmpty else {
            throw VaultError.commandFailed("没有可备份的会话。")
        }

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
        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

        var includedPaths = Set<String>()

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

        for relPath in conversationLineMergePaths {
            try checkOperationCancellation()
            let src = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dst = dataURL.appendingPathComponent(relPath)
            try writeFilteredLineFile(
                src: src,
                dst: dst,
                uniqueKey: relPath == "session_index.jsonl" ? "id" : nil,
                allowedSessionIDs: targetIDs
            )
            includedPaths.insert(relPath)
        }

        try checkOperationCancellation()
        try copyRolloutFiles(sessionIDs: targetIDs, from: root, to: dataURL, includedPaths: &includedPaths)
        try checkOperationCancellation()
        try copyShellSnapshots(sessionIDs: targetIDs, from: root, to: dataURL, includedPaths: &includedPaths)

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
        let counts = snapshotSessionCounts(dataURL: dataURL, sessionIDs: restorableIDs)
        let state = inspectCurrentState()
        let meta = SnapshotMeta(
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
        try encoded.write(to: snapshotURL.appendingPathComponent(metadataFile), options: .atomic)
        try enforceAutomaticSnapshotRetention()
        return meta
    }

    private func restore(snapshot: SnapshotMeta, mode: RestoreMode) throws {
        try checkOperationCancellation()
        let snapshotURL = snapshotRootURL.appendingPathComponent(snapshot.id, isDirectory: true)
        let dataURL = snapshotURL.appendingPathComponent(dataDir, isDirectory: true)
        guard fileManager.fileExists(atPath: snapshotURL.path) else { throw VaultError.snapshotMissing }
        guard fileManager.fileExists(atPath: dataURL.path) else { throw VaultError.invalidSnapshot }

        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        switch mode {
        case .conversationsOnly:
            try checkOperationCancellation()
            try restoreConversationsOnly(
                from: dataURL,
                to: root,
                includedPaths: snapshot.includedPaths,
                snapshotCodexRoot: snapshot.codexRoot
            )
        case .full:
            try checkOperationCancellation()
            try restoreFull(
                from: dataURL,
                to: root,
                includedPaths: snapshot.includedPaths,
                snapshotCodexRoot: snapshot.codexRoot
            )
        }
    }

    private func restoreFull(
        from dataURL: URL,
        to root: URL,
        includedPaths: [String],
        snapshotCodexRoot: String
    ) throws {
        try checkOperationCancellation()
        let included = Set(includedPaths)

        for relPath in includedPaths {
            try checkOperationCancellation()
            guard relPath != "external_attachments" else { continue }
            let src = dataURL.appendingPathComponent(relPath)
            let dst = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try copyReplacing(src: src, dst: dst)
        }

        guard included.contains("state_5.sqlite") else { return }

        try checkOperationCancellation()
        let restorableSessionIDs = try restorableSessionIDs(from: dataURL, snapshotCodexRoot: snapshotCodexRoot)
        let database = root.appendingPathComponent("state_5.sqlite")
        if fileManager.fileExists(atPath: database.path) {
            try checkOperationCancellation()
            try pruneStateDatabase(database: database, sqlite: "/usr/bin/sqlite3", allowedSessionIDs: restorableSessionIDs)
            try checkOperationCancellation()
            try repairStateDatabaseRolloutPaths(database: database, root: root, sessionIDs: restorableSessionIDs)
        }

        for relPath in conversationLineMergePaths where included.contains(relPath) {
            try checkOperationCancellation()
            let lineFile = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: lineFile.path) else { continue }
            try writeFilteredLineFile(
                src: lineFile,
                dst: lineFile,
                uniqueKey: relPath == "session_index.jsonl" ? "id" : nil,
                allowedSessionIDs: restorableSessionIDs
            )
        }
        try checkOperationCancellation()
        try restoreExternalAttachments(sessionIDs: restorableSessionIDs, from: dataURL)
    }

    private func restoreConversationsOnly(
        from dataURL: URL,
        to root: URL,
        includedPaths: [String],
        snapshotCodexRoot: String
    ) throws {
        try checkOperationCancellation()
        let included = Set(includedPaths)
        let restorableSessionIDs = try included.contains("state_5.sqlite")
            ? restorableSessionIDs(from: dataURL, snapshotCodexRoot: snapshotCodexRoot)
            : nil

        for relPath in conversationDirectoryPaths where included.contains(relPath) {
            try checkOperationCancellation()
            let src = dataURL.appendingPathComponent(relPath)
            let dst = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try mergeDirectory(src: src, dst: dst)
        }

        for relPath in conversationLineMergePaths where included.contains(relPath) {
            try checkOperationCancellation()
            let src = dataURL.appendingPathComponent(relPath)
            let dst = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try mergeLineFile(
                src: src,
                dst: dst,
                uniqueKey: relPath == "session_index.jsonl" ? "id" : nil,
                allowedSessionIDs: restorableSessionIDs
            )
        }

        if included.contains("state_5.sqlite") {
            try checkOperationCancellation()
            let src = dataURL.appendingPathComponent("state_5.sqlite")
            let dst = root.appendingPathComponent("state_5.sqlite")
            if fileManager.fileExists(atPath: src.path) {
                try mergeStateDatabase(src: src, dst: dst, allowedSessionIDs: restorableSessionIDs)
                try checkOperationCancellation()
                if let restorableSessionIDs {
                    try repairStateDatabaseRolloutPaths(database: dst, root: root, sessionIDs: restorableSessionIDs)
                }
            }
        }
        try checkOperationCancellation()
        try restoreExternalAttachments(sessionIDs: restorableSessionIDs, from: dataURL)
    }

    private func restoreSingleSession(snapshot: SnapshotMeta, session: CodexSession) throws {
        try checkOperationCancellation()
        let dataURL = snapshotDataURL(snapshot)
        guard fileManager.fileExists(atPath: dataURL.path) else { throw VaultError.invalidSnapshot }

        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        guard let sourceFileURL = resolvedRolloutFileURL(
            sessionID: session.id,
            rolloutPath: session.rolloutPath,
            dataRoot: dataURL,
            snapshotCodexRoot: snapshot.codexRoot
        ),
              let rolloutRelPath = relativePath(sourceFileURL, under: dataURL) else {
            throw VaultError.commandFailed("这个快照里的会话文件路径无法映射到当前 Codex 数据目录。")
        }

        let dst = root.appendingPathComponent(rolloutRelPath)
        try checkOperationCancellation()
        try copyReplacing(src: sourceFileURL, dst: dst)

        for relPath in conversationLineMergePaths {
            try checkOperationCancellation()
            let src = dataURL.appendingPathComponent(relPath)
            let dst = root.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try mergeJSONLLines(matchingSessionID: session.id, from: src, into: dst)
        }

        try checkOperationCancellation()
        try restoreShellSnapshots(sessionID: session.id, from: dataURL, to: root)

        let srcDB = dataURL.appendingPathComponent("state_5.sqlite")
        let dstDB = root.appendingPathComponent("state_5.sqlite")
        if fileManager.fileExists(atPath: srcDB.path), fileManager.fileExists(atPath: dstDB.path) {
            try checkOperationCancellation()
            try mergeSingleSessionStateDatabase(src: srcDB, dst: dstDB, sessionID: session.id)
            try checkOperationCancellation()
            try updateThreadRolloutPath(database: dstDB, sessionID: session.id, rolloutPath: dst.path)
        }
        try checkOperationCancellation()
        try restoreExternalAttachments(sessionIDs: [session.id], from: dataURL)
    }

    private func snapshotRelativePath(for absolutePath: String, snapshotCodexRoot: String) -> String? {
        guard !absolutePath.isEmpty else { return nil }
        let normalizedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let snapshotRoot = URL(fileURLWithPath: snapshotCodexRoot, isDirectory: true).standardizedFileURL.path
        let currentRoot = URL(fileURLWithPath: codexRoot, isDirectory: true).standardizedFileURL.path

        for root in [snapshotRoot, currentRoot] where normalizedPath.hasPrefix(root + "/") {
            return String(normalizedPath.dropFirst(root.count + 1))
        }

        if let range = normalizedPath.range(of: "/.codex/") {
            return String(normalizedPath[range.upperBound...])
        }

        return nil
    }

    private func resolvedRolloutFileURL(
        sessionID: String,
        rolloutPath: String,
        dataRoot: URL,
        snapshotCodexRoot: String
    ) -> URL? {
        if let relPath = snapshotRelativePath(for: rolloutPath, snapshotCodexRoot: snapshotCodexRoot) {
            let candidate = dataRoot.appendingPathComponent(relPath)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let directURL = URL(fileURLWithPath: rolloutPath)
        if directURL.path.hasPrefix(dataRoot.standardizedFileURL.path + "/"),
           fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        return findRolloutFile(sessionID: sessionID, root: dataRoot)
    }

    private func findRolloutFile(sessionID: String, root: URL) -> URL? {
        for directory in ["sessions", "archived_sessions"] {
            let dirURL = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl",
                      fileURL.lastPathComponent.contains(sessionID),
                      fileManager.fileExists(atPath: fileURL.path) else {
                    continue
                }
                return fileURL
            }
        }
        return nil
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
            _ = try createSystemSnapshot(
                name: "Pre-Auto-Restore Backup",
                reason: "pre-auto-restore",
                candidatePaths: autoProtectionCandidates
            )
            try restore(snapshot: latestSnapshot, mode: .conversationsOnly)
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

    private func delete(session: CodexSession) throws {
        try checkOperationCancellation()
        let root = URL(fileURLWithPath: codexRoot, isDirectory: true)

        if !session.rolloutPath.isEmpty {
            try checkOperationCancellation()
            let rolloutURL = URL(fileURLWithPath: session.rolloutPath)
            if fileManager.fileExists(atPath: rolloutURL.path) {
                try fileManager.removeItem(at: rolloutURL)
                try removeEmptyParents(startingAt: rolloutURL.deletingLastPathComponent(), stopAt: root)
            }
        }

        try checkOperationCancellation()
        try removeRolloutFiles(sessionID: session.id, root: root)
        try checkOperationCancellation()
        try removeJSONLLines(matchingSessionID: session.id, from: root.appendingPathComponent("history.jsonl"))
        try checkOperationCancellation()
        try removeJSONLLines(matchingSessionID: session.id, from: root.appendingPathComponent("history.jsonl.bak"))
        try checkOperationCancellation()
        try removeJSONLLines(matchingSessionID: session.id, from: root.appendingPathComponent("session_index.jsonl"))
        try checkOperationCancellation()
        try removeShellSnapshots(sessionID: session.id, root: root)
        try checkOperationCancellation()
        try deleteSessionDatabaseRows(sessionID: session.id, root: root)
        try checkOperationCancellation()
        try deleteAppDatabaseRows(sessionID: session.id, root: root)
    }

    private func deleteSessionDatabaseRows(sessionID: String, root: URL) throws {
        let database = root.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return }

        let sql = """
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE;
        DELETE FROM thread_dynamic_tools WHERE thread_id = \(sqliteStringLiteral(sessionID));
        DELETE FROM thread_goals WHERE thread_id = \(sqliteStringLiteral(sessionID));
        DELETE FROM thread_spawn_edges WHERE parent_thread_id = \(sqliteStringLiteral(sessionID)) OR child_thread_id = \(sqliteStringLiteral(sessionID));
        DELETE FROM stage1_outputs WHERE thread_id = \(sqliteStringLiteral(sessionID));
        DELETE FROM agent_job_items WHERE assigned_thread_id = \(sqliteStringLiteral(sessionID));
        DELETE FROM threads WHERE id = \(sqliteStringLiteral(sessionID));
        COMMIT;
        PRAGMA foreign_keys = ON;
        """
        try runCommand(executable: "/usr/bin/sqlite3", arguments: [database.path, sql])
    }

    private func removeRolloutFiles(sessionID: String, root: URL) throws {
        for directory in ["sessions", "archived_sessions"] {
            try checkOperationCancellation()
            let dirURL = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                try checkOperationCancellation()
                guard fileURL.pathExtension == "jsonl",
                      fileURL.lastPathComponent.contains(sessionID),
                      fileManager.fileExists(atPath: fileURL.path) else {
                    continue
                }
                try fileManager.removeItem(at: fileURL)
                try removeEmptyParents(startingAt: fileURL.deletingLastPathComponent(), stopAt: dirURL)
            }
        }
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

    private func removeJSONLLines(matchingSessionID sessionID: String, from url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try checkOperationCancellation()
        let lines = try readLineData(url)
        var output = Data()

        for line in lines {
            try checkOperationCancellation()
            guard !line.isWhitespaceOrEmpty else { continue }
            if lineContainsSessionID(line, sessionID: sessionID) {
                continue
            }
            output.append(line)
            output.append(0x0A)
        }

        try output.write(to: url, options: .atomic)
    }

    private func lineContainsSessionID(_ line: Data, sessionID: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return String(decoding: line, as: UTF8.self).contains(sessionID)
        }
        if let value = object["session_id"] as? String, value == sessionID { return true }
        if let value = object["id"] as? String, value == sessionID { return true }
        if let value = object["thread_id"] as? String, value == sessionID { return true }
        return false
    }

    private func lineContainsAnySessionID(_ line: Data, sessionIDs: Set<String>) -> Bool {
        guard !sessionIDs.isEmpty else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            let text = String(decoding: line, as: UTF8.self)
            return sessionIDs.contains { text.contains($0) }
        }

        for key in ["session_id", "id", "thread_id"] {
            if let value = object[key] as? String, sessionIDs.contains(value) {
                return true
            }
        }

        let text = String(decoding: line, as: UTF8.self)
        return sessionIDs.contains { text.contains($0) }
    }

    private func restorableSessionIDs(from dataURL: URL, snapshotCodexRoot: String) throws -> Set<String> {
        let database = dataURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return [] }

        let rows = try loadSessionRows(from: database)
        let ids = rows.compactMap { row -> String? in
            resolvedRolloutFileURL(
                sessionID: row.id,
                rolloutPath: row.rolloutPath,
                dataRoot: dataURL,
                snapshotCodexRoot: snapshotCodexRoot
            ) == nil ? nil : row.id
        }
        return Set(ids)
    }

    private func removeShellSnapshots(sessionID: String, root: URL) throws {
        let shellDir = root.appendingPathComponent("shell_snapshots", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: shellDir, includingPropertiesForKeys: nil) else {
            return
        }

        for case let fileURL as URL in enumerator {
            try checkOperationCancellation()
            guard fileURL.lastPathComponent.contains(sessionID),
                  fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            try fileManager.removeItem(at: fileURL)
        }
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

    private func copyReplacing(src: URL, dst: URL) throws {
        try checkOperationCancellation()
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: dst.path) {
            try fileManager.removeItem(at: dst)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: src.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try copyDirectoryContents(src: src, dst: dst)
        } else {
            try fileManager.copyItem(at: src, to: dst)
        }
        try checkOperationCancellation()
    }

    private func copyDirectoryContents(src: URL, dst: URL) throws {
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

    private func mergeDirectory(src: URL, dst: URL) throws {
        try checkOperationCancellation()
        if !fileManager.fileExists(atPath: dst.path) {
            try copyReplacing(src: src, dst: dst)
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
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try copyReplacing(src: itemURL, dst: targetURL)
            }
        }
    }

    private func mergeLineFile(
        src: URL,
        dst: URL,
        uniqueKey: String?,
        allowedSessionIDs: Set<String>? = nil
    ) throws {
        try checkOperationCancellation()
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: dst.path) {
            if let allowedSessionIDs {
                try writeFilteredLineFile(src: src, dst: dst, uniqueKey: uniqueKey, allowedSessionIDs: allowedSessionIDs)
            } else {
                try copyReplacing(src: src, dst: dst)
            }
            return
        }

        let currentLines = try readLineData(dst)
        let snapshotLines = try readLineData(src)
        var merged: [Data] = []
        var seen = Set<String>()

        func addLine(_ line: Data, requiresAllowedSession: Bool) {
            guard !line.isWhitespaceOrEmpty else { return }
            if requiresAllowedSession,
               let allowedSessionIDs,
               !lineContainsAnySessionID(line, sessionIDs: allowedSessionIDs) {
                return
            }
            let identity = uniqueKey.flatMap { jsonLineIdentity(line, key: $0) } ?? line
                .base64EncodedString()
            guard !seen.contains(identity) else { return }
            seen.insert(identity)
            merged.append(line)
        }

        currentLines.forEach { addLine($0, requiresAllowedSession: false) }
        try checkOperationCancellation()
        snapshotLines.forEach { addLine($0, requiresAllowedSession: true) }

        var output = Data()
        for line in merged {
            output.append(line)
            output.append(0x0A)
        }
        try output.write(to: dst, options: .atomic)
        try checkOperationCancellation()
    }

    private func writeFilteredLineFile(
        src: URL,
        dst: URL,
        uniqueKey: String?,
        allowedSessionIDs: Set<String>
    ) throws {
        try checkOperationCancellation()
        let snapshotLines = try readLineData(src)
        var output = Data()
        var seen = Set<String>()

        for line in snapshotLines {
            try checkOperationCancellation()
            guard !line.isWhitespaceOrEmpty,
                  lineContainsAnySessionID(line, sessionIDs: allowedSessionIDs) else {
                continue
            }
            let identity = uniqueKey.flatMap { jsonLineIdentity(line, key: $0) } ?? line
                .base64EncodedString()
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            output.append(line)
            output.append(0x0A)
        }

        try output.write(to: dst, options: .atomic)
    }

    private func mergeJSONLLines(matchingSessionID sessionID: String, from src: URL, into dst: URL) throws {
        try checkOperationCancellation()
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let currentLines = fileManager.fileExists(atPath: dst.path) ? try readLineData(dst) : []
        let snapshotLines = try readLineData(src).filter { line in
            !line.isWhitespaceOrEmpty && lineContainsSessionID(line, sessionID: sessionID)
        }

        var merged: [Data] = []
        var seen = Set<String>()

        func addLine(_ line: Data) {
            guard !line.isWhitespaceOrEmpty else { return }
            let identity = line.base64EncodedString()
            guard !seen.contains(identity) else { return }
            seen.insert(identity)
            merged.append(line)
        }

        currentLines.forEach(addLine)
        try checkOperationCancellation()
        snapshotLines.forEach(addLine)

        var output = Data()
        for line in merged {
            output.append(line)
            output.append(0x0A)
        }
        try output.write(to: dst, options: .atomic)
    }

    private func restoreShellSnapshots(sessionID: String, from dataURL: URL, to root: URL) throws {
        let srcDir = dataURL.appendingPathComponent("shell_snapshots", isDirectory: true)
        let dstDir = root.appendingPathComponent("shell_snapshots", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: srcDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        for case let srcURL as URL in enumerator {
            try checkOperationCancellation()
            let values = try srcURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true, srcURL.lastPathComponent.contains(sessionID) else { continue }
            let dstURL = dstDir.appendingPathComponent(srcURL.lastPathComponent)
            try copyReplacing(src: srcURL, dst: dstURL)
        }
    }

    private func loadConversationMessages(for session: CodexSession) throws -> [ConversationMessage] {
        guard !session.rolloutPath.isEmpty else {
            throw VaultError.commandFailed("这个会话没有记录文件路径。")
        }
        let url = URL(fileURLWithPath: session.rolloutPath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw VaultError.commandFailed("会话文件不存在：\(session.rolloutPath)")
        }

        let lines = try readLineData(url)
        var eventMessages: [ConversationMessage] = []
        var responseMessages: [ConversationMessage] = []

        for (index, line) in lines.enumerated() {
            guard !line.isWhitespaceOrEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            let timestamp = parseCodexTimestamp(object["timestamp"] as? String)

            if type == "event_msg",
               let eventType = payload["type"] as? String,
               let message = conversationEventMessage(
                eventType: eventType,
                payload: payload,
                lineIndex: index,
                timestamp: timestamp
               ) {
                eventMessages.append(message)
            } else if type == "response_item",
                      let response = conversationResponseMessage(
                        payload: payload,
                        lineIndex: index,
                        timestamp: timestamp
                      ) {
                responseMessages.append(response)
            }
        }

        return eventMessages.isEmpty ? responseMessages : eventMessages
    }

    private func conversationEventMessage(
        eventType: String,
        payload: [String: Any],
        lineIndex: Int,
        timestamp: Date?
    ) -> ConversationMessage? {
        let role: String
        switch eventType {
        case "user_message":
            role = "用户"
        case "agent_message":
            role = "助手"
        default:
            return nil
        }

        let text = cleanConversationText(payload["message"] as? String ?? extractConversationText(from: payload["content"]))
        guard !text.isEmpty else { return nil }

        return ConversationMessage(
            id: "event-\(lineIndex)",
            role: role,
            phase: payload["phase"] as? String,
            timestamp: timestamp,
            text: text
        )
    }

    private func conversationResponseMessage(
        payload: [String: Any],
        lineIndex: Int,
        timestamp: Date?
    ) -> ConversationMessage? {
        guard payload["type"] as? String == "message",
              let rawRole = payload["role"] as? String,
              ["user", "assistant"].contains(rawRole) else {
            return nil
        }

        let text = cleanConversationText(extractConversationText(from: payload["content"]))
        guard !text.isEmpty else { return nil }

        return ConversationMessage(
            id: "response-\(lineIndex)",
            role: conversationRoleLabel(rawRole),
            phase: payload["phase"] as? String,
            timestamp: timestamp,
            text: text
        )
    }

    private func extractConversationText(from value: Any?) -> String {
        if let text = value as? String {
            return text
        }

        if let parts = value as? [Any] {
            return parts
                .map { extractConversationText(from: $0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }

        if let object = value as? [String: Any] {
            for key in ["text", "message", "content", "input", "output"] {
                let text = extractConversationText(from: object[key])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }

        return ""
    }

    private func cleanConversationText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func conversationRoleLabel(_ role: String) -> String {
        switch role.lowercased() {
        case "user":
            return "用户"
        case "assistant":
            return "助手"
        default:
            return role
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

    private func mergeStateDatabase(src: URL, dst: URL, allowedSessionIDs: Set<String>? = nil) throws {
        if let allowedSessionIDs, allowedSessionIDs.isEmpty {
            return
        }

        let sqlite = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: sqlite) else { throw VaultError.sqliteUnavailable }

        if !fileManager.fileExists(atPath: dst.path) {
            try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sql = "VACUUM INTO \(sqliteStringLiteral(dst.path));"
            try runCommand(executable: sqlite, arguments: [src.path, sql])
            try purgeAccountBindings(database: dst, sqlite: sqlite)
            if let allowedSessionIDs {
                try pruneStateDatabase(database: dst, sqlite: sqlite, allowedSessionIDs: allowedSessionIDs)
            }
            return
        }

        let statements = try stateDatabaseMergeStatements(src: src, dst: dst, allowedSessionIDs: allowedSessionIDs)
        guard !statements.isEmpty else { return }

        let sql = """
        PRAGMA foreign_keys = OFF;
        ATTACH DATABASE \(sqliteStringLiteral(src.path)) AS snapshot;
        BEGIN IMMEDIATE;
        \(statements.joined(separator: "\n"))
        COMMIT;
        DETACH DATABASE snapshot;
        PRAGMA foreign_keys = ON;
        """
        try runCommand(executable: sqlite, arguments: [dst.path, sql])
    }

    private func mergeSingleSessionStateDatabase(src: URL, dst: URL, sessionID: String) throws {
        let sqlite = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: sqlite) else { throw VaultError.sqliteUnavailable }

        let statements = try singleSessionStateDatabaseMergeStatements(src: src, dst: dst, sessionID: sessionID)
        guard !statements.isEmpty else { return }

        let sql = """
        PRAGMA foreign_keys = OFF;
        ATTACH DATABASE \(sqliteStringLiteral(src.path)) AS snapshot;
        BEGIN IMMEDIATE;
        \(statements.joined(separator: "\n"))
        COMMIT;
        DETACH DATABASE snapshot;
        PRAGMA foreign_keys = ON;
        """
        try runCommand(executable: sqlite, arguments: [dst.path, sql])
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

    private func repairStateDatabaseRolloutPaths(database: URL, root: URL, sessionIDs: Set<String>) throws {
        for sessionID in sessionIDs {
            guard let rolloutURL = findRolloutFile(sessionID: sessionID, root: root) else { continue }
            let relPath = relativePath(rolloutURL, under: root)
            try updateThreadRolloutPath(
                database: database,
                sessionID: sessionID,
                rolloutPath: rolloutURL.path,
                archived: relPath?.hasPrefix("archived_sessions/")
            )
        }
    }

    private func purgeAccountBindings(database: URL, sqlite: String) throws {
        let sql = """
        DELETE FROM device_key_bindings WHERE EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'device_key_bindings');
        DELETE FROM remote_control_enrollments WHERE EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'remote_control_enrollments');
        """
        _ = try? runCommand(executable: sqlite, arguments: [database.path, sql])
    }

    private func stateDatabaseMergeStatements(
        src: URL,
        dst: URL,
        allowedSessionIDs: Set<String>? = nil
    ) throws -> [String] {
        var statements: [String] = []
        for table in conversationStateTables {
            let sourceColumns = try sqliteTableColumns(database: src, table: table)
            let destColumns = try sqliteTableColumns(database: dst, table: table)
            let commonColumns = destColumns.filter { sourceColumns.contains($0) }
            guard !commonColumns.isEmpty else { continue }

            let columnList = commonColumns.map(sqliteIdentifier).joined(separator: ", ")
            let whereClause = stateDatabaseWhereClause(table: table, allowedSessionIDs: allowedSessionIDs)
            statements.append(
                "INSERT OR REPLACE INTO \(sqliteIdentifier(table)) (\(columnList)) SELECT \(columnList) FROM snapshot.\(sqliteIdentifier(table))\(whereClause);"
            )
        }
        return statements
    }

    private func pruneStateDatabase(database: URL, sqlite: String, allowedSessionIDs: Set<String>) throws {
        if allowedSessionIDs.isEmpty {
            let sql = """
            PRAGMA foreign_keys = OFF;
            BEGIN IMMEDIATE;
            DELETE FROM thread_dynamic_tools;
            DELETE FROM thread_goals;
            DELETE FROM thread_spawn_edges;
            DELETE FROM stage1_outputs;
            DELETE FROM threads;
            COMMIT;
            PRAGMA foreign_keys = ON;
            """
            try runCommand(executable: sqlite, arguments: [database.path, sql])
            return
        }

        let ids = allowedSessionIDs.map(sqliteStringLiteral).joined(separator: ", ")
        let sql = """
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE;
        DELETE FROM thread_dynamic_tools WHERE thread_id NOT IN (\(ids));
        DELETE FROM thread_goals WHERE thread_id NOT IN (\(ids));
        DELETE FROM thread_spawn_edges WHERE parent_thread_id NOT IN (\(ids)) AND child_thread_id NOT IN (\(ids));
        DELETE FROM stage1_outputs WHERE thread_id NOT IN (\(ids));
        DELETE FROM threads WHERE id NOT IN (\(ids));
        COMMIT;
        PRAGMA foreign_keys = ON;
        """
        try runCommand(executable: sqlite, arguments: [database.path, sql])
    }

    private func stateDatabaseWhereClause(table: String, allowedSessionIDs: Set<String>?) -> String {
        guard let allowedSessionIDs else { return "" }
        guard !allowedSessionIDs.isEmpty else { return " WHERE 0" }

        let ids = allowedSessionIDs.map(sqliteStringLiteral).joined(separator: ", ")
        switch table {
        case "threads":
            return " WHERE id IN (\(ids))"
        case "thread_spawn_edges":
            return " WHERE parent_thread_id IN (\(ids)) OR child_thread_id IN (\(ids))"
        default:
            return " WHERE thread_id IN (\(ids))"
        }
    }

    private func singleSessionStateDatabaseMergeStatements(src: URL, dst: URL, sessionID: String) throws -> [String] {
        var statements: [String] = []
        let quotedSessionID = sqliteStringLiteral(sessionID)

        func appendInsert(table: String, whereClause: String) throws {
            let sourceColumns = try sqliteTableColumns(database: src, table: table)
            let destColumns = try sqliteTableColumns(database: dst, table: table)
            let commonColumns = destColumns.filter { sourceColumns.contains($0) }
            guard !commonColumns.isEmpty else { return }

            let columnList = commonColumns.map(sqliteIdentifier).joined(separator: ", ")
            statements.append(
                "INSERT OR REPLACE INTO \(sqliteIdentifier(table)) (\(columnList)) SELECT \(columnList) FROM snapshot.\(sqliteIdentifier(table)) WHERE \(whereClause);"
            )
        }

        try appendInsert(table: "threads", whereClause: "id = \(quotedSessionID)")
        try appendInsert(table: "thread_goals", whereClause: "thread_id = \(quotedSessionID)")
        try appendInsert(table: "thread_dynamic_tools", whereClause: "thread_id = \(quotedSessionID)")
        try appendInsert(table: "stage1_outputs", whereClause: "thread_id = \(quotedSessionID)")
        try appendInsert(table: "thread_spawn_edges", whereClause: "parent_thread_id = \(quotedSessionID) OR child_thread_id = \(quotedSessionID)")

        return statements
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
        for directory in ["sessions", "archived_sessions"] {
            try checkOperationCancellation()
            let dirURL = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }

            var didCopyDirectory = false
            for case let fileURL as URL in enumerator {
                try checkOperationCancellation()
                guard fileURL.pathExtension == "jsonl",
                      sessionIDs.contains(where: { fileURL.lastPathComponent.contains($0) }),
                      let relPath = relativePath(fileURL, under: root) else {
                    continue
                }

                try copyReplacing(src: fileURL, dst: dataURL.appendingPathComponent(relPath))
                didCopyDirectory = true
            }

            if didCopyDirectory {
                includedPaths.insert(directory)
            }
        }
    }

    private func copyShellSnapshots(
        sessionIDs: Set<String>,
        from root: URL,
        to dataURL: URL,
        includedPaths: inout Set<String>
    ) throws {
        try checkOperationCancellation()
        let shellDir = root.appendingPathComponent("shell_snapshots", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: shellDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        var didCopy = false
        for case let fileURL as URL in enumerator {
            try checkOperationCancellation()
            guard sessionIDs.contains(where: { fileURL.lastPathComponent.contains($0) }) else {
                continue
            }
            let dst = dataURL
                .appendingPathComponent("shell_snapshots", isDirectory: true)
                .appendingPathComponent(fileURL.lastPathComponent)
            try copyReplacing(src: fileURL, dst: dst)
            didCopy = true
        }

        if didCopy {
            includedPaths.insert("shell_snapshots")
        }
    }

    @discardableResult
    private func copyExternalAttachments(sessionIDs: Set<String>, from dataURL: URL) throws -> Bool {
        guard !sessionIDs.isEmpty else { return false }
        try checkOperationCancellation()
        var records: [ExternalAttachmentRecord] = []
        var seen = Set<String>()

        for sessionID in sessionIDs {
            try checkOperationCancellation()
            guard let rolloutURL = findRolloutFile(sessionID: sessionID, root: dataURL) else { continue }
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
                    ExternalAttachmentRecord(
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

    private func restoreExternalAttachments(sessionIDs: Set<String>?, from dataURL: URL) throws {
        try checkOperationCancellation()
        let manifestURL = dataURL.appendingPathComponent("external_attachments/manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }
        let manifest = try JSONDecoder.snapshot.decode(
            ExternalAttachmentManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        for record in manifest.records {
            try checkOperationCancellation()
            if let sessionIDs, !sessionIDs.contains(record.sessionID) {
                continue
            }
            let src = dataURL.appendingPathComponent(record.storedRelativePath)
            let dst = URL(fileURLWithPath: record.originalPath)
            guard fileManager.fileExists(atPath: src.path),
                  !fileManager.fileExists(atPath: dst.path) else {
                continue
            }
            try copyReplacing(src: src, dst: dst)
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

        let restorableIDs = try restorableSessionIDs(from: dataURL, snapshotCodexRoot: snapshotCodexRoot)
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
        for sessionID in sessionIDs {
            try checkOperationCancellation()
            guard let rolloutURL = findRolloutFile(sessionID: sessionID, root: dataRoot),
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

    private func snapshotSessionCounts(dataURL: URL, sessionIDs: Set<String>) -> (active: Int, archived: Int) {
        var active = 0
        var archived = 0

        for sessionID in sessionIDs {
            guard let rolloutURL = findRolloutFile(sessionID: sessionID, root: dataURL),
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
        for snapshot in sorted.dropFirst(limit) {
            try checkOperationCancellation()
            let url = snapshotRootURL.appendingPathComponent(snapshot.id, isDirectory: true)
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
            "stage1_outputs"
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
            try restore(snapshot: snapshot, mode: mode)
            try report(1.0, "恢复完成", mode.successMessage)
            return .ok(message: "\(snapshot.name)：\(mode.successMessage)")

        case .restoreSnapshotSession:
            guard let snapshot = command.snapshot,
                  let session = command.sessions.first else {
                throw VaultError.invalidSnapshot
            }
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
            try restoreSingleSession(snapshot: snapshot, session: session)
            try report(1.0, "恢复完成：\(session.displayTitle)", "会话文件、历史索引和线程记录已合并。")
            return .ok(message: "已恢复单个会话：\(session.displayTitle)")

        case .restoreSnapshotSessions:
            guard let snapshot = command.snapshot,
                  !command.sessions.isEmpty else {
                throw VaultError.invalidSnapshot
            }
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
            let total = max(command.sessions.count, 1)
            for (index, session) in command.sessions.enumerated() {
                try checkCancellation()
                let fraction = 0.20 + (0.75 * Double(index) / Double(total))
                try report(
                    fraction,
                    "正在恢复 \(index + 1)/\(total)：\(session.displayTitle)",
                    "正在复制会话文件并合并 Codex 本地索引。"
                )
                try restoreSingleSession(snapshot: snapshot, session: session)
            }
            try report(1.0, "批量恢复完成", "已恢复 \(command.sessions.count) 个会话。")
            return .ok(message: "已从 \(snapshot.name) 批量恢复 \(command.sessions.count) 个会话")

        case .deleteSnapshots:
            let total = max(command.snapshots.count, 1)
            for (index, snapshot) in command.snapshots.enumerated() {
                try checkCancellation()
                try report(
                    0.05 + (0.90 * Double(index) / Double(total)),
                    "正在删除快照 \(index + 1)/\(total)...",
                    snapshot.name
                )
                let url = snapshotRootURL.appendingPathComponent(snapshot.id, isDirectory: true)
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
            try report(0.08, "正在创建删除前恢复点...", "只保存即将删除的会话。")
            _ = try createSessionProtectionSnapshot(
                name: command.sessions.count == 1 ? "Pre-Delete Session Backup" : "Pre-Delete Sessions Backup",
                reason: "pre-delete-session",
                sessions: command.sessions
            )
            let total = max(command.sessions.count, 1)
            for (index, session) in command.sessions.enumerated() {
                try checkCancellation()
                try report(
                    0.25 + (0.70 * Double(index) / Double(total)),
                    "正在删除会话 \(index + 1)/\(total)：\(session.displayTitle)",
                    "正在清理会话文件、history.jsonl、session_index.jsonl 和 SQLite 线程记录。"
                )
                try delete(session: session)
            }
            try report(1.0, "会话删除完成", "已删除 \(command.sessions.count) 个会话。")
            return .ok(message: "已删除 \(command.sessions.count) 个会话")

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
            try report(0.08, "正在创建自动找回前备份...", "正在保护当前 Codex 会话状态。")
            _ = try createSystemSnapshot(
                name: "Pre-Auto-Restore Backup",
                reason: "pre-auto-restore",
                candidatePaths: autoProtectionCandidates
            )
            try report(0.50, "正在自动找回会话...", "正在合并快照里的会话文件和索引。")
            try checkCancellation()
            try restore(snapshot: snapshot, mode: .conversationsOnly)
            try report(1.0, "自动找回完成", "已从 \(snapshot.name) 合并恢复。")
            return .ok(message: "已自动找回会话：从 \(snapshot.name) 合并恢复，保留当前账号和模型供应商配置")
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

            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

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

private enum ConversationLogParser {
    static func loadMessages(rolloutPath: String) throws -> [ConversationMessage] {
        guard !rolloutPath.isEmpty else {
            throw VaultError.commandFailed("这个会话没有记录文件路径。")
        }

        let url = URL(fileURLWithPath: rolloutPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.commandFailed("会话文件不存在：\(rolloutPath)")
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let text = String(decoding: data, as: UTF8.self)
        var eventMessages: [ConversationMessage] = []
        var responseMessages: [ConversationMessage] = []
        eventMessages.reserveCapacity(256)
        responseMessages.reserveCapacity(128)

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if isEventMessageLine(line),
               let message = parseEventMessage(line, lineIndex: index) {
                eventMessages.append(message)
                continue
            }

            if eventMessages.isEmpty,
               isResponseMessageLine(line),
               let message = parseResponseMessage(line, lineIndex: index) {
                responseMessages.append(message)
            }
        }

        return eventMessages.isEmpty ? responseMessages : eventMessages
    }

    private static func isEventMessageLine(_ line: Substring) -> Bool {
        line.contains(#""event_msg""#)
            && (line.contains(#""user_message""#) || line.contains(#""agent_message""#))
    }

    private static func isResponseMessageLine(_ line: Substring) -> Bool {
        line.contains(#""response_item""#)
            && line.contains(#""message""#)
            && (line.contains(#""user""#) || line.contains(#""assistant""#))
    }

    private static func parseEventMessage(_ line: Substring, lineIndex: Int) -> ConversationMessage? {
        guard let object = jsonObject(from: line),
              let payload = object["payload"] as? [String: Any],
              let eventType = payload["type"] as? String else {
            return nil
        }

        let role: String
        switch eventType {
        case "user_message":
            role = "用户"
        case "agent_message":
            role = "助手"
        default:
            return nil
        }

        let text = cleanText(payload["message"] as? String ?? extractText(from: payload["content"]))
        guard !text.isEmpty else { return nil }

        return ConversationMessage(
            id: "event-\(lineIndex)",
            role: role,
            phase: payload["phase"] as? String,
            timestamp: parseTimestamp(object["timestamp"] as? String),
            text: text
        )
    }

    private static func parseResponseMessage(_ line: Substring, lineIndex: Int) -> ConversationMessage? {
        guard let object = jsonObject(from: line),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              let rawRole = payload["role"] as? String,
              ["user", "assistant"].contains(rawRole) else {
            return nil
        }

        let text = cleanText(extractText(from: payload["content"]))
        guard !text.isEmpty else { return nil }

        return ConversationMessage(
            id: "response-\(lineIndex)",
            role: rawRole == "user" ? "用户" : "助手",
            phase: payload["phase"] as? String,
            timestamp: parseTimestamp(object["timestamp"] as? String),
            text: text
        )
    }

    private static func jsonObject(from line: Substring) -> [String: Any]? {
        let lineData = Data(line.utf8)
        return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
    }

    private static func extractText(from value: Any?) -> String {
        if let text = value as? String {
            return text
        }

        if let parts = value as? [Any] {
            return parts
                .map { extractText(from: $0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }

        if let object = value as? [String: Any] {
            for key in ["text", "message", "content", "input", "output"] {
                let text = extractText(from: object[key])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }

        return ""
    }

    private static func cleanText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }
}

@main
struct CodexSessionVaultApp: App {
    @StateObject private var model = VaultModel(refreshOnInit: CommandLine.arguments.dropFirst().first != "--worker")

    init() {
        _ = VaultWorkerProcess.runFromCommandLine(arguments: CommandLine.arguments)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("创建快照") { model.createManualSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command])
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
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Picker("功能", selection: sectionBinding) {
                        ForEach(AppSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Spacer()
                    Toggle("打开时自动找回", isOn: $model.autoRestoreOnLaunch)
                        .toggleStyle(.switch)
                        .help("启动 app 时自动从最新会话保护点找回丢失的对话，不覆盖账号和模型供应商配置")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 10)
                Divider()

                switch model.selectedSection ?? .sessions {
                case .sessions:
                    SessionsPane()
                case .snapshots:
                    SnapshotPane()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
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
        .sheet(isPresented: $model.isConversationViewerPresented) {
            if let session = model.conversationViewerSession {
                ConversationViewer(session: session, messages: model.conversationMessages)
                    .environmentObject(model)
                    .frame(minWidth: 760, minHeight: 620)
            } else {
                ContentUnavailableView("没有会话内容", systemImage: "bubble.left")
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
        .onAppear {
            model.clearSessionSearch()
            model.runLaunchAutoRestoreIfNeeded()
        }
    }
}

struct AppSidebar: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("codex_会话管理")
                    .font(.title2.bold())
                Text("管理、删除、备份和恢复 Codex 对话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                CurrentStateCard(state: model.currentState)
            }
            .padding()

            List(selection: $model.selectedSection) {
                Section("功能") {
                    Label("会话管理", systemImage: "bubble.left.and.bubble.right")
                        .tag(AppSection.sessions)
                    Label("快照恢复", systemImage: "archivebox")
                        .tag(AppSection.snapshots)
                }
            }
        }
        .frame(minWidth: 300)
    }
}

struct CurrentStateCard: View {
    let state: CurrentCodexState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("当前 Codex 状态", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            InfoLine("Provider", state.modelProvider)
            InfoLine("Model", state.model)
            InfoLine("Account", state.accountFingerprint)
            InfoLine("Sessions", "\(state.sessionCount) active / \(state.archivedSessionCount) archived")
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
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
                    .background(snapshot.isManualSnapshot ? .blue.opacity(0.14) : .orange.opacity(0.14), in: Capsule())
            }
            Text("\(snapshot.modelProvider) / \(snapshot.model)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(snapshot.createdAt.formatted(date: .numeric, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

struct SessionsPane: View {
    @EnvironmentObject private var model: VaultModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("会话列表")
                            .font(.largeTitle.bold())
                        Text("单击选中会话；双击查看对话记录；右键可从快照恢复指定会话。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CountBadge(value: "\(model.filteredSessions.count) / \(model.sessions.count)")
                }

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
                    Divider()
                        .frame(height: 22)
                    Button("全选可见") { model.checkAllVisibleSessions() }
                        .disabled(model.filteredSessions.isEmpty)
                    if !model.checkedSessionIDs.isEmpty {
                        Button("清空选择") { model.clearCheckedSessions() }
                        Button("删除选中 \(model.checkedSessionIDs.count)", role: .destructive) {
                            model.deleteCheckedSessions()
                        }
                        .disabled(model.isBusy)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))

                if model.filteredSessions.isEmpty {
                    ContentUnavailableView(
                        "没有匹配会话",
                        systemImage: "magnifyingglass",
                        description: Text("换个关键词，或清空搜索条件。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedSessionID) {
                        ForEach(model.filteredSessions) { session in
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
                            .tag(session.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .padding(24)
            .frame(minWidth: 460)
            .onChange(of: model.sessionSearch) { _, _ in
                model.selectFirstVisibleSessionIfNeeded()
            }
            .onChange(of: model.showArchivedSessions) { _, _ in
                model.selectFirstVisibleSessionIfNeeded()
            }

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
            .frame(minWidth: 560)
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
                        .background(.orange.opacity(0.16), in: Capsule())
                }
                if !session.existsOnDisk {
                    Text("缺文件")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.14), in: Capsule())
                }
            }
            Text("\(session.modelProvider) / \(session.model) · \(session.source)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(session.updatedAt.formatted(date: .numeric, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
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
                    MetricCard(title: "来源", value: session.source, systemImage: "terminal")
                    MetricCard(title: "文件状态", value: session.existsOnDisk ? "存在" : "缺失", systemImage: "doc.text")
                }

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

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("快照恢复")
                            .font(.largeTitle.bold())
                        Text("用于切换账号后找回或回滚对话。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CountBadge(value: "\(model.filteredSnapshots.count) / \(model.snapshots.count)")
                }

                HStack(spacing: 10) {
                    TextField("快照备注，可留空", text: $model.snapshotName)
                        .textFieldStyle(.roundedBorder)
                    Button("创建快照") {
                        model.createManualSnapshot()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(model.isBusy)
                    Divider()
                        .frame(height: 22)
                    Picker("类型", selection: $model.snapshotFilter) {
                        ForEach(SnapshotFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Button("全选") { model.checkAllSnapshots() }
                        .disabled(model.filteredSnapshots.isEmpty)
                    if !model.checkedSnapshotIDs.isEmpty {
                        Button("清空选择") { model.clearCheckedSnapshots() }
                        Button("删除选中 \(model.checkedSnapshotIDs.count)", role: .destructive) {
                            model.deleteCheckedSnapshots()
                        }
                        .disabled(model.isBusy)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))

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
            }
            .padding(24)
            .frame(minWidth: 390)
            .onAppear {
                model.refreshSelectedSnapshotSessions()
            }
            .onChange(of: model.selectedID) { _, _ in
                model.clearCheckedSnapshotSessions()
                model.refreshSelectedSnapshotSessions()
            }
            .onChange(of: model.snapshotFilter) { _, _ in
                model.selectFirstVisibleSnapshotIfNeeded()
                model.clearCheckedSnapshotSessions()
                model.refreshSelectedSnapshotSessions()
            }

            VStack(alignment: .leading, spacing: 18) {
                if let snapshot = model.selectedSnapshot {
                    SnapshotDetail(snapshot: snapshot)
                } else {
                    ContentUnavailableView(
                        "没有选中快照",
                        systemImage: "archivebox",
                        description: Text("先创建一个快照，或从左侧选择已有快照。")
                    )
                }
                Spacer()
            }
            .padding(24)
            .frame(minWidth: 590)
        }
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
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(isSelected ? .blue.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CountBadge: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.title3.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.25), in: Capsule())
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
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
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
            content()
        }
        .padding(14)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
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
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(14)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
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
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
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
                .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                Spacer()
                Text(model.codexRoot)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !model.autoRestoreOnLaunch {
                    Text("自动找回：关闭")
                        .foregroundStyle(.tertiary)
                }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
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

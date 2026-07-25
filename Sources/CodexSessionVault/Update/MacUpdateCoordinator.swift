import AppKit
import CodexSessionVaultCore
import Darwin
import Foundation
import Sparkle

@MainActor
final class MacUpdateCoordinator: ObservableObject {
    @Published private(set) var state: UpdatePresentationState = .idle
    @Published private(set) var isPresented = false

    private static let scheduledInterval = Duration.seconds(8 * 60 * 60)

    private let model: VaultModel
    private let currentVersion: String
    private let currentBuild: Int
    private let checkClient: UpdateCheckClient?
    private let stateStore: MacUpdateStateStore
    private let auditLogger: UpdateActionAuditLogger
    private let sparkleDriver: SparkleUpdateDriver
    private let updater: SPUUpdater

    private var machine = UpdatePresentationMachine()
    private var scheduleTask: Task<Void, Never>?
    private var checkInProgress = false
    private var didStart = false
    private var updaterStartError: String?
    private var targetManifest: ReleaseManifest?
    private var downloadReceived: UInt64 = 0
    private var downloadTotal: UInt64?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private let attemptGate = UpdateAttemptGate<SPUUserUpdateChoice>()
    private var terminationRetryAttempted = false
    private var installWhenReady = false
    private var deferredReady = false
    private var backupDrainedForInstall = false

    private var targetVersion: String? { targetManifest?.version }

    init(model: VaultModel, bundle: Bundle = .main) {
        self.model = model
        self.currentVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        self.currentBuild = Int(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        ) ?? 0

        let baseURL = (bundle.object(forInfoDictionaryKey: "CSKUpdateBaseURL") as? String)
            .flatMap(URL.init(string:))
        if let baseURL,
           let encodedKey = bundle.object(forInfoDictionaryKey: "CSKManifestPublicKey") as? String,
           let publicKey = Data(base64Encoded: encodedKey),
           publicKey.count == 32 {
            self.checkClient = UpdateCheckClient(
                baseURL: baseURL,
                publicKey: publicKey,
                transport: URLSessionUpdateTransport(timeout: 5),
                timeout: .seconds(5)
            )
        } else {
            self.checkClient = nil
        }
        let vaultURL = URL(fileURLWithPath: model.vaultRoot, isDirectory: true)
        self.stateStore = MacUpdateStateStore(
            url: vaultURL.appendingPathComponent("update-state.json")
        )
        self.auditLogger = UpdateActionAuditLogger(
            url: vaultURL.appendingPathComponent("update-audit.jsonl"),
            platform: "macos-arm64"
        )

        let driver = SparkleUpdateDriver()
        self.sparkleDriver = driver
        self.updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: driver,
            delegate: nil
        )
        driver.delegate = self
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
        } catch {
            updaterStartError = error.localizedDescription
        }

        let persistedState = stateStore.load()
        if persistedState.pendingVersion == currentVersion {
            transition(.completed(version: currentVersion), present: true)
        }

        scheduleTask = Task { [weak self] in
            do {
                let initialDelay = Self.initialScheduledDelay(
                    lastCheckAt: persistedState.lastCheckAt,
                    now: Date()
                )
                try await Task.sleep(for: initialDelay)
            } catch {
                return
            }
            guard let self else { return }
            await self.check(silentUnavailable: true)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.scheduledInterval)
                } catch {
                    return
                }
                await self.check(silentUnavailable: true)
            }
        }
    }

    func checkNow() {
        if case .ready = state {
            isPresented = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        Task { await check(silentUnavailable: false) }
    }

    func remindLater() {
        isPresented = false
        if case .ready = state { return }
        transition(.dismiss)
    }

    func beginDownload() {
        guard MacUpdateConsentPolicy.allows(.beginDownload, in: state),
              case .available(let version, _) = state else {
            return
        }
        guard updaterStartError == nil else {
            transition(.failed(message: "更新功能配置失败，请联系管理员"), present: true)
            return
        }
        guard targetManifest?.version == version else {
            transition(.failed(message: "更新版本不匹配，请联系管理员"), present: true)
            return
        }
        guard !attemptGate.isBusy else { return }

        let currentState = state
        recordAudit(.downloadConfirmationRequested, version: version)
        _ = MacUpdateConsentPolicy.perform(
            .beginDownload,
            in: currentState,
            confirmation: { [weak self] in
                guard let self else { return false }
                let confirmed = self.showDownloadConfirmation(version: version)
                self.recordAudit(
                    confirmed ? .downloadConfirmed : .downloadCancelled,
                    version: version
                )
                return confirmed
            },
            operation: { [weak self] in
                guard let self else { return }
                guard self.attemptGate.beginRequest() else { return }
                self.recordAudit(.downloadRequested, version: version)
                self.installWhenReady = false
                self.deferredReady = false
                self.updater.checkForUpdates()
            }
        )
    }

    func deferRestart() {
        guard case .ready = state else { return }
        deferredReady = true
        isPresented = false
        _ = attemptGate.resolveReadyReply(.dismiss)
    }

    func restartAndInstall() async {
        guard MacUpdateConsentPolicy.allows(.restartAndInstall, in: state),
              case .ready(let version) = state else {
            return
        }
        let currentState = state
        recordAudit(.installConfirmationRequested, version: version)
        _ = await MacUpdateConsentPolicy.performAsync(
            .restartAndInstall,
            in: currentState,
            confirmation: { [weak self] in
                guard let self else { return false }
                let confirmed = self.showInstallConfirmation(version: version)
                self.recordAudit(
                    confirmed ? .installConfirmed : .installCancelled,
                    version: version
                )
                return confirmed
            },
            operation: { [weak self] in
                guard let self else { return }
                await self.performRestartAndInstall(version: version)
            }
        )
    }

    private func performRestartAndInstall(version: String) async {
        recordAudit(.installRequested, version: version)
        terminationRetryAttempted = false
        guard await model.prepareForUpdate(timeout: .seconds(5)) else {
            cancelPendingUpdateSession(resumeBackup: false)
            transition(
                .failed(message: "备份仍在写入，已取消更新重启，请稍后重试"),
                present: true
            )
            return
        }

        backupDrainedForInstall = true
        do {
            try stateStore.setPendingVersion(version)
        } catch {
            cancelPendingUpdateSession(resumeBackup: true)
            transition(.failed(message: "更新状态保存失败，请稍后重试"), present: true)
            return
        }

        deferredReady = false
        if attemptGate.resolveReadyReply(.install) {
            installWhenReady = false
        } else {
            guard attemptGate.beginRequest() else {
                cancelPendingUpdateSession(resumeBackup: true)
                transition(.failed(message: "更新会话仍在处理中，请稍后重试"), present: true)
                return
            }
            installWhenReady = true
            updater.checkForUpdates()
        }
    }

    func acknowledge() {
        if case .completed = state {
            try? stateStore.setPendingVersion(nil)
        }
        isPresented = false
        transition(.dismiss)
    }

    private func check(silentUnavailable: Bool) async {
        guard !checkInProgress else { return }
        checkInProgress = true
        defer { checkInProgress = false }

        if !silentUnavailable {
            transition(.checkStarted, present: true)
        }
        try? stateStore.setLastCheckAt(Date())

        guard let checkClient else {
            if !silentUnavailable {
                transition(.failed(message: "更新功能配置失败，请联系管理员"), present: true)
            }
            return
        }

        let result = await checkClient.check(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            platform: .macosArm64
        )
        switch result {
        case .available(let manifest, _):
            targetManifest = manifest
            transition(
                .found(version: manifest.version, notes: manifest.notes),
                present: true
            )
        case .upToDate:
            targetManifest = nil
            if silentUnavailable {
                if case .checking = state { transition(.dismiss) }
            } else {
                transition(.upToDate(version: currentVersion), present: true)
            }
        case .unavailable:
            if silentUnavailable {
                if case .checking = state { transition(.dismiss) }
            } else {
                transition(.failed(message: "暂时无法连接公司更新服务器，请稍后重试"), present: true)
            }
        case .invalid(let message):
            targetManifest = nil
            transition(.failed(message: message), present: true)
        }
    }

    private func transition(_ event: UpdatePresentationEvent, present: Bool? = nil) {
        machine.apply(event)
        state = machine.state
        if let present {
            isPresented = present
        }
    }

    private static func initialScheduledDelay(lastCheckAt: Date?, now: Date) -> Duration {
        guard let lastCheckAt else { return .seconds(5) }
        let nextCheck = lastCheckAt.addingTimeInterval(8 * 60 * 60)
        return .seconds(max(5, nextCheck.timeIntervalSince(now)))
    }

    private func resumeBackupIfNeeded() {
        guard backupDrainedForInstall else { return }
        backupDrainedForInstall = false
        model.resumeBackupAfterCancelledUpdate()
    }

    private func cancelPendingUpdateSession(resumeBackup: Bool) {
        _ = attemptGate.cancelPendingSession(with: .dismiss)
        terminationRetryAttempted = false
        model.revokeUpdateTerminationApproval()
        installWhenReady = false
        deferredReady = false
        if resumeBackup {
            resumeBackupIfNeeded()
        }
    }

    private func showDownloadConfirmation(version: String) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现公司版本 \(version)"
        alert.informativeText = "是否开始下载更新？下载前不会关闭应用。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确认下载")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showInstallConfirmation(version: String) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更新已经下载完成"
        alert.informativeText = "应用将关闭并安装 \(version)，是否继续？"
        alert.addButton(withTitle: "稍后安装")
        alert.addButton(withTitle: "重启并安装")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func recordAudit(_ event: UpdateActionAuditEvent, version: String) {
        try? auditLogger.record(event, version: version)
    }
}

extension MacUpdateCoordinator: SparkleUpdateDriverDelegate {
    func sparkleCheckStarted(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        transition(.checkStarted, present: true)
    }

    func acceptSparkleItem(
        displayVersion: String,
        buildVersion: String,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        checkCancellation = nil
        guard attemptGate.hasRequestInFlight,
              let targetManifest,
              targetManifest.matchesSparkleItem(
                displayVersion: displayVersion,
                buildVersion: buildVersion
              ) else {
            attemptGate.endRequest()
            installWhenReady = false
            reply(.dismiss)
            resumeBackupIfNeeded()
            transition(.failed(message: "更新版本不匹配，请联系管理员"), present: true)
            return
        }
        attemptGate.endRequest()
        reply(.install)
    }

    func sparkleUpdateNotFound() {
        checkCancellation = nil
        attemptGate.endRequest()
        installWhenReady = false
        resumeBackupIfNeeded()
        transition(.upToDate(version: currentVersion), present: true)
    }

    func sparkleUpdaterFailed() {
        checkCancellation = nil
        downloadCancellation = nil
        cancelPendingUpdateSession(resumeBackup: true)
        recordAudit(.updateFailed, version: targetVersion ?? currentVersion)
        transition(.failed(message: "更新失败，请稍后重试"), present: true)
    }

    func sparkleDownloadStarted(cancellation: @escaping () -> Void) {
        checkCancellation = nil
        downloadCancellation = cancellation
        downloadReceived = 0
        downloadTotal = nil
        recordAudit(.downloadStarted, version: targetVersion ?? currentVersion)
        transition(.downloadStarted(version: targetVersion ?? currentVersion), present: true)
    }

    func setDownloadTotal(_ total: UInt64) {
        downloadTotal = total > 0 ? total : nil
        transition(.downloadProgress(
            version: targetVersion ?? currentVersion,
            received: downloadReceived,
            total: downloadTotal
        ))
    }

    func addDownloadedBytes(_ length: UInt64) {
        let (sum, overflow) = downloadReceived.addingReportingOverflow(length)
        downloadReceived = overflow ? UInt64.max : sum
        transition(.downloadProgress(
            version: targetVersion ?? currentVersion,
            received: downloadReceived,
            total: downloadTotal
        ))
    }

    func sparkleExtractionStarted() {
        downloadCancellation = nil
        transition(.extractionProgress(version: targetVersion ?? currentVersion, progress: 0))
    }

    func setExtractionProgress(_ progress: Double) {
        transition(.extractionProgress(
            version: targetVersion ?? currentVersion,
            progress: progress
        ))
    }

    func holdReadyReply(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        attemptGate.holdReadyReply(reply, resolvingPreviousWith: .dismiss)
        recordAudit(.downloadReady, version: targetVersion ?? currentVersion)
        if installWhenReady && backupDrainedForInstall {
            installWhenReady = false
            transition(.installStarted(version: targetVersion ?? currentVersion), present: true)
            _ = attemptGate.resolveReadyReply(.install)
            return
        }
        deferredReady = false
        transition(.downloadReady(version: targetVersion ?? currentVersion), present: true)
    }

    func sparkleInstallStarted(
        applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        recordAudit(.installStarted, version: targetVersion ?? currentVersion)
        transition(.installStarted(version: targetVersion ?? currentVersion), present: true)
        guard !applicationTerminated, !terminationRetryAttempted else { return }
        terminationRetryAttempted = true
        model.approveUpdateTerminationRetry()
        retryTerminatingApplication()
    }

    func sparkleInstallCompleted() {
        backupDrainedForInstall = false
        installWhenReady = false
        terminationRetryAttempted = false
        model.revokeUpdateTerminationApproval()
        recordAudit(.installCompleted, version: targetVersion ?? currentVersion)
        transition(.completed(version: targetVersion ?? currentVersion), present: true)
    }

    func sparkleDismissed() {
        checkCancellation = nil
        downloadCancellation = nil
        attemptGate.endRequest()
        attemptGate.discardReadyReply()
        terminationRetryAttempted = false
        model.revokeUpdateTerminationApproval()
        let abandonedInstall = installWhenReady
        installWhenReady = false
        if abandonedInstall {
            resumeBackupIfNeeded()
        }
        if deferredReady {
            transition(.downloadReady(version: targetVersion ?? currentVersion), present: false)
            return
        }
        if case .completed = state { return }
        transition(.dismiss, present: false)
    }

    func revealUpdateInFocus() {
        isPresented = true
    }
}

private struct MacUpdateDiskState {
    var lastCheckAt: Date?
    var pendingVersion: String?
}

private struct MacUpdateStateStore {
    let url: URL

    func load() -> MacUpdateDiskState {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MacUpdateDiskState()
        }
        let formatter = ISO8601DateFormatter()
        return MacUpdateDiskState(
            lastCheckAt: (object["lastCheckAt"] as? String).flatMap(formatter.date(from:)),
            pendingVersion: object["pendingVersion"] as? String
        )
    }

    func setLastCheckAt(_ date: Date) throws {
        var value = load()
        value.lastCheckAt = date
        try save(value)
    }

    func setPendingVersion(_ version: String?) throws {
        var value = load()
        value.pendingVersion = version
        try save(value)
    }

    private func save(_ value: MacUpdateDiskState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        var object: [String: String] = [:]
        if let lastCheckAt = value.lastCheckAt {
            object["lastCheckAt"] = formatter.string(from: lastCheckAt)
        }
        if let pendingVersion = value.pendingVersion {
            object["pendingVersion"] = pendingVersion
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)

        let temporaryURL = directory.appendingPathComponent(
            ".update-state-\(UUID().uuidString).tmp"
        )
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

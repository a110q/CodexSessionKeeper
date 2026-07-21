import AppKit
import CodexSessionVaultCore
import Darwin
import Foundation
import Sparkle

@MainActor
final class MacUpdateCoordinator: ObservableObject {
    @Published private(set) var state: UpdatePresentationState = .idle
    @Published private(set) var isPresented = false

    private static let fallbackBaseURL = URL(
        string: "http://192.168.10.99:18080/codex-session-keeper/stable/"
    )!
    private static let scheduledInterval = Duration.seconds(8 * 60 * 60)

    private let model: VaultModel
    private let currentVersion: String
    private let currentBuild: Int
    private let checkClient: UpdateCheckClient?
    private let stateStore: MacUpdateStateStore
    private let sparkleDriver: SparkleUpdateDriver
    private let updater: SPUUpdater

    private var machine = UpdatePresentationMachine()
    private var scheduleTask: Task<Void, Never>?
    private var checkInProgress = false
    private var didStart = false
    private var updaterStartError: String?
    private var targetVersion: String?
    private var downloadReceived: UInt64 = 0
    private var downloadTotal: UInt64?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var retryTermination: (() -> Void)?
    private var installRequested = false
    private var deferredReady = false
    private var backupDrainedForInstall = false

    init(model: VaultModel, bundle: Bundle = .main) {
        self.model = model
        self.currentVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        self.currentBuild = Int(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        ) ?? 0

        let baseURL = (bundle.object(forInfoDictionaryKey: "CSKUpdateBaseURL") as? String)
            .flatMap(URL.init(string:)) ?? Self.fallbackBaseURL
        if let encodedKey = bundle.object(forInfoDictionaryKey: "CSKManifestPublicKey") as? String,
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
        self.stateStore = MacUpdateStateStore(
            url: URL(fileURLWithPath: model.vaultRoot, isDirectory: true)
                .appendingPathComponent("update-state.json")
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
        guard case .available(let version, _) = state else { return }
        guard updaterStartError == nil else {
            transition(.failed(message: "更新功能配置失败，请联系管理员"), present: true)
            return
        }
        targetVersion = version
        installRequested = true
        deferredReady = false
        updater.checkForUpdates()
    }

    func deferRestart() {
        guard case .ready = state else { return }
        deferredReady = true
        isPresented = false
        let reply = readyReply
        readyReply = nil
        reply?(.dismiss)
    }

    func restartAndInstall() async {
        guard case .ready(let version) = state else { return }
        guard await model.prepareForUpdate(timeout: .seconds(5)) else {
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
            resumeBackupIfNeeded()
            transition(.failed(message: "更新状态保存失败，请稍后重试"), present: true)
            return
        }

        deferredReady = false
        if let reply = readyReply {
            readyReply = nil
            reply(.install)
        } else {
            installRequested = true
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
            targetVersion = manifest.version
            transition(
                .found(version: manifest.version, notes: manifest.notes),
                present: true
            )
        case .upToDate:
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
}

extension MacUpdateCoordinator: SparkleUpdateDriverDelegate {
    func sparkleCheckStarted(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        transition(.checkStarted, present: true)
    }

    func acceptSparkleItem(
        version: String,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        checkCancellation = nil
        guard installRequested, version == targetVersion else {
            installRequested = false
            reply(.dismiss)
            transition(.failed(message: "更新版本不匹配，请联系管理员"), present: true)
            return
        }
        installRequested = false
        reply(.install)
    }

    func sparkleUpdateNotFound() {
        checkCancellation = nil
        resumeBackupIfNeeded()
        transition(.upToDate(version: currentVersion), present: true)
    }

    func sparkleUpdaterFailed() {
        checkCancellation = nil
        downloadCancellation = nil
        readyReply = nil
        retryTermination = nil
        resumeBackupIfNeeded()
        transition(.failed(message: "更新失败，请稍后重试"), present: true)
    }

    func sparkleDownloadStarted(cancellation: @escaping () -> Void) {
        checkCancellation = nil
        downloadCancellation = cancellation
        downloadReceived = 0
        downloadTotal = nil
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
        if let previous = readyReply {
            readyReply = nil
            previous(.dismiss)
        }
        readyReply = reply
        deferredReady = false
        transition(.downloadReady(version: targetVersion ?? currentVersion), present: true)
    }

    func sparkleInstallStarted(
        applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        transition(.installStarted(version: targetVersion ?? currentVersion), present: true)
    }

    func sparkleInstallCompleted() {
        backupDrainedForInstall = false
        transition(.completed(version: targetVersion ?? currentVersion), present: true)
    }

    func sparkleDismissed() {
        checkCancellation = nil
        downloadCancellation = nil
        readyReply = nil
        retryTermination = nil
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

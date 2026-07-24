import Foundation
import Testing

@Suite(.serialized)
struct MacNASWiringContractTests {
    @Test
    func appUsesNASRuntimeAndLogicalRecoveryIdentityWithoutLocalFallback() throws {
        let source = try macAppSource()

        #expect(source.contains("startLocalIncrementalBackup") == false)
        #expect(source.contains("private var localBackupAgent") == false)
        #expect(source.contains("incrementalRecoverySource: NASRecoverySourceIdentity?"))
        #expect(source.contains("IncrementalRecoveryRestorer(paths:"))
        #expect(source.contains("BackupRecoveryBuilder(paths:") == false)
        #expect(source.contains("@Published private(set) var nasSetupSnapshot"))
        #expect(source.contains("@Published var nasDepartments"))
        #expect(source.contains("@Published var nasEmployees"))
        #expect(source.contains("@Published var nasRecoverySources"))
    }

    @Test
    func firstRunSetupHasNoPathFieldAndCannotBeDismissedWhileUnconfigured() throws {
        let source = try macAppSource()

        #expect(source.contains("struct NASSetupView: View"))
        #expect(source.contains("检测公司 NAS"))
        #expect(source.contains("重新检测 NAS"))
        #expect(source.contains("更换 NAS 备份身份"))
        #expect(source.contains("model.onboardingDecision.preventDismissal"))
        #expect(source.contains("!model.isManualNASReconfiguration"))
        #expect(source.contains("fileImporter") == false)
    }

    @Test
    func terminationGuardWarnsForEveryBusyNASWorkPhase() throws {
        let source = try macAppSource()

        #expect(source.contains("applicationShouldTerminate"))
        #expect(source.contains("NAS 备份尚未完成，仍要退出吗？"))
        #expect(source.contains("nasSetupSnapshot.state == .seeding"))
        #expect(source.contains("nasSetupSnapshot.state == .pending"))
        #expect(source.contains("|| model.nasSetupSnapshot.state == .verifying"))
    }

    @Test
    func applicationLifecycleForwardsActivationAndWakeScansAndRemovesObserver() throws {
        let source = try macAppSource()

        #expect(source.contains("func applicationDidBecomeActive"))
        #expect(source.contains("requestNASBackupScan(.activation)"))
        #expect(source.contains("NSWorkspace.shared.notificationCenter"))
        #expect(source.contains("NSWorkspace.didWakeNotification"))
        #expect(source.contains("requestNASBackupScan(.wake)"))
        #expect(source.contains("removeObserver"))
    }

    @Test
    func configuredNASAutomaticallyEnablesAndSurfacesLaunchAtLoginState() throws {
        let source = try macAppSource()

        #expect(source.contains("MacLaunchAtLoginController"))
        #expect(source.contains("@Published private(set) var launchAtLoginSnapshot"))
        #expect(source.contains("ensureLaunchAtLoginEnabled()"))
        #expect(source.contains("func retryLaunchAtLogin()"))
        #expect(source.contains("func openLoginItemSettings()"))
        #expect(source.contains("修复开机自启"))
        #expect(source.contains("打开登录项设置"))
    }

    @Test
    func loginItemLaunchHidesTheInitialWindowWithoutChangingManualLaunches() throws {
        let source = try macAppSource()

        #expect(source.contains("keyAELaunchedAsLogInItem"))
        #expect(source.contains("launchedAsLoginItem"))
        #expect(source.contains("NSApp.hide(nil)"))
    }

    @Test
    func startupWorkersAndSnapshotsEnforceLocalVaultPermissions() throws {
        let source = try macAppSource()

        #expect(source.contains("LocalVaultPermissionHardener().prepareVault(at: vaultURL)"))
        #expect(source.contains("LocalVaultPermissionHardener().hardenTree(at: snapshotURL)"))
        #expect(source.contains("permissions: 0o600"))
        #expect(source.contains("parentDirectoryPermissions: 0o700"))
        #expect(source.contains("try? fileManager.removeItem(at: snapshotURL)"))
    }

    @Test
    func failedVaultPreparationGuardsNASActivationAndScanBeforeRuntimeSideEffects() throws {
        let source = try macAppSource()
        let activation = try modelFunctionSource("activateSelectedNASIdentity()", in: source)
        let scan = try modelFunctionSource("requestNASBackupScan(_ trigger: BackupScanTrigger)", in: source)
        let activationGuard = try #require(activation.range(of: "try ensureVaultPrepared()"))
        let activationSideEffect = try #require(activation.range(of: "nasRuntime.activate("))
        let scanGuard = try #require(scan.range(of: "try ensureVaultPrepared()"))
        let scanSideEffect = try #require(scan.range(of: "nasRuntime.requestImmediateScan(trigger)"))
        let activationBeforeSideEffect = activation[..<activationSideEffect.lowerBound]
        let scanBeforeSideEffect = scan[..<scanSideEffect.lowerBound]

        #expect(source.contains("private func ensureVaultPrepared() throws"))
        #expect(activationGuard.lowerBound < activationSideEffect.lowerBound)
        #expect(scanGuard.lowerBound < scanSideEffect.lowerBound)
        #expect(activationBeforeSideEffect.contains("catch {") && activationBeforeSideEffect.contains("return"))
        #expect(scanBeforeSideEffect.contains("catch {") && scanBeforeSideEffect.contains("return"))
        #expect(try modelFunctionSource("ensureDirectories() throws", in: source).contains("try ensureVaultPrepared()"))
        #expect(try modelFunctionSource("runWorker(", in: source).contains("try ensureVaultPrepared()"))
    }

    @Test
    func snapshotRestorePreflightsSQLiteConflictsBeforeProtectionSideEffects() throws {
        let source = try macAppSource()
        let preflight = try modelFunctionSource("preflightSessionRestore(", in: source)

        #expect(preflight.contains("StateDatabaseRestoreService().preflightMerge("))
        #expect(preflight.contains("checkDatabaseConflicts"))
        #expect(source.contains("checkDatabaseConflicts: mode != .full"))
    }

    @Test
    func snapshotRestoreTracksDestinationsThatMustRemainMissing() throws {
        let source = try macAppSource()
        let preflight = try modelFunctionSource("preflightSessionRestore(", in: source)
        let publish = try modelFunctionSource("publishSessionRestore(", in: source)

        #expect(source.contains("let missingDestinationFiles: [SessionFileAbsenceExpectation]"))
        #expect(preflight.contains("SessionFileAbsenceExpectation.requireMissing("))
        #expect(publish.contains("try preflight.validateCurrent()"))
    }

    @Test
    func snapshotRestorePublishesOnlyJsonlBytesFrozenDuringPreflight() throws {
        let source = try macAppSource()
        let preflight = try modelFunctionSource("preflightSessionRestore(", in: source)
        let publish = try modelFunctionSource("publishSessionRestore(", in: source)

        #expect(source.contains("let lineMutations: [SessionRestoreLineMutation]"))
        #expect(preflight.contains("SessionJSONLRestoreOutput.build("))
        #expect(publish.contains("for mutation in preflight.lineMutations"))
        #expect(publish.contains("mergeLineFile(") == false)
        #expect(publish.contains("writeFilteredLineFile(") == false)
    }

    @Test
    func snapshotRestoreUpdatesRolloutPathsInsideTheSQLiteTransaction() throws {
        let source = try macAppSource()
        let conversations = try modelFunctionSource("restoreConversationsOnly(", in: source)

        #expect(conversations.contains("rolloutPathUpdates: try rolloutPathUpdates(for: sessionPreflight)"))
        #expect(conversations.contains("repairStateDatabaseRolloutPaths(") == false)
    }

    @Test
    func sessionScopedOperationsNeverIdentifyShellSnapshotsByFilenameSubstring() throws {
        let source = try macAppSource()

        #expect(source.contains("copyShellSnapshots(") == false)
        #expect(source.contains("restoreShellSnapshots(") == false)
        #expect(source.contains("removeShellSnapshots(") == false)
        #expect(source.contains("lastPathComponent.contains(sessionID)") == false)
    }

    @Test
    func protectionSnapshotsMaterializeTheFrozenSecurityPlan() throws {
        let source = try macAppSource()
        let protection = try modelFunctionSource("createSessionProtectionSnapshot(", in: source)

        #expect(protection.contains("SessionProtectionSnapshotPlan.preflight("))
        #expect(protection.contains("protectionPlan.materialize()"))
        #expect(protection.contains("SessionDeletionPlan.preflight(") == false)
        #expect(protection.contains("writeFilteredLineFile(") == false)
        #expect(protection.contains("copyRolloutFiles(") == false)
    }

    @Test
    func conversationViewerRevalidatesTheSessionFileAndReleasesMessagesWhenDismissed() throws {
        let source = try macAppSource()
        let open = try modelFunctionSource("openConversationViewer(for session: CodexSession)", in: source)

        #expect(open.contains("TrustedSessionFileResolver.resolve("))
        #expect(open.contains("ConversationLogParser.loadMessages(from: trusted)"))
        #expect(open.contains("let rolloutPath = session.rolloutPath") == false)
        #expect(source.contains("func dismissConversationViewer()"))
        let dismiss = try modelFunctionSource("dismissConversationViewer()", in: source)
        #expect(dismiss.contains("conversationLoadTask?.cancel()"))
        #expect(dismiss.contains("conversationMessages.removeAll(keepingCapacity: false)"))
        #expect(source.contains("onDismiss: { model.dismissConversationViewer() }"))
    }

    @Test
    func sessionListBuildsOneTrustedRolloutIndexInsteadOfRescanningForEveryDatabaseRow() throws {
        let source = try macAppSource()
        let load = try modelFunctionSource("loadSessionsFromStateDatabase(", in: source)

        #expect(load.contains("TrustedSessionFileResolver.index(under: dataRoot)"))
        #expect(load.contains("resolvedRolloutFileURL(") == false)
        #expect(load.components(separatedBy: "TrustedSessionFileResolver.index(").count - 1 == 1)
    }

    @Test
    func batchSnapshotHelpersUseOneTrustedIndexInsteadOfPerSessionDirectoryScans() throws {
        let source = try macAppSource()
        let signatures = [
            "restorableSessionIDs(",
            "copyExternalAttachments(",
            "repairSnapshotStateDatabaseRolloutPaths(",
            "snapshotSessionCounts("
        ]

        for signature in signatures {
            let function = try modelFunctionSource(signature, in: source)
            #expect(function.contains("TrustedSessionFileResolver.index(under:"))
            #expect(function.contains("findRolloutFile(") == false)
        }
    }

    @Test
    func automaticRecoveryPreferenceMigratesOnceAndPersistsExplicitChoice() throws {
        let source = try macAppSource()

        #expect(source.contains("autoRestoreOnLaunch = AutoRestorePreference.load()"))
        #expect(source.contains("AutoRestorePreference.save(autoRestoreOnLaunch)"))
        #expect(source.contains("UserDefaults.standard.set(false, forKey: Self.autoRestoreDefaultsKey)") == false)
    }

    @Test
    func employeeGuidanceUsesRealNASStateAndProvidesOfflineHelp() throws {
        let source = try macAppSource()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let guidance = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexSessionVault/EmployeeGuidanceViews.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("EmployeeOnboardingPolicy.evaluate("))
        #expect(source.contains("employeeOnboardingVersion"))
        #expect(source.contains("employeeOnboardingInProgress"))
        #expect(source.contains("EmployeeHelpView("))
        #expect(source.contains(".interactiveDismissDisabled("))
        #expect(source.contains("model.onboardingDecision.preventDismissal"))
        #expect(source.contains("model.canActivateSelectedNASIdentity"))
        #expect(guidance.contains("EmployeeGuidanceCatalog.helpTopics"))
        #expect(guidance.contains("struct EmployeeHelpView: View"))
        #expect(guidance.contains("连接公司 NAS"))
        #expect(guidance.contains("完成首次备份"))
    }

    private func macAppSource() throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Sources/CodexSessionVault/main.swift"),
            encoding: .utf8
        )
    }

    private func modelFunctionSource(_ signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: "func \(signature)"))
        let remainder = source[start.lowerBound...]
        let openingBrace = try #require(remainder.firstIndex(of: "{"))
        var depth = 0
        for index in remainder[openingBrace...].indices {
            switch remainder[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(remainder[...index])
                }
            default: break
            }
        }
        throw MacNASWiringContractTestError.unterminatedFunction(signature)
    }
}

private enum MacNASWiringContractTestError: Error {
    case unterminatedFunction(String)
}

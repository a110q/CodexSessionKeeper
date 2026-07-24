import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("Employee onboarding")
struct EmployeeOnboardingTests {
    @Test
    func unconfiguredIsForcedAndRunningCompletesOnlyRealProgress() {
        let unconfigured = EmployeeOnboardingPolicy.evaluate(
            snapshot: .unconfigured,
            storedVersion: 0,
            inProgress: false,
            catalogReady: false,
            selectionValid: false
        )
        #expect(unconfigured.step == 1)
        #expect(unconfigured.presentSetup)
        #expect(unconfigured.preventDismissal)
        #expect(unconfigured.nextInProgress)
        #expect(!unconfigured.shouldMarkComplete)
        #expect(!unconfigured.canActivate)

        let catalogLoaded = EmployeeOnboardingPolicy.evaluate(
            snapshot: .unconfigured,
            storedVersion: 0,
            inProgress: true,
            catalogReady: true,
            selectionValid: true
        )
        #expect(catalogLoaded.step == 2)
        #expect(catalogLoaded.presentSetup)
        #expect(catalogLoaded.preventDismissal)
        #expect(catalogLoaded.canActivate)

        let running = EmployeeOnboardingPolicy.evaluate(
            snapshot: configuredSnapshot(state: .running),
            storedVersion: 0,
            inProgress: true,
            catalogReady: false,
            selectionValid: false
        )
        #expect(running.step == 3)
        #expect(!running.presentSetup)
        #expect(running.shouldMarkComplete)
        #expect(!running.nextInProgress)
    }

    @Test
    func catalogWithoutValidIdentityCannotActivate() {
        let decision = EmployeeOnboardingPolicy.evaluate(
            snapshot: .unconfigured,
            storedVersion: 0,
            inProgress: true,
            catalogReady: true,
            selectionValid: false
        )

        #expect(decision.step == 2)
        #expect(!decision.canActivate)
    }

    @Test
    func existingConfiguredUpgradeDoesNotForceIdentitySelection() {
        let decision = EmployeeOnboardingPolicy.evaluate(
            snapshot: configuredSnapshot(state: .disconnected),
            storedVersion: 0,
            inProgress: false,
            catalogReady: false,
            selectionValid: false
        )
        #expect(!decision.presentSetup)
        #expect(!decision.preventDismissal)

        let validating = EmployeeOnboardingPolicy.evaluate(
            snapshot: configuredSnapshot(state: .validating),
            storedVersion: 0,
            inProgress: false,
            catalogReady: false,
            selectionValid: false
        )
        #expect(validating.step == 3)
        #expect(!validating.presentSetup)
    }

    @Test
    func firstRunNeverCompletesBeforeRunning() {
        for state in [NASSetupState.disconnected, .validating, .seeding, .verifying, .pending, .error] {
            let decision = EmployeeOnboardingPolicy.evaluate(
                snapshot: configuredSnapshot(state: state),
                storedVersion: 0,
                inProgress: true,
                catalogReady: false,
                selectionValid: false
            )
            #expect(decision.presentSetup)
            #expect(decision.preventDismissal)
            #expect(!decision.shouldMarkComplete)
            #expect(decision.nextInProgress)
        }
    }

    @Test
    func guidanceUsesTheApprovedEightTitlesAndFourTopics() {
        let expected: [(NASSetupState, String)] = [
            (.unconfigured, "尚未选择部门和姓名"),
            (.disconnected, "未检测到公司 NAS"),
            (.validating, "正在验证备份目录"),
            (.seeding, "正在进行首次备份"),
            (.verifying, "正在确认 NAS 文件完整"),
            (.running, "备份已验证"),
            (.pending, "有会话等待补传"),
            (.error, "备份出现异常"),
        ]
        for (state, title) in expected {
            #expect(EmployeeGuidanceCatalog.state(state).title == title)
        }
        #expect(EmployeeGuidanceCatalog.helpTopics.map(\.title) == [
            "安装与首次启动",
            "备份状态说明",
            "NAS 断开与异常处理",
            "会话恢复和更换电脑",
        ])
    }

    private func configuredSnapshot(state: NASSetupState) -> NASSetupSnapshot {
        NASSetupSnapshot(
            state: state,
            configuration: NASBackupConfiguration(
                endpoint: .production,
                department: "运营部",
                employee: "测试员工",
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                deviceName: "测试电脑",
                deviceDirectoryName: "device-0001"
            )
        )
    }
}

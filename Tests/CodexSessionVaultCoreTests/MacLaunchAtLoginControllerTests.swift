import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct MacLaunchAtLoginControllerTests {
    @Test
    func enabledServiceReportsEnabledWithoutRegisteringAgain() {
        var registrations = 0
        let controller = MacLaunchAtLoginController(
            status: { .enabled },
            register: { registrations += 1 },
            openSettings: {}
        )

        let snapshot = controller.ensureEnabled()

        #expect(snapshot == LaunchAtLoginSnapshot(enabled: true))
        #expect(registrations == 0)
    }

    @Test
    func missingServiceRegistersAndReturnsTheObservedFinalState() {
        var state = LaunchAtLoginServiceStatus.notRegistered
        var registrations = 0
        let controller = MacLaunchAtLoginController(
            status: { state },
            register: {
                registrations += 1
                state = .enabled
            },
            openSettings: {}
        )

        let snapshot = controller.ensureEnabled()

        #expect(snapshot == LaunchAtLoginSnapshot(enabled: true))
        #expect(registrations == 1)
    }

    @Test
    func approvalRequiredDoesNotReregisterAndExposesActionableState() {
        var registrations = 0
        let controller = MacLaunchAtLoginController(
            status: { .requiresApproval },
            register: { registrations += 1 },
            openSettings: {}
        )

        let snapshot = controller.ensureEnabled()

        #expect(snapshot.enabled == false)
        #expect(snapshot.requiresApproval)
        #expect(snapshot.message == "请在系统设置的登录项中允许 codex_会话管理。")
        #expect(registrations == 0)
    }

    @Test
    func registrationFailureDoesNotPretendAutostartIsEnabled() {
        let controller = MacLaunchAtLoginController(
            status: { .notRegistered },
            register: { throw InjectedLaunchAtLoginError.failed },
            openSettings: {}
        )

        let snapshot = controller.ensureEnabled()

        #expect(snapshot.enabled == false)
        #expect(snapshot.requiresApproval == false)
        #expect(snapshot.message?.contains("injected launch-at-login failure") == true)
    }

    @Test
    func openSystemSettingsUsesTheInjectedPlatformAction() {
        var opened = false
        let controller = MacLaunchAtLoginController(
            status: { .notRegistered },
            register: {},
            openSettings: { opened = true }
        )

        controller.openSystemSettings()

        #expect(opened)
    }
}

private enum InjectedLaunchAtLoginError: LocalizedError {
    case failed

    var errorDescription: String? {
        "injected launch-at-login failure"
    }
}

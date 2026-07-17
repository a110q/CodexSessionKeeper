import Foundation
import ServiceManagement

public enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

public struct LaunchAtLoginSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let requiresApproval: Bool
    public let message: String?

    public init(
        enabled: Bool,
        requiresApproval: Bool = false,
        message: String? = nil
    ) {
        self.enabled = enabled
        self.requiresApproval = requiresApproval
        self.message = message
    }
}

public final class MacLaunchAtLoginController {
    private let status: () -> LaunchAtLoginServiceStatus
    private let register: () throws -> Void
    private let openSettings: () -> Void

    public convenience init() {
        let service = SMAppService.mainApp
        self.init(
            status: {
                switch service.status {
                case .enabled:
                    return .enabled
                case .requiresApproval:
                    return .requiresApproval
                case .notRegistered:
                    return .notRegistered
                case .notFound:
                    return .notFound
                @unknown default:
                    return .notFound
                }
            },
            register: { try service.register() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }

    public init(
        status: @escaping () -> LaunchAtLoginServiceStatus,
        register: @escaping () throws -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.status = status
        self.register = register
        self.openSettings = openSettings
    }

    public func currentState() -> LaunchAtLoginSnapshot {
        snapshot(for: status())
    }

    public func ensureEnabled() -> LaunchAtLoginSnapshot {
        let initial = status()
        if initial == .enabled || initial == .requiresApproval {
            return snapshot(for: initial)
        }

        do {
            try register()
            return snapshot(for: status())
        } catch {
            let observed = status()
            if observed == .enabled || observed == .requiresApproval {
                return snapshot(for: observed)
            }
            return LaunchAtLoginSnapshot(
                enabled: false,
                message: "无法启用开机自启：\(error.localizedDescription)"
            )
        }
    }

    public func openSystemSettings() {
        openSettings()
    }

    private func snapshot(for status: LaunchAtLoginServiceStatus) -> LaunchAtLoginSnapshot {
        switch status {
        case .enabled:
            return LaunchAtLoginSnapshot(enabled: true)
        case .requiresApproval:
            return LaunchAtLoginSnapshot(
                enabled: false,
                requiresApproval: true,
                message: "请在系统设置的登录项中允许 codex_会话管理。"
            )
        case .notRegistered:
            return LaunchAtLoginSnapshot(
                enabled: false,
                message: "开机自启尚未启用。"
            )
        case .notFound:
            return LaunchAtLoginSnapshot(
                enabled: false,
                message: "系统找不到应用登录项，请先将软件放入“应用程序”文件夹。"
            )
        }
    }
}

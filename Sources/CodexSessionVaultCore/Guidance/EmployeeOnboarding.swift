import Foundation

public struct EmployeeOnboardingDecision: Equatable, Sendable {
    public let step: Int
    public let presentSetup: Bool
    public let preventDismissal: Bool
    public let shouldMarkComplete: Bool
    public let nextInProgress: Bool
    public let canActivate: Bool
}

public struct EmployeeStateGuidance: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let actionTitle: String?
}

public struct EmployeeHelpTopic: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
}

public enum EmployeeOnboardingPolicy {
    public static let currentVersion = 1

    public static func evaluate(
        snapshot: NASSetupSnapshot,
        storedVersion: Int,
        inProgress: Bool,
        catalogReady: Bool,
        selectionValid: Bool
    ) -> EmployeeOnboardingDecision {
        if snapshot.configuration == nil || snapshot.state == .unconfigured {
            return EmployeeOnboardingDecision(
                step: catalogReady ? 2 : 1,
                presentSetup: true,
                preventDismissal: true,
                shouldMarkComplete: false,
                nextInProgress: true,
                canActivate: catalogReady && selectionValid
            )
        }

        if snapshot.state == .running {
            return EmployeeOnboardingDecision(
                step: 3,
                presentSetup: false,
                preventDismissal: false,
                shouldMarkComplete: storedVersion < currentVersion || inProgress,
                nextInProgress: false,
                canActivate: false
            )
        }

        if inProgress {
            return EmployeeOnboardingDecision(
                step: snapshot.state == .disconnected ? 1 : 3,
                presentSetup: true,
                preventDismissal: true,
                shouldMarkComplete: false,
                nextInProgress: true,
                canActivate: false
            )
        }

        return EmployeeOnboardingDecision(
            step: snapshot.state == .disconnected ? 1 : 3,
            presentSetup: false,
            preventDismissal: false,
            shouldMarkComplete: false,
            nextInProgress: false,
            canActivate: false
        )
    }
}

public enum EmployeeGuidanceCatalog {
    public static func state(_ state: NASSetupState) -> EmployeeStateGuidance {
        switch state {
        case .unconfigured:
            EmployeeStateGuidance(
                title: "尚未选择部门和姓名",
                detail: "连接公司 NAS 后选择部门和姓名。",
                actionTitle: "开始配置"
            )
        case .disconnected:
            EmployeeStateGuidance(
                title: "未检测到公司 NAS",
                detail: "请先在 Finder 或资源管理器中重新连接公司共享盘。",
                actionTitle: "重新检测"
            )
        case .validating:
            EmployeeStateGuidance(
                title: "正在验证备份目录",
                detail: "正在确认目录和写入能力。",
                actionTitle: nil
            )
        case .seeding:
            EmployeeStateGuidance(
                title: "正在进行首次备份",
                detail: "请保持 NAS 连接，暂勿退出软件。",
                actionTitle: nil
            )
        case .verifying:
            EmployeeStateGuidance(
                title: "正在确认 NAS 文件完整",
                detail: "正在从 NAS 回读并校验备份。",
                actionTitle: nil
            )
        case .running:
            EmployeeStateGuidance(
                title: "备份已验证",
                detail: "会话已上传并通过回读校验。",
                actionTitle: nil
            )
        case .pending:
            EmployeeStateGuidance(
                title: "有会话等待补传",
                detail: "请保持 NAS 连接，软件会继续补传。",
                actionTitle: "立即重试"
            )
        case .error:
            EmployeeStateGuidance(
                title: "备份出现异常",
                detail: "请重新检测；仍失败时联系管理员。",
                actionTitle: "重新检测"
            )
        }
    }

    public static let helpTopics: [EmployeeHelpTopic] = [
        EmployeeHelpTopic(
            id: "install",
            title: "安装与首次启动",
            body: "安装后先连接 192.168.10.99 上的“文件中转站”，再在软件中选择部门和姓名，不需要手工选择目录。"
        ),
        EmployeeHelpTopic(
            id: "status",
            title: "备份状态说明",
            body: "只有显示“备份已验证”才表示上传和 NAS 回读校验都已完成。"
        ),
        EmployeeHelpTopic(
            id: "disconnect",
            title: "NAS 断开与异常处理",
            body: "先重新连接公司共享盘，再点击“重新检测”。仍失败时保留错误详情并联系管理员。"
        ),
        EmployeeHelpTopic(
            id: "recovery",
            title: "会话恢复和更换电脑",
            body: "打开“快照恢复”，选择 NAS 备份设备和缺失会话。恢复前软件会再次完整校验。"
        ),
    ]
}

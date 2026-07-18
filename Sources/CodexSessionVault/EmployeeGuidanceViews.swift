import SwiftUI
import CodexSessionVaultCore

struct EmployeeOnboardingStepsView: View {
    let currentStep: Int

    private let titles = ["连接公司 NAS", "选择部门和姓名", "完成首次备份"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                let step = index + 1
                Label(
                    title,
                    systemImage: step < currentStep ? "checkmark.circle.fill" : "\(step).circle"
                )
                .foregroundStyle(step <= currentStep ? Color.accentColor : .secondary)

                if index < titles.count - 1 {
                    Divider()
                        .frame(width: 20)
                }
            }
        }
        .font(.caption.weight(.semibold))
    }
}

struct EmployeeStateCard: View {
    let snapshot: NASSetupSnapshot

    var body: some View {
        let guidance = EmployeeGuidanceCatalog.state(snapshot.state)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(guidance.title, systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Text(guidance.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if snapshot.totalCount > 0 {
                    ProgressView(
                        value: Double(snapshot.completedCount),
                        total: Double(snapshot.totalCount)
                    )
                    Text(snapshot.progressSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSymbol: String {
        switch snapshot.state {
        case .running:
            "checkmark.shield.fill"
        case .validating, .seeding, .verifying:
            "arrow.triangle.2.circlepath"
        case .pending:
            "clock.badge.exclamationmark"
        case .disconnected, .error:
            "exclamationmark.triangle.fill"
        case .unconfigured:
            "person.crop.circle.badge.questionmark"
        }
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .running:
            .green
        case .disconnected, .error:
            .red
        case .pending:
            .orange
        default:
            .accentColor
        }
    }
}

struct EmployeeHelpView: View {
    @Environment(\.dismiss) private var dismiss

    let version: String
    let retryNAS: () -> Void
    let reconfigure: () -> Void
    let openRecovery: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(EmployeeGuidanceCatalog.helpTopics) { topic in
                    Section(topic.title) {
                        Text(topic.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("快捷操作") {
                    Button("重新检测 NAS", action: retryNAS)
                    Button("重新配置部门和姓名", action: reconfigure)
                    Button("打开恢复页面", action: openRecovery)
                }

                Section {
                    Text("版本 \(version)")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("使用帮助")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

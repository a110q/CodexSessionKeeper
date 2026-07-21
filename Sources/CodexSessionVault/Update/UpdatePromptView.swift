import CodexSessionVaultCore
import SwiftUI

struct UpdatePromptView: View {
    @EnvironmentObject private var coordinator: MacUpdateCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .checking:
            Text("正在检查更新…")
                .font(.title2.weight(.semibold))
            ProgressView()
        case .available(let version, let notes):
            Text("发现新版本 \(version)")
                .font(.title2.weight(.semibold))
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Text("• \(note)")
                    }
                }
            }
            HStack {
                Button("稍后提醒", action: coordinator.remindLater)
                Spacer()
                Button("立即更新", action: coordinator.beginDownload)
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let version, let received, let total):
            Text("正在下载 \(version)")
                .font(.title2.weight(.semibold))
            if let total, total > 0 {
                ProgressView(value: Double(received), total: Double(total))
                Text("\(formattedBytes(received)) / \(formattedBytes(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        case .extracting(let version, let progress):
            Text("正在准备 \(version)")
                .font(.title2.weight(.semibold))
            ProgressView(value: progress, total: 1)
        case .ready(let version):
            Text("版本 \(version) 已准备好")
                .font(.title2.weight(.semibold))
            Text("重启应用即可完成更新。")
                .foregroundStyle(.secondary)
            HStack {
                Button("稍后重启", action: coordinator.deferRestart)
                Spacer()
                Button("重启并更新") {
                    Task { await coordinator.restartAndInstall() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .installing(let version):
            Text("正在安装 \(version)…")
                .font(.title2.weight(.semibold))
            ProgressView()
        case .failed(let message):
            Text("更新未完成")
                .font(.title2.weight(.semibold))
            Text(message)
            acknowledgementButton
        case .upToDate(let version):
            Text("已是最新版本")
                .font(.title2.weight(.semibold))
            Text("当前版本：\(version)")
                .foregroundStyle(.secondary)
            acknowledgementButton
        case .completed(let version):
            Text("已更新到 \(version)")
                .font(.title2.weight(.semibold))
            acknowledgementButton
        }
    }

    private var acknowledgementButton: some View {
        HStack {
            Spacer()
            Button("知道了", action: coordinator.acknowledge)
                .buttonStyle(.borderedProminent)
        }
    }

    private func formattedBytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

# 员工首次使用引导与使用说明 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 macOS、Windows 增加由真实 NAS 状态驱动的三步首次使用引导、离线帮助面板、五页以内的跨平台安装说明 PDF，以及可追溯的内部发布目录。

**Architecture:** 两端继续复用现有 NAS 配置和运行时，不建立第二套备份状态。纯策略模块把 `NASSetupState`、本地引导版本和“引导进行中”标记转换成 UI 决策；UI 只渲染该决策。员工文档以 Markdown 为源，通过现有 Electron Chromium 打印为 PDF，发布脚本把两个安装包、PDF 和 SHA-256 汇总到版本化目录。

**Tech Stack:** Swift 6.2、SwiftUI、Foundation `UserDefaults`、Electron 43、Node.js `node:test`、HTML/CSS、Bash、Electron `webContents.printToPDF`。

## Global Constraints

- 固定公司 NAS 为 `192.168.10.99 / 文件中转站 / codex会话备份`。
- 员工只能选择实时枚举的部门和姓名，不增加任意路径输入或目录选择器。
- 只有真实状态为 `running` 且当前配置有效时，才能记录 `onboardingVersion = 1`。
- `unconfigured`、`disconnected`、`validating`、`seeding`、`verifying`、`pending`、`error` 均不得伪装为完成。
- 不修改 NAS 目录、manifest、verification、cursor、数据库 schema、现有 IPC channel 名称或现有 IPC 参数。
- 不新增运行时依赖；PDF 构建复用 Windows 工程已有的 Electron devDependency。
- 帮助离线可用，不增加账号、远程服务、视频教程或自动更新。
- PDF 不包含真实员工会话正文、账号、令牌、NAS 凭据或内部数据库内容。
- 现有未提交的会话查看器内存修复必须先单独提交，后续任务不得把它与引导功能混入同一提交。
- 本计划不推送远程、不发布到 NAS；发布目录生成后由管理员验收并手动开放只读权限。

---

## File Map

**Create**

- `Sources/CodexSessionVaultCore/Preferences/AutoRestorePreference.swift` — macOS 自动找回偏好的一次性默认关闭迁移。
- `Sources/CodexSessionVaultCore/Guidance/EmployeeOnboarding.swift` — macOS 纯引导策略、状态术语和帮助主题。
- `Sources/CodexSessionVault/EmployeeGuidanceViews.swift` — macOS 步骤条、状态卡和离线帮助视图。
- `Tests/CodexSessionVaultCoreTests/AutoRestorePreferenceTests.swift` — 偏好迁移测试。
- `Tests/CodexSessionVaultCoreTests/EmployeeOnboardingTests.swift` — Swift 引导状态机测试。
- `windows/codex_session_manager_electron/src/user-guidance.js` — Electron 主进程与 renderer 共用的 UMD 纯策略模块。
- `windows/codex_session_manager_electron/test/user-guidance.test.js` — Windows 引导策略和术语测试。
- `windows/codex_session_manager_electron/scripts/employee-guide-markdown.js` — 受限 Markdown 到安全 HTML 的转换器。
- `windows/codex_session_manager_electron/scripts/build-employee-guide.js` — 使用 Electron 生成 A4 PDF。
- `windows/codex_session_manager_electron/test/employee-guide-markdown.test.js` — 文档转换和 HTML 转义测试。
- `docs/员工安装与使用说明.md` — PDF 的受版本控制内容源。
- `docs/assets/employee-guide/*.png` — 匿名化的最终界面截图。
- `scripts/build_employee_guide.sh` — PDF 构建入口。
- `scripts/assemble_internal_release.sh` — 汇总双端安装包、PDF 和校验信息。

**Modify**

- `Sources/CodexSessionVault/main.swift` — 偏好加载、引导持久化、NAS 设置流程、帮助入口和 sheet。
- `Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift` — macOS UI 接线和双端术语契约。
- `windows/codex_session_manager_electron/src/settings.js` — 引导版本和进行中标记默认值。
- `windows/codex_session_manager_electron/src/main.js` — 在现有状态响应中调和引导持久化。
- `windows/codex_session_manager_electron/src/index.html` — 步骤条、进度区、帮助按钮和帮助 modal。
- `windows/codex_session_manager_electron/src/renderer.js` — 根据纯策略渲染设置流程和帮助操作。
- `windows/codex_session_manager_electron/src/styles.css` — 引导与帮助样式。
- `windows/codex_session_manager_electron/package.json` — 增加 `guide:pdf` 脚本。
- `windows/codex_session_manager_electron/test/backup/nas-runtime.test.js` — settings 默认值和补丁保留测试。
- `README.md`、`windows/codex_session_manager_electron/README_WIN10_EXE.md` — 员工下载和帮助入口说明。

---

### Task 0: 单独收口现有会话查看器内存修复

**Files:**
- Modify/commit only: `Sources/CodexSessionVault/main.swift`
- Modify/commit only: `Sources/CodexSessionVaultCore/Restore/SessionJSONLValidator.swift`
- Create/commit only: `Sources/CodexSessionVaultCore/Restore/ConversationLogParser.swift`
- Modify/commit only: `Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift`
- Create/commit only: `Tests/CodexSessionVaultCoreTests/ConversationLogParserTests.swift`

**Interfaces:**
- Consumes: 当前工作树中已经完成的流式会话解析修改。
- Produces: 一个干净、可追溯的基础提交，后续可以安全继续修改 `main.swift`。

- [ ] **Step 1: 确认设计提交之外只有五个预期文件未提交**

Run:

```bash
git status --short
```

Expected: 只出现上面列出的五个产品/测试文件；若出现其他文件，停止并逐项确认归属。

- [ ] **Step 2: 重新验证现有修复**

Run:

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
git diff --check
```

Expected: 301 项测试通过，Release 构建退出码为 0，`git diff --check` 无输出。

- [ ] **Step 3: 只提交这五个文件**

```bash
git add Sources/CodexSessionVault/main.swift \
  Sources/CodexSessionVaultCore/Restore/SessionJSONLValidator.swift \
  Sources/CodexSessionVaultCore/Restore/ConversationLogParser.swift \
  Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift \
  Tests/CodexSessionVaultCoreTests/ConversationLogParserTests.swift
git commit -m "fix(mac): stream conversation viewer loading"
```

Expected: 新提交只包含流式查看器修复，不包含本计划后续文件。

---

### Task 1: 修复 macOS 自动找回偏好的持久化

**Files:**
- Create: `Sources/CodexSessionVaultCore/Preferences/AutoRestorePreference.swift`
- Create: `Tests/CodexSessionVaultCoreTests/AutoRestorePreferenceTests.swift`
- Modify: `Sources/CodexSessionVault/main.swift`

**Interfaces:**
- Consumes: Foundation `UserDefaults`。
- Produces: `AutoRestorePreference.load(from:) -> Bool` 和 `AutoRestorePreference.save(_:to:)`。

- [ ] **Step 1: 写偏好迁移失败测试**

Create tests covering first-run default-off and subsequent persistence:

```swift
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("AutoRestorePreference")
struct AutoRestorePreferenceTests {
    @Test
    func firstMigrationForcesDefaultOffExactlyOnce() throws {
        let suite = "auto-restore-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AutoRestorePreference.valueKey)

        #expect(AutoRestorePreference.load(from: defaults) == false)
        #expect(defaults.bool(forKey: AutoRestorePreference.migrationKey))
    }

    @Test
    func explicitChoicePersistsAfterMigration() throws {
        let suite = "auto-restore-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = AutoRestorePreference.load(from: defaults)
        AutoRestorePreference.save(true, to: defaults)

        #expect(AutoRestorePreference.load(from: defaults))
    }
}
```

- [ ] **Step 2: 运行测试并确认失败**

```bash
swift test --filter AutoRestorePreferenceTests
```

Expected: FAIL，因为 `AutoRestorePreference` 尚不存在。

- [ ] **Step 3: 实现一次性迁移**

```swift
import Foundation

public enum AutoRestorePreference {
    public static let valueKey = "autoRestoreOnLaunch"
    public static let migrationKey = "autoRestoreDefaultOffMigrationV1"

    public static func load(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: migrationKey) else {
            defaults.set(false, forKey: valueKey)
            defaults.set(true, forKey: migrationKey)
            return false
        }
        return defaults.bool(forKey: valueKey)
    }

    public static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: migrationKey)
        defaults.set(enabled, forKey: valueKey)
    }
}
```

Modify `VaultModel`:

```swift
@Published var autoRestoreOnLaunch: Bool {
    didSet {
        AutoRestorePreference.save(autoRestoreOnLaunch)
        if autoRestoreOnLaunch, oldValue == false {
            runLaunchAutoRestoreIfNeeded(force: true)
        }
    }
}

// In init:
autoRestoreOnLaunch = AutoRestorePreference.load()
```

Delete the unconditional startup `set(false, forKey:)`.

- [ ] **Step 4: 验证测试和 app 接线**

```bash
swift test --filter AutoRestorePreferenceTests
swift test --filter MacNASWiringContractTests
swift build
```

Expected: all selected tests pass and build exits 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexSessionVaultCore/Preferences/AutoRestorePreference.swift \
  Sources/CodexSessionVault/main.swift \
  Tests/CodexSessionVaultCoreTests/AutoRestorePreferenceTests.swift
git commit -m "fix(mac): persist automatic recovery preference"
```

---

### Task 2: 建立 Swift 引导状态策略与统一术语

**Files:**
- Create: `Sources/CodexSessionVaultCore/Guidance/EmployeeOnboarding.swift`
- Create: `Tests/CodexSessionVaultCoreTests/EmployeeOnboardingTests.swift`

**Interfaces:**
- Consumes: `NASSetupSnapshot`、已保存版本、`onboardingInProgress`、`catalogReady`和 `selectionValid`。
- Produces:
  - `EmployeeOnboardingPolicy.evaluate(snapshot:storedVersion:inProgress:catalogReady:selectionValid:) -> EmployeeOnboardingDecision`
  - `EmployeeGuidanceCatalog.state(_:) -> EmployeeStateGuidance`
  - `EmployeeGuidanceCatalog.helpTopics`

- [ ] **Step 1: 写状态机失败测试**

```swift
import Foundation
import Testing
@testable import CodexSessionVaultCore

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
    #expect(!running.presentSetup)
    #expect(running.shouldMarkComplete)
    #expect(!running.nextInProgress)
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
```

Add a parameterized test asserting:

```swift
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
```

- [ ] **Step 2: 运行测试并确认失败**

```bash
swift test --filter EmployeeOnboardingTests
```

Expected: FAIL because policy/catalog types do not exist.

- [ ] **Step 3: 实现最小纯策略**

```swift
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
            return .init(step: catalogReady ? 2 : 1,
                         presentSetup: true,
                         preventDismissal: true,
                         shouldMarkComplete: false,
                         nextInProgress: true,
                         canActivate: catalogReady && selectionValid)
        }
        if snapshot.state == .running {
            return .init(step: 3, presentSetup: false, preventDismissal: false,
                         shouldMarkComplete: storedVersion < currentVersion || inProgress,
                         nextInProgress: false, canActivate: false)
        }
        if inProgress {
            let step = snapshot.state == .disconnected ? 1 : 3
            return .init(step: step, presentSetup: true, preventDismissal: true,
                         shouldMarkComplete: false, nextInProgress: true,
                         canActivate: false)
        }
        return .init(step: snapshot.state == .validating ? 1 : 3,
                     presentSetup: false, preventDismissal: false,
                     shouldMarkComplete: false, nextInProgress: false,
                     canActivate: false)
    }
}

public enum EmployeeGuidanceCatalog {
    public static func state(_ state: NASSetupState) -> EmployeeStateGuidance {
        switch state {
        case .unconfigured:
            .init(title: "尚未选择部门和姓名",
                  detail: "连接公司 NAS 后选择部门和姓名。",
                  actionTitle: "开始配置")
        case .disconnected:
            .init(title: "未检测到公司 NAS",
                  detail: "请先在 Finder 或资源管理器中重新连接公司共享盘。",
                  actionTitle: "重新检测")
        case .validating:
            .init(title: "正在验证备份目录", detail: "正在确认目录和写入能力。", actionTitle: nil)
        case .seeding:
            .init(title: "正在进行首次备份", detail: "请保持 NAS 连接，暂勿退出软件。", actionTitle: nil)
        case .verifying:
            .init(title: "正在确认 NAS 文件完整", detail: "正在从 NAS 回读并校验备份。", actionTitle: nil)
        case .running:
            .init(title: "备份已验证", detail: "会话已上传并通过回读校验。", actionTitle: nil)
        case .pending:
            .init(title: "有会话等待补传", detail: "请保持 NAS 连接，软件会继续补传。", actionTitle: "立即重试")
        case .error:
            .init(title: "备份出现异常", detail: "请重新检测；仍失败时联系管理员。", actionTitle: "重新检测")
        }
    }

    public static let helpTopics: [EmployeeHelpTopic] = [
        .init(id: "install", title: "安装与首次启动",
              body: "安装后先连接 192.168.10.99 上的“文件中转站”，再在软件中选择部门和姓名，不需要手工选择目录。"),
        .init(id: "status", title: "备份状态说明",
              body: "只有显示“备份已验证”才表示上传和 NAS 回读校验都已完成。"),
        .init(id: "disconnect", title: "NAS 断开与异常处理",
              body: "先重新连接公司共享盘，再点击“重新检测”。仍失败时保留错误详情并联系管理员。"),
        .init(id: "recovery", title: "会话恢复和更换电脑",
              body: "打开“快照恢复”，选择 NAS 备份设备和缺失会话。恢复前软件会再次完整校验。"),
    ]
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter EmployeeOnboardingTests
swift build
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexSessionVaultCore/Guidance/EmployeeOnboarding.swift \
  Tests/CodexSessionVaultCoreTests/EmployeeOnboardingTests.swift
git commit -m "feat(core): define employee onboarding policy"
```

---

### Task 3: 接入 macOS 三步引导和离线帮助

**Files:**
- Create: `Sources/CodexSessionVault/EmployeeGuidanceViews.swift`
- Modify: `Sources/CodexSessionVault/main.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift`

**Interfaces:**
- Consumes: Task 2 policy/catalog and existing `NASSetupView` actions.
- Produces: `EmployeeOnboardingStepsView`, `EmployeeHelpView` and model methods `showEmployeeHelp()` / `openRecoveryFromHelp()`.

- [ ] **Step 1: 写 macOS 接线失败测试**

```swift
@Test
func employeeGuidanceUsesRealNasStateAndProvidesOfflineHelp() throws {
    let source = try macAppSource()
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let guidance = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CodexSessionVault/EmployeeGuidanceViews.swift"
        ),
        encoding: .utf8
    )
    #expect(source.contains("EmployeeOnboardingPolicy.evaluate("))
    #expect(source.contains("onboardingVersion"))
    #expect(source.contains("onboardingInProgress"))
    #expect(source.contains("EmployeeHelpView("))
    #expect(guidance.contains("安装与首次启动"))
    #expect(guidance.contains("会话恢复和更换电脑"))
}
```

- [ ] **Step 2: Run failing contract test**

```bash
swift test --filter MacNASWiringContractTests.employeeGuidanceUsesRealNasStateAndProvidesOfflineHelp
```

Expected: FAIL because the view file and wiring do not exist.

- [ ] **Step 3: Add model persistence and reconciliation**

Add keys and state:

```swift
private static let onboardingVersionKey = "employeeOnboardingVersion"
private static let onboardingInProgressKey = "employeeOnboardingInProgress"

@Published var isEmployeeHelpPresented = false
@Published private(set) var isNASCatalogReady = false
@Published private(set) var onboardingDecision = EmployeeOnboardingPolicy.evaluate(
    snapshot: .unconfigured,
    storedVersion: 0,
    inProgress: false,
    catalogReady: false,
    selectionValid: false
)
private var isNASReconfigurationPresented = false

var nasSelectionIsValid: Bool {
    nasDepartments.contains { $0.name == selectedNASDepartment }
        && nasEmployees.contains { $0.name == selectedNASEmployee }
}

var displayAppVersion: String { appVersion }
var isManualNASReconfiguration: Bool { isNASReconfigurationPresented }
```

Add one reconciliation method instead of duplicating persistence logic:

```swift
func reconcileEmployeeOnboarding() {
    let defaults = UserDefaults.standard
    let version = defaults.integer(forKey: Self.onboardingVersionKey)
    let inProgress = defaults.bool(forKey: Self.onboardingInProgressKey)
    let decision = EmployeeOnboardingPolicy.evaluate(
        snapshot: nasSetupSnapshot,
        storedVersion: version,
        inProgress: inProgress,
        catalogReady: isNASCatalogReady,
        selectionValid: nasSelectionIsValid
    )
    if decision.nextInProgress != inProgress {
        defaults.set(decision.nextInProgress, forKey: Self.onboardingInProgressKey)
    }
    if decision.shouldMarkComplete && version < EmployeeOnboardingPolicy.currentVersion {
        defaults.set(EmployeeOnboardingPolicy.currentVersion, forKey: Self.onboardingVersionKey)
    }
    onboardingDecision = decision
    if decision.presentSetup {
        isNASSetupPresented = true
    } else if !isNASReconfigurationPresented {
        isNASSetupPresented = false
    }
}

func dismissNASSetup() {
    guard !onboardingDecision.preventDismissal || isNASReconfigurationPresented else { return }
    isNASReconfigurationPresented = false
    isNASSetupPresented = false
}
```

Call `reconcileEmployeeOnboarding()` after every `syncNASSetupSnapshot()`, after both success and failure in `refreshNASCatalog()`, after every return path in `loadNASEmployees()`, and from the employee picker's `onChange`. Set `isNASCatalogReady = false` before catalog refresh, set it to `true` only after `departments()` returns successfully, and reset it to `false` on failure. This is what advances an unconfigured user from step 1 to step 2 even though the runtime snapshot is still `.unconfigured`.

Before first activation, when `nasSetupSnapshot.configuration == nil`, persist `onboardingInProgress = true` and reconcile. Remove the immediate `isNASSetupPresented = false` after activation so validating/seeding/verifying remains visible. `presentNASReconfiguration()` sets `isNASReconfigurationPresented = true`; its Close button calls `dismissNASSetup()`. The sheet uses `.interactiveDismissDisabled(model.onboardingDecision.preventDismissal && !model.isManualNASReconfiguration)`.

- [ ] **Step 4: Build the SwiftUI views**

```swift
import SwiftUI
import CodexSessionVaultCore

struct EmployeeOnboardingStepsView: View {
    let currentStep: Int
    private let titles = ["连接公司 NAS", "选择部门和姓名", "完成首次备份"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Label(title, systemImage: index + 1 < currentStep
                      ? "checkmark.circle.fill" : "\(index + 1).circle")
                    .foregroundStyle(index + 1 <= currentStep ? .blue : .secondary)
                if index < titles.count - 1 { Divider().frame(width: 24) }
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
                Text(guidance.title).font(.headline)
                Text(guidance.detail).foregroundStyle(.secondary)
                if snapshot.totalCount > 0 {
                    ProgressView(value: Double(snapshot.completedCount),
                                 total: Double(snapshot.totalCount))
                    Text("已发现 \(snapshot.totalCount) · 已完成 \(snapshot.completedCount) · 待处理 \(snapshot.pendingCount)")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Section(topic.title) { Text(topic.body) }
                }
                Section("快捷操作") {
                    Button("重新检测 NAS", action: retryNAS)
                    Button("重新配置部门和姓名", action: reconfigure)
                    Button("打开恢复页面", action: openRecovery)
                }
                Section { Text("版本 \(version)") }
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
```

Extend `NASSetupView` with the stepper, guidance card, real `completedCount / totalCount / pendingCount` progress, and a “如何连接 NAS” disclosure. Keep raw paths out of employee-facing error text.

Replace its local `selectionIsValid` check with `model.onboardingDecision.canActivate`, call `model.reconcileEmployeeOnboarding()` from the employee picker change handler, and render the activation button as:

```swift
Button("验证并开始备份") { model.activateSelectedNASIdentity() }
    .buttonStyle(.borderedProminent)
    .disabled(!model.onboardingDecision.canActivate
              || model.nasSetupSnapshot.state == .validating)
```

- [ ] **Step 5: Add toolbar and help sheet**

```swift
Button {
    model.showEmployeeHelp()
} label: {
    Label("使用帮助", systemImage: "questionmark.circle")
}
```

Add these model methods so help actions cannot receive or construct a filesystem path:

```swift
func showEmployeeHelp() {
    isEmployeeHelpPresented = true
}

func openRecoveryFromHelp() {
    isEmployeeHelpPresented = false
    selectedSection = .snapshots
}

func reconfigureFromHelp() {
    isEmployeeHelpPresented = false
    Task { @MainActor [weak self] in
        await Task.yield()
        self?.presentNASReconfiguration()
    }
}
```

Render the second sheet from the root view:

```swift
.sheet(isPresented: $model.isEmployeeHelpPresented) {
    EmployeeHelpView(
        version: model.displayAppVersion,
        retryNAS: { model.retryNASBackup() },
        reconfigure: { model.reconfigureFromHelp() },
        openRecovery: { model.openRecoveryFromHelp() }
    )
    .frame(minWidth: 620, minHeight: 520)
}
```

- [ ] **Step 6: Verify macOS behavior**

```bash
swift test --filter EmployeeOnboardingTests
swift test --filter MacNASWiringContractTests
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodexSessionVault/EmployeeGuidanceViews.swift \
  Sources/CodexSessionVault/main.swift \
  Tests/CodexSessionVaultCoreTests/MacNASWiringContractTests.swift
git commit -m "feat(mac): guide employees through NAS setup"
```

---

### Task 4: 建立 Windows 引导策略和持久化

**Files:**
- Create: `windows/codex_session_manager_electron/src/user-guidance.js`
- Create: `windows/codex_session_manager_electron/test/user-guidance.test.js`
- Modify: `windows/codex_session_manager_electron/src/settings.js`
- Modify: `windows/codex_session_manager_electron/src/main.js`
- Modify: `windows/codex_session_manager_electron/test/backup/nas-runtime.test.js`

**Interfaces:**
- Consumes: existing `nasSetupState()` and `settingsStore`.
- Produces: UMD API `EmployeeGuidance.onboardingDecision(input)`, `stateGuidance(state)`, `helpTopics`.

- [ ] **Step 1: Write failing Node tests**

```javascript
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  CURRENT_ONBOARDING_VERSION,
  onboardingDecision,
  stateGuidance,
  helpTopics,
} = require('../src/user-guidance');

test('unconfigured setup is forced until a real running state', () => {
  const required = onboardingDecision({
    setup: { state: 'unconfigured', configured: false },
    settings: { onboardingVersion: 0, onboardingInProgress: false },
    catalogReady: false,
    selectionValid: false,
  });
  assert.equal(required.step, 1);
  assert.equal(required.presentSetup, true);
  assert.equal(required.preventDismissal, true);
  assert.equal(required.nextInProgress, true);
  assert.equal(required.canActivate, false);

  const identity = onboardingDecision({
    setup: { state: 'unconfigured', configured: false },
    settings: { onboardingVersion: 0, onboardingInProgress: true },
    catalogReady: true,
    selectionValid: true,
  });
  assert.equal(identity.step, 2);
  assert.equal(identity.canActivate, true);

  const completed = onboardingDecision({
    setup: { state: 'running', configured: true },
    settings: { onboardingVersion: 0, onboardingInProgress: true },
    catalogReady: false,
    selectionValid: false,
  });
  assert.equal(completed.shouldMarkComplete, true);
  assert.equal(completed.nextInProgress, false);
  assert.equal(CURRENT_ONBOARDING_VERSION, 1);
});

test('guidance exposes exact shared labels and four topics', () => {
  assert.deepEqual(
    ['unconfigured', 'disconnected', 'validating', 'seeding', 'verifying', 'running', 'pending', 'error']
      .map((state) => stateGuidance(state).title),
    ['尚未选择部门和姓名', '未检测到公司 NAS', '正在验证备份目录', '正在进行首次备份',
      '正在确认 NAS 文件完整', '备份已验证', '有会话等待补传', '备份出现异常']
  );
  assert.deepEqual(helpTopics.map((topic) => topic.title), [
    '安装与首次启动',
    '备份状态说明',
    'NAS 断开与异常处理',
    '会话恢复和更换电脑',
  ]);
});

test('first run remains forced for every non-running runtime state', () => {
  for (const state of ['disconnected', 'validating', 'seeding', 'verifying', 'pending', 'error']) {
    const decision = onboardingDecision({
      setup: { state, configured: true },
      settings: { onboardingVersion: 0, onboardingInProgress: true },
    });
    assert.equal(decision.presentSetup, true, state);
    assert.equal(decision.preventDismissal, true, state);
    assert.equal(decision.shouldMarkComplete, false, state);
    assert.equal(decision.nextInProgress, true, state);
  }
});
```

- [ ] **Step 2: Run test and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/user-guidance.test.js
```

Expected: FAIL with module-not-found.

- [ ] **Step 3: Implement a Node/browser-safe UMD module**

```javascript
'use strict';

(function publish(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.EmployeeGuidance = api;
}(typeof globalThis === 'object' ? globalThis : this, () => {
  const CURRENT_ONBOARDING_VERSION = 1;
  const labels = Object.freeze({
    unconfigured: ['尚未选择部门和姓名', '连接公司 NAS 后选择部门和姓名。', '开始配置'],
    disconnected: ['未检测到公司 NAS', '请先重新连接公司共享盘。', '重新检测'],
    validating: ['正在验证备份目录', '正在确认目录和写入能力。', null],
    seeding: ['正在进行首次备份', '请保持 NAS 连接，暂勿退出软件。', null],
    verifying: ['正在确认 NAS 文件完整', '正在从 NAS 回读并校验备份。', null],
    running: ['备份已验证', '会话已上传并通过回读校验。', null],
    pending: ['有会话等待补传', '请保持 NAS 连接，软件会继续补传。', '立即重试'],
    error: ['备份出现异常', '请重新检测；仍失败时联系管理员。', '重新检测'],
  });

  function stateGuidance(state) {
    const [title, detail, actionTitle] = labels[state] || ['等待中', '等待备份状态。', null];
    return Object.freeze({ title, detail, actionTitle });
  }

  function onboardingDecision({ setup, settings, catalogReady = false, selectionValid = false }) {
    const configured = Boolean(setup && setup.configured);
    const state = setup?.state || 'unconfigured';
    const version = Number(settings?.onboardingVersion || 0);
    const inProgress = Boolean(settings?.onboardingInProgress);
    if (!configured || state === 'unconfigured') {
      return Object.freeze({
        step: catalogReady ? 2 : 1, presentSetup: true, preventDismissal: true,
        shouldMarkComplete: false, nextInProgress: true,
        canActivate: catalogReady && selectionValid,
      });
    }
    if (state === 'running') {
      return Object.freeze({
        step: 3, presentSetup: false, preventDismissal: false,
        shouldMarkComplete: version < CURRENT_ONBOARDING_VERSION || inProgress,
        nextInProgress: false, canActivate: false,
      });
    }
    if (inProgress) {
      return Object.freeze({
        step: state === 'disconnected' ? 1 : 3,
        presentSetup: true, preventDismissal: true,
        shouldMarkComplete: false, nextInProgress: true, canActivate: false,
      });
    }
    return Object.freeze({
      step: state === 'validating' ? 1 : 3,
      presentSetup: false, preventDismissal: false,
      shouldMarkComplete: false, nextInProgress: false, canActivate: false,
    });
  }

  const helpTopics = Object.freeze([
    Object.freeze({ id: 'install', title: '安装与首次启动', body: '安装后先连接 192.168.10.99 上的“文件中转站”，再在软件中选择部门和姓名。' }),
    Object.freeze({ id: 'status', title: '备份状态说明', body: '只有“备份已验证”表示上传和回读校验均完成。' }),
    Object.freeze({ id: 'disconnect', title: 'NAS 断开与异常处理', body: '重新连接公司共享盘后点击“重新检测”。' }),
    Object.freeze({ id: 'recovery', title: '会话恢复和更换电脑', body: '在快照恢复页面选择 NAS 备份并恢复缺失会话，恢复前软件会再次完整校验。' }),
  ]);

  return Object.freeze({
    CURRENT_ONBOARDING_VERSION, onboardingDecision, stateGuidance, helpTopics,
  });
}));
```

- [ ] **Step 4: Persist without adding an IPC channel**

Extend `settings.js` defaults:

```javascript
const defaults = Object.freeze({
  autoRestoreOnLaunch: false,
  nasBackup: null,
  onboardingVersion: 0,
  onboardingInProgress: false,
});
```

Import the pure policy at the top of `main.js`:

```javascript
const {
  CURRENT_ONBOARDING_VERSION,
  onboardingDecision,
} = require('./user-guidance');
```

Then add:

```javascript
function reconcileOnboarding(setup) {
  const settings = loadSettings();
  const decision = onboardingDecision({
    setup,
    settings,
    catalogReady: false,
    selectionValid: false,
  });
  if (
    decision.shouldMarkComplete
    || decision.nextInProgress !== Boolean(settings.onboardingInProgress)
  ) {
    return saveSettings({
      onboardingVersion: decision.shouldMarkComplete
        ? CURRENT_ONBOARDING_VERSION
        : Number(settings.onboardingVersion || 0),
      onboardingInProgress: decision.nextInProgress,
    });
  }
  return settings;
}
```

Use the same four defaults in both `settings.js` and `main.js`'s defensive `loadSettings()` fallback. Add these exact wrappers:

```javascript
function backupStatusWithOnboarding() {
  const setup = nasSetupState();
  const settings = reconcileOnboarding(setup);
  return {
    ...readBackupStatus(),
    onboardingVersion: Number(settings.onboardingVersion || 0),
    onboardingInProgress: Boolean(settings.onboardingInProgress),
  };
}

async function loadState() {
  ensureDir(snapshotRoot);
  const sessions = await loadSessions();
  const snapshots = loadSnapshots();
  const nasSetup = nasSetupState();
  const settings = reconcileOnboarding(nasSetup);
  return {
    appVersion,
    currentState: inspectCurrentState(),
    sessions,
    snapshots,
    settings,
    nasSetup,
    backupStatus: backupStatusWithOnboarding(),
    autoRestoreSuggestion: await autoRestoreSuggestion(sessions, snapshots),
  };
}
```

Change the existing status handler to `handleTrustedIpc('load-backup-status', async () => backupStatusWithOnboarding())`. In `activate-nas-backup`, read settings before activation and call `saveSettings({ onboardingInProgress: true })` only when `nasBackup` is absent; after activation call `reconcileOnboarding(nasSetupState())`. This persists first-run progress before any NAS side effect but does not force a manual reconfiguration flow. No new IPC channel or handler argument is allowed.

- [ ] **Step 5: Update settings tests**

Change malformed-file expectation to include the two new defaults, then assert sequential patches preserve all four keys.

- [ ] **Step 6: Run Windows tests**

```bash
cd windows/codex_session_manager_electron
npm test
node --check src/user-guidance.js
node --check src/main.js
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add windows/codex_session_manager_electron/src/user-guidance.js \
  windows/codex_session_manager_electron/src/settings.js \
  windows/codex_session_manager_electron/src/main.js \
  windows/codex_session_manager_electron/test/user-guidance.test.js \
  windows/codex_session_manager_electron/test/backup/nas-runtime.test.js
git commit -m "feat(win): persist employee onboarding state"
```

---

### Task 5: 接入 Windows 三步引导和离线帮助

**Files:**
- Modify: `windows/codex_session_manager_electron/src/index.html`
- Modify: `windows/codex_session_manager_electron/src/renderer.js`
- Modify: `windows/codex_session_manager_electron/src/styles.css`
- Modify: `windows/codex_session_manager_electron/test/user-guidance.test.js`

**Interfaces:**
- Consumes: `window.EmployeeGuidance` from Task 4 and existing renderer actions.
- Produces: `renderEmployeeHelp()` and policy-driven `renderNasSetup()`.

- [ ] **Step 1: Add a failing HTML contract test**

```javascript
const fsp = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(__dirname, '..');

test('renderer loads guidance before app code and exposes help controls', async () => {
  const html = await fsp.readFile(path.join(root, 'src/index.html'), 'utf8');
  const renderer = await fsp.readFile(path.join(root, 'src/renderer.js'), 'utf8');
  assert.ok(html.indexOf('./user-guidance.js') < html.indexOf('./renderer.js'));
  assert.match(html, /id="employeeHelpBtn"/);
  assert.match(html, /id="employeeHelpModal"/);
  assert.match(html, /连接公司 NAS/);
  assert.match(html, /选择部门和姓名/);
  assert.match(html, /完成首次备份/);
  assert.match(renderer, /EmployeeGuidance\.onboardingDecision/);
});
```

- [ ] **Step 2: Run and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/user-guidance.test.js
```

Expected: FAIL because help DOM and renderer wiring are absent.

- [ ] **Step 3: Extend the setup modal**

```html
<ol class="employee-onboarding-steps" aria-label="首次使用步骤">
  <li data-onboarding-step="1">连接公司 NAS</li>
  <li data-onboarding-step="2">选择部门和姓名</li>
  <li data-onboarding-step="3">完成首次备份</li>
</ol>
<section id="nasOnboardingProgress" class="nas-onboarding-progress" aria-live="polite">
  <strong id="nasOnboardingStatus">等待检测</strong>
  <span id="nasOnboardingCounts"></span>
</section>
```

Load `user-guidance.js` before `renderer.js`. Add a collapsible “如何连接 NAS” explanation and keep the target path non-editable.

- [ ] **Step 4: Add the offline help modal**

Add the toolbar button and modal with these stable IDs; keep them inside the existing trusted local `index.html`:

```html
<button id="employeeHelpBtn" class="toolbar-button" type="button"
        aria-haspopup="dialog" aria-controls="employeeHelpModal">
  使用帮助
</button>

<div id="employeeHelpModal" class="modal hidden" role="dialog" aria-modal="true"
     aria-labelledby="employeeHelpTitle">
  <section class="employee-help-panel">
    <header class="employee-help-header">
      <div>
        <h2 id="employeeHelpTitle">使用帮助</h2>
        <p id="employeeHelpVersion"></p>
      </div>
      <button id="employeeHelpCloseBtn" type="button" aria-label="关闭使用帮助">关闭</button>
    </header>
    <div id="employeeHelpTopics" class="employee-help-topics"></div>
    <footer class="employee-help-actions">
      <button id="employeeHelpRetryBtn" type="button">重新检测 NAS</button>
      <button id="employeeHelpReconfigureBtn" type="button">重新配置部门和姓名</button>
      <button id="employeeHelpRecoveryBtn" type="button">打开恢复页面</button>
    </footer>
  </section>
</div>
```

Add every ID to `els`, add `appVersion: ''` to renderer state, and populate topics with DOM APIs rather than `innerHTML`:

```javascript
function renderEmployeeHelp() {
  els.employeeHelpVersion.textContent = `版本 ${state.appVersion || '未知'}`;
  els.employeeHelpTopics.replaceChildren();
  for (const topic of window.EmployeeGuidance.helpTopics) {
    const section = document.createElement('section');
    const title = document.createElement('h3');
    const body = document.createElement('p');
    title.textContent = topic.title;
    body.textContent = topic.body;
    section.append(title, body);
    els.employeeHelpTopics.append(section);
  }
}

function openEmployeeHelp() {
  renderEmployeeHelp();
  els.employeeHelpModal.classList.remove('hidden');
  els.employeeHelpCloseBtn.focus();
}

function closeEmployeeHelp() {
  els.employeeHelpModal.classList.add('hidden');
  els.employeeHelpBtn.focus();
}
```

Wire the controls without adding preload methods:

```javascript
els.employeeHelpBtn.addEventListener('click', openEmployeeHelp);
els.employeeHelpCloseBtn.addEventListener('click', closeEmployeeHelp);
els.employeeHelpRetryBtn.addEventListener('click', () => { void retryNasBackup(); });
els.employeeHelpReconfigureBtn.addEventListener('click', () => {
  closeEmployeeHelp();
  void beginNasSetup(true);
});
els.employeeHelpRecoveryBtn.addEventListener('click', () => {
  closeEmployeeHelp();
  setSection('snapshots');
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !els.employeeHelpModal.classList.contains('hidden')) {
    event.preventDefault();
    closeEmployeeHelp();
  }
});
```

- [ ] **Step 5: Render from the policy**

```javascript
const effectiveSetup = {
  ...state.nasSetup,
  state: state.backupStatus?.status || state.nasSetup?.state || 'unconfigured',
};
const decision = window.EmployeeGuidance.onboardingDecision({
  setup: effectiveSetup,
  settings: state.settings,
  catalogReady: state.nasDetected,
  selectionValid: validDepartment && validEmployee,
});
const visible = decision.presentSetup || state.nasReconfiguring;
els.nasSetupModal.classList.toggle('hidden', !visible);
document.querySelectorAll('[data-onboarding-step]').forEach((element) => {
  const step = Number(element.dataset.onboardingStep);
  element.classList.toggle('active', step === decision.step);
  element.classList.toggle('complete', step < decision.step);
});
els.nasConfirmBtn.disabled = state.nasCatalogLoading || !decision.canActivate;
```

In `refresh()`, assign `state.appVersion = data.appVersion || state.appVersion`. When `refreshBackupStatusOnly()` receives onboarding fields, merge them into `state.settings`, then call `renderBackupStatus()` and `renderNasSetup()`:

```javascript
const backupStatus = await window.codexManager.loadBackupStatus() || {};
state.backupStatus = backupStatus;
state.settings = {
  ...state.settings,
  onboardingVersion: Number(backupStatus.onboardingVersion || 0),
  onboardingInProgress: Boolean(backupStatus.onboardingInProgress),
};
renderBackupStatus();
renderNasSetup();
```

Immediately before the first `activateNasBackup()` request, if `previous.configured` is false, merge `onboardingInProgress: true` into local `state.settings` and rerender. The main process remains the source of truth and returns the persisted value on the next status refresh.

- [ ] **Step 6: Add focused CSS**

```css
.employee-onboarding-steps {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 8px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.employee-onboarding-steps li {
  padding: 10px 12px;
  border: 1px solid var(--separator);
  border-radius: 10px;
  color: var(--secondary);
}
.employee-onboarding-steps li.active { border-color: #2563eb; color: #1d4ed8; }
.employee-onboarding-steps li.complete { color: #047857; background: #ecfdf5; }
.employee-help-panel {
  width: min(760px, calc(100vw - 48px));
  max-height: calc(100vh - 64px);
  overflow: auto;
  padding: 24px;
  border-radius: 16px;
  background: var(--panel-bg-solid);
  transition: opacity 180ms ease, transform 180ms ease;
}
.employee-help-header,
.employee-help-actions { display: flex; gap: 10px; justify-content: space-between; }
.employee-help-topics { display: grid; gap: 12px; margin: 18px 0; }
.employee-help-topics section { padding: 14px; border: 1px solid var(--separator); border-radius: 12px; }
#employeeHelpModal button:focus-visible,
#nasSetupModal button:focus-visible,
#nasSetupModal select:focus-visible { outline: 3px solid #60a5fa; outline-offset: 2px; }
```

Keep motion to the existing 180 ms opacity/scale behavior and retain `aria-live="polite"` on the progress section.

- [ ] **Step 7: Run tests and syntax checks**

```bash
cd windows/codex_session_manager_electron
npm test
node --check src/user-guidance.js
node --check src/renderer.js
node --check src/main.js
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add windows/codex_session_manager_electron/src/index.html \
  windows/codex_session_manager_electron/src/renderer.js \
  windows/codex_session_manager_electron/src/styles.css \
  windows/codex_session_manager_electron/test/user-guidance.test.js
git commit -m "feat(win): add employee setup guidance"
```

---

### Task 6: 编写员工指南并生成五页以内 PDF

**Files:**
- Create: `docs/员工安装与使用说明.md`
- Create: `docs/assets/employee-guide/macos-install.png`
- Create: `docs/assets/employee-guide/macos-nas-setup.png`
- Create: `docs/assets/employee-guide/windows-install.png`
- Create: `docs/assets/employee-guide/windows-nas-setup.png`
- Create: `docs/assets/employee-guide/backup-verified.png`
- Create: `windows/codex_session_manager_electron/scripts/employee-guide-markdown.js`
- Create: `windows/codex_session_manager_electron/scripts/build-employee-guide.js`
- Create: `windows/codex_session_manager_electron/test/employee-guide-markdown.test.js`
- Create: `scripts/build_employee_guide.sh`
- Modify: `windows/codex_session_manager_electron/package.json`

**Interfaces:**
- Consumes: final UI labels/screenshots from Tasks 3 and 5.
- Produces: `dist/Codex会话管理-安装与使用说明.pdf`.

- [ ] **Step 1: Write failing renderer tests**

```javascript
const test = require('node:test');
const assert = require('node:assert/strict');
const { renderGuideHTML } = require('../scripts/employee-guide-markdown');

test('renderer escapes HTML and resolves only guide asset images', () => {
  const html = renderGuideHTML(
    '# 标题\n\n<script>alert(1)</script>\n\n![截图](assets/employee-guide/macos-install.png)',
    { version: '1.0.14' }
  );
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /assets\/employee-guide\/macos-install\.png/);
  assert.match(html, /版本 1\.0\.14/);
});

test('renderer rejects external and parent-relative image URLs', () => {
  assert.throws(() => renderGuideHTML('![x](https://example.com/x.png)', { version: '1.0.14' }));
  assert.throws(() => renderGuideHTML('![x](../secret.png)', { version: '1.0.14' }));
});
```

- [ ] **Step 2: Run and confirm failure**

```bash
cd windows/codex_session_manager_electron
node --test test/employee-guide-markdown.test.js
```

Expected: FAIL because renderer module is missing.

- [ ] **Step 3: Implement the restricted renderer**

Create `employee-guide-markdown.js` with the complete restricted grammar below. Source text is escaped before inline formatting; images are accepted only as a single local PNG line under the approved asset directory.

```javascript
'use strict';

function escapeHTML(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function renderInline(value) {
  return escapeHTML(value)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
}

function approvedImagePath(value) {
  const normalized = String(value || '').replaceAll('\\', '/');
  if (!/^assets\/employee-guide\/[A-Za-z0-9._-]+\.png$/.test(normalized)) {
    throw new Error(`Unapproved guide image path: ${value}`);
  }
  return normalized;
}

function renderGuideHTML(markdown, { version }) {
  const lines = String(markdown).replace(/\r\n?/g, '\n').split('\n');
  const blocks = [];
  let paragraph = [];
  let list = null;
  let fence = null;

  function flushParagraph() {
    if (paragraph.length) blocks.push(`<p>${renderInline(paragraph.join(' '))}</p>`);
    paragraph = [];
  }

  function flushList() {
    if (!list) return;
    blocks.push(`<${list.tag}>${list.items.map((item) => `<li>${renderInline(item)}</li>`).join('')}</${list.tag}>`);
    list = null;
  }

  function flushText() {
    flushParagraph();
    flushList();
  }

  for (const line of lines) {
    if (fence) {
      if (/^```\s*$/.test(line)) {
        blocks.push(`<pre><code>${escapeHTML(fence.join('\n'))}</code></pre>`);
        fence = null;
      } else {
        fence.push(line);
      }
      continue;
    }
    if (/^```(?:text)?\s*$/.test(line)) {
      flushText();
      fence = [];
      continue;
    }
    if (!line.trim()) {
      flushText();
      continue;
    }
    const image = line.match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
    if (image) {
      flushText();
      const source = approvedImagePath(image[2]);
      blocks.push(`<figure><img src="${source}" alt="${escapeHTML(image[1])}"></figure>`);
      continue;
    }
    const heading = line.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      flushText();
      const level = heading[1].length;
      blocks.push(`<h${level}>${renderInline(heading[2])}</h${level}>`);
      continue;
    }
    const ordered = line.match(/^\d+\.\s+(.+)$/);
    const unordered = line.match(/^[-*]\s+(.+)$/);
    const item = ordered || unordered;
    if (item) {
      flushParagraph();
      const tag = ordered ? 'ol' : 'ul';
      if (list && list.tag !== tag) flushList();
      if (!list) list = { tag, items: [] };
      list.items.push(item[1]);
      continue;
    }
    flushList();
    paragraph.push(line.trim());
  }
  if (fence) throw new Error('Unclosed guide code fence');
  flushText();

  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><style>
@page { size: A4; margin: 14mm 15mm; }
* { box-sizing: border-box; }
body { font: 11pt -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #1f2937; line-height: 1.5; }
h1 { font-size: 24pt; color: #17345f; margin: 0 0 12mm; }
h2 { break-before: page; font-size: 18pt; color: #1d4ed8; margin-top: 0; }
h2:first-of-type { break-before: auto; }
h3 { font-size: 13pt; color: #17345f; }
p, li { orphans: 3; widows: 3; }
pre { white-space: pre-wrap; padding: 8px 10px; background: #f3f4f6; border-radius: 6px; }
code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
figure { margin: 5mm 0; break-inside: avoid; text-align: center; }
img { max-width: 100%; max-height: 92mm; object-fit: contain; }
.document-version { color: #64748b; margin-bottom: 8mm; }
</style></head><body>
<p class="document-version">适用版本 ${escapeHTML(version)}</p>
${blocks.join('\n')}
</body></html>`;
}

module.exports = { approvedImagePath, escapeHTML, renderGuideHTML };
```

- [ ] **Step 4: Write the five-section Markdown**

Use the following exact source; replace screenshot files only after their UI labels pass Tasks 3 and 5:

```markdown
# Codex 会话管理：安装与使用说明

本软件会把 Codex 会话持续备份到公司 NAS，并在上传后回读校验。首次使用只需连接 NAS、选择部门和姓名，不要手工选择备份目录。

## 1. 选择正确版本

- Apple Silicon Mac 下载 `Codex会话管理-macOS-arm64.dmg`。
- Windows 10/11 64 位电脑下载 `Codex会话管理-Windows-x64.exe`。
- 普通员工不需要打开 `安装包校验信息.txt`；该文件仅供管理员核对安装包。

## 2. 安装与首次启动

### macOS

1. 打开 DMG，把“codex_会话管理”拖到“应用程序”。
2. 如果 macOS 拦截，打开“系统设置 → 隐私与安全性”，在拦截提示旁点击“仍要打开”，再确认一次。

![macOS 安装示意](assets/employee-guide/macos-install.png)

### Windows

1. 双击 EXE 安装包，按页面提示安装。
2. 如果 SmartScreen 提示保护电脑，先点“更多信息”，再点“仍要运行”。

![Windows 安装示意](assets/employee-guide/windows-install.png)

## 3. 连接 NAS 并确认身份

1. 先在 Finder 或资源管理器连接服务器 `192.168.10.99` 上的“文件中转站”共享盘。
2. 软件显示“已连接”后，先选部门，再选本人姓名。
3. 确认页面的部门和姓名，点击“验证并开始备份”。不要在 Finder 或资源管理器中自行改名、移动或创建个人备份目录。

![macOS NAS 配置](assets/employee-guide/macos-nas-setup.png)

![Windows NAS 配置](assets/employee-guide/windows-nas-setup.png)

## 4. 判断备份是否成功

首次备份会依次显示“正在验证备份目录”“正在进行首次备份”和“正在确认 NAS 文件完整”。在此期间保持 NAS 连接，暂勿退出软件。

只有“备份已验证”表示上传和 NAS 回读校验都已成功。“有会话等待补传”表示软件会继续补传；“备份出现异常”时先点“重新检测”。

![备份已验证](assets/employee-guide/backup-verified.png)

## 5. 恢复会话与常见问题

### 更换电脑或会话丢失

打开“快照恢复”，选择 NAS 备份设备，再选择缺失会话恢复。全新电脑上没有旧的 Codex 目录也可以恢复；软件会在写入前校验备份完整性。

### NAS 断开

重新连接“文件中转站”，回到软件点“重新检测 NAS”。仍失败时，打开错误详情截图并联系管理员，不要手动删除备份文件。

### 部门或姓名选错

打开右上角“使用帮助”，选择“重新配置部门和姓名”。只能选择 NAS 已存在的部门和员工目录。

### 退出软件

软件需要常驻才能持续备份。需要退出时，使用软件的明确“退出”命令；首次备份尚未完成时，按页面提示确认。
```

- [ ] **Step 5: Capture and anonymize screenshots**

Capture the five named PNG files from final builds. Use synthetic department/name and session titles; crop desktop notifications, usernames, account fingerprints and unrelated windows. Visually inspect each image before adding it.

- [ ] **Step 6: Build PDF with existing Electron**

```javascript
'use strict';

const { app, BrowserWindow } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { renderGuideHTML } = require('./employee-guide-markdown');
const packageJSON = require('../package.json');

const root = path.resolve(__dirname, '../../..');
const source = path.join(root, 'docs/员工安装与使用说明.md');
const output = path.join(root, 'dist/Codex会话管理-安装与使用说明.pdf');
const temporary = path.join(root, 'docs/.employee-guide.html');

async function buildGuide() {
  let window;
  try {
    const markdown = await fs.readFile(source, 'utf8');
    const html = renderGuideHTML(markdown, {
      version: process.env.APP_VERSION || packageJSON.version,
    });
    await fs.mkdir(path.dirname(output), { recursive: true });
    await fs.writeFile(temporary, html, { encoding: 'utf8', mode: 0o600 });
    window = new BrowserWindow({
      show: false,
      webPreferences: { sandbox: true, nodeIntegration: false, contextIsolation: true },
    });
    await window.loadFile(temporary);
    const pdf = await window.webContents.printToPDF({
      pageSize: 'A4',
      printBackground: true,
      margins: { top: 0, bottom: 0, left: 0, right: 0 },
    });
    await fs.writeFile(output, pdf, { mode: 0o600 });
  } finally {
    if (window && !window.isDestroyed()) window.destroy();
    await fs.rm(temporary, { force: true });
  }
}

app.whenReady()
  .then(buildGuide)
  .then(() => app.quit())
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });
```

Add package script `"guide:pdf": "electron scripts/build-employee-guide.js"`. Create the root wrapper exactly as follows so the build fails when the page count is outside 1–5:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDF="$ROOT_DIR/dist/Codex会话管理-安装与使用说明.pdf"
command -v pdfinfo >/dev/null || { echo "pdfinfo is required" >&2; exit 1; }
npm --prefix "$ROOT_DIR/windows/codex_session_manager_electron" run guide:pdf
PAGES="$(pdfinfo "$PDF" | awk '/^Pages:/ { print $2 }')"
if [[ ! "$PAGES" =~ ^[1-5]$ ]]; then
  echo "Employee guide must contain 1-5 pages; got: ${PAGES:-unknown}" >&2
  exit 1
fi
echo "$PDF"
```

- [ ] **Step 7: Verify rendered pages**

```bash
./scripts/build_employee_guide.sh
pdfinfo "dist/Codex会话管理-安装与使用说明.pdf"
rm -rf /tmp/codex-employee-guide-pages
mkdir -p /tmp/codex-employee-guide-pages
pdftoppm -png -r 130 "dist/Codex会话管理-安装与使用说明.pdf" \
  /tmp/codex-employee-guide-pages/page
```

Expected: 1–5 pages, no clipped text, all screenshots legible, no sensitive data.

- [ ] **Step 8: Commit**

```bash
chmod +x scripts/build_employee_guide.sh
git add docs/员工安装与使用说明.md \
  docs/assets/employee-guide \
  scripts/build_employee_guide.sh \
  windows/codex_session_manager_electron/scripts/employee-guide-markdown.js \
  windows/codex_session_manager_electron/scripts/build-employee-guide.js \
  windows/codex_session_manager_electron/test/employee-guide-markdown.test.js \
  windows/codex_session_manager_electron/package.json
git commit -m "docs: add employee installation guide"
```

---

### Task 7: 汇总可下载的内部发布目录

**Files:**
- Create: `scripts/assemble_internal_release.sh`
- Modify: `README.md`
- Modify: `windows/codex_session_manager_electron/README_WIN10_EXE.md`

**Interfaces:**
- Consumes:
  - `dist/codex_session_keeper_macos_v<version>_internal-test-unsigned.dmg`
  - `dist/win10-installer/codex_session_keeper_windows_<version>_internal-test-unsigned.exe`
  - `dist/Codex会话管理-安装与使用说明.pdf`
- Produces: `dist/internal-release/versions/v<version>/` and copied `dist/internal-release/latest/`.

- [ ] **Step 1: Write release script safety checks**

Create the complete script below. It rejects untracked files as well as modified files, validates both source versions, rebuilds every deliverable, verifies the source checksums, and never uses a symbolic link for `latest`.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 X.Y.Z" >&2
  exit 1
fi

cd "$ROOT_DIR"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to assemble a release from a dirty worktree." >&2
  exit 1
fi

MAC_VERSION="$(sed -nE 's/.*private let appVersion = "([^"]+)".*/\1/p' \
  Sources/CodexSessionVault/main.swift | head -1)"
WIN_VERSION="$(node -p "require('./windows/codex_session_manager_electron/package.json').version")"
if [[ "$MAC_VERSION" != "$VERSION" || "$WIN_VERSION" != "$VERSION" ]]; then
  echo "Version mismatch: requested=$VERSION mac=$MAC_VERSION windows=$WIN_VERSION" >&2
  exit 1
fi

swift test
npm --prefix windows/codex_session_manager_electron test
APP_VERSION="$VERSION" ./scripts/build_app.sh
./scripts/build_macos_dmg.sh
npm --prefix windows/codex_session_manager_electron run dist:win
APP_VERSION="$VERSION" ./scripts/build_employee_guide.sh

MAC_SOURCE="$ROOT_DIR/dist/codex_session_keeper_macos_v${VERSION}_internal-test-unsigned.dmg"
MAC_CHECKSUM="${MAC_SOURCE}.sha256"
WIN_SOURCE="$ROOT_DIR/dist/win10-installer/codex_session_keeper_windows_${VERSION}_internal-test-unsigned.exe"
WIN_CHECKSUM="${WIN_SOURCE}.sha256"
PDF_SOURCE="$ROOT_DIR/dist/Codex会话管理-安装与使用说明.pdf"
for artifact in "$MAC_SOURCE" "$MAC_CHECKSUM" "$WIN_SOURCE" "$WIN_CHECKSUM" "$PDF_SOURCE"; do
  [[ -f "$artifact" ]] || { echo "Missing artifact: $artifact" >&2; exit 1; }
done

hdiutil verify "$MAC_SOURCE"
(cd "$(dirname "$MAC_SOURCE")" && shasum -a 256 -c "$(basename "$MAC_CHECKSUM")")
(cd "$(dirname "$WIN_SOURCE")" && shasum -a 256 -c "$(basename "$WIN_CHECKSUM")")
PAGES="$(pdfinfo "$PDF_SOURCE" | awk '/^Pages:/ { print $2 }')"
[[ "$PAGES" =~ ^[1-5]$ ]] || { echo "Guide page count is $PAGES" >&2; exit 1; }

RELEASE_ROOT="$ROOT_DIR/dist/internal-release"
VERSION_DIR="$RELEASE_ROOT/versions/v$VERSION"
LATEST="$RELEASE_ROOT/latest"
LATEST_NEW="$RELEASE_ROOT/latest.new"
if [[ -e "$VERSION_DIR" ]]; then
  echo "Version directory already exists: $VERSION_DIR" >&2
  exit 1
fi
mkdir -p "$VERSION_DIR/macOS" "$VERSION_DIR/Windows"
cp "$MAC_SOURCE" "$VERSION_DIR/macOS/Codex会话管理-macOS-arm64.dmg"
cp "$WIN_SOURCE" "$VERSION_DIR/Windows/Codex会话管理-Windows-x64.exe"
cp "$PDF_SOURCE" "$VERSION_DIR/Codex会话管理-安装与使用说明.pdf"

MAC_HASH="$(shasum -a 256 "$MAC_SOURCE" | awk '{ print $1 }')"
WIN_HASH="$(shasum -a 256 "$WIN_SOURCE" | awk '{ print $1 }')"
PDF_HASH="$(shasum -a 256 "$PDF_SOURCE" | awk '{ print $1 }')"
COMMIT="$(git rev-parse HEAD)"
BUILT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$VERSION_DIR/安装包校验信息.txt" <<EOF
Codex 会话管理内部版本：$VERSION
Git 提交：$COMMIT
UTC 构建时间：$BUILT_AT
macOS：Apple Silicon，macOS 14 或更高
Windows：Windows 10/11 x64

SHA-256
$MAC_HASH  macOS/Codex会话管理-macOS-arm64.dmg
$WIN_HASH  Windows/Codex会话管理-Windows-x64.exe
$PDF_HASH  Codex会话管理-安装与使用说明.pdf
EOF

rm -rf "$LATEST_NEW"
cp -R "$VERSION_DIR" "$LATEST_NEW"
rm -rf "$LATEST"
mv "$LATEST_NEW" "$LATEST"
echo "$VERSION_DIR"
echo "$LATEST"
```

- [ ] **Step 2: Review the expected output tree**

```text
dist/internal-release/
├── versions/v1.0.14/
│   ├── macOS/Codex会话管理-macOS-arm64.dmg
│   ├── Windows/Codex会话管理-Windows-x64.exe
│   ├── Codex会话管理-安装与使用说明.pdf
│   └── 安装包校验信息.txt
└── latest/
    └── (the same four copied files, never a symlink)
```

- [ ] **Step 3: Add operator documentation**

Document that employees open `latest/`, administrators verify checksums and keep it read-only, macOS uses Privacy & Security → “仍要打开”, Windows may show SmartScreen, and NAS publication happens only after acceptance.

- [ ] **Step 4: Syntax-check and commit the release tooling**

```bash
bash -n scripts/assemble_internal_release.sh
chmod +x scripts/assemble_internal_release.sh
git add scripts/assemble_internal_release.sh \
  README.md \
  windows/codex_session_manager_electron/README_WIN10_EXE.md
git commit -m "build: assemble internal employee release"
```

The commit must happen before the integration run because the production script intentionally refuses every dirty worktree, including its own uncommitted source.

- [ ] **Step 5: Run the clean-tree assembly integration test**

```bash
rm -rf dist/internal-release
./scripts/assemble_internal_release.sh 1.0.14
find dist/internal-release -maxdepth 4 -type f -print
rm -rf dist/internal-release
git status --short
```

Expected: before cleanup, versioned and latest directories each contain exactly the four approved deliverables and matching checksums; after cleanup, `git status --short` is empty. If the clean-tree integration test fails, fix it in a separate `fix(build): ...` commit and repeat this step. Cleanup prevents the final Task 8 candidate assembly from colliding with this dry run.

---

### Task 8: 双端回归、文档验收和上线候选判定

**Files:**
- Modify only for factual corrections: `docs/员工安装与使用说明.md`
- Generated, not committed: `dist/internal-release/**`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: evidence-backed internal test candidate; no automatic push or NAS publication.

- [ ] **Step 1: Run full automated verification**

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
npm --prefix windows/codex_session_manager_electron test
node --check windows/codex_session_manager_electron/src/user-guidance.js
node --check windows/codex_session_manager_electron/src/renderer.js
node --check windows/codex_session_manager_electron/src/main.js
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 2: Build all artifacts**

```bash
./scripts/build_app.sh
./scripts/build_macos_dmg.sh
npm --prefix windows/codex_session_manager_electron run package:win
npm --prefix windows/codex_session_manager_electron run dist:win
./scripts/build_employee_guide.sh
```

Expected: macOS App/DMG, Windows portable folder/installer and PDF exist.

- [ ] **Step 3: Verify artifact integrity**

```bash
codesign --verify --deep --strict "dist/codex_会话管理.app"
hdiutil verify dist/codex_session_keeper_macos_v1.0.14_internal-test-unsigned.dmg
shasum -a 256 -c dist/codex_session_keeper_macos_v1.0.14_internal-test-unsigned.dmg.sha256
pdfinfo "dist/Codex会话管理-安装与使用说明.pdf"
test -f windows/codex_session_manager_electron/vendor/sqlite3.exe
```

Expected: ad-hoc signature structurally valid, DMG/checksum valid, PDF at most five pages, SQLite executable present.

- [ ] **Step 4: macOS manual acceptance**

On a clean local user:

1. Install from DMG and complete Gatekeeper “仍要打开”.
2. Start disconnected; verify step 1 is forced.
3. Connect NAS and select an approved synthetic identity.
4. Verify step 3 remains through seeding/verifying and closes only at running.
5. Restart; verify onboarding does not repeat.
6. Open offline help and exercise retry/reconfigure/recovery navigation.
7. Confirm auto-restore preference persists across restart.
8. Confirm resident backup continues and explicit quit works.

- [ ] **Step 5: Windows manual acceptance**

Repeat on Windows 10/11, including SmartScreen, tray reopen, explicit tray quit, launch-at-login and recovery navigation.

- [ ] **Step 6: First-time employee test**

Give one employee who did not participate in development only `latest/`. They must install, select identity without entering a path, identify “备份已验证”, recover from a disconnect, find recovery instructions, and finish without developer help.

- [ ] **Step 7: Assemble the candidate**

```bash
./scripts/assemble_internal_release.sh 1.0.14
```

Do not copy to NAS until every manual item above is recorded as passed.

- [ ] **Step 8: Final review checkpoint**

```bash
git status --short --branch
git log --oneline -10
```

Expected: source tree clean, dist artifacts ignored, commits separated by task. Stop for user approval before push, merge or NAS publication.

# macOS 更新重试与可见入口设计

## 背景

macOS 1.0.99 已具备启动定时检查以及菜单栏“检查更新…”入口，但主窗口工具栏没有可见的检查更新按钮。员工容易认为应用不支持手动检查。

手动更新测试还暴露出一个 Sparkle 生命周期缺陷：1.1.0 下载完成后，如果 NAS 备份仍在写入，`prepareForUpdate` 会安全拒绝重启安装，但应用没有结束 Sparkle 保存的 ready reply。旧 Updater 因此持续运行，后续“确认下载”虽然写入审计日志，却不能启动新的下载。

## 目标

- 在主窗口右上角提供始终可见的“检查更新”文字按钮。
- 安装准备失败时显式结束当前 Sparkle 会话。
- 更新请求尚未结束时拒绝重复的下载确认流程。
- 失败后允许员工重新检查并重新下载。
- 保留下载前和安装前两次原生确认以及现有审计日志。

## 非目标

- 不改变 NAS 备份、回读校验或 5 秒安装前安全等待策略。
- 不启用无人确认的自动下载或自动安装。
- 不改变 Windows 更新行为。
- 不修改 `stable` 正式发布路径或员工下载页。

## 设计

### 可见入口

`ContentView` 注入现有 `MacUpdateCoordinator`，在“帮助、刷新、打开目录”所在工具栏增加文字按钮“检查更新”。按钮与菜单栏入口共同调用 `checkNow()`，不复制网络或状态机逻辑。

后台每 8 小时检查和首次启动检查保持不变。

### 一次性 Sparkle reply

在 `CodexSessionVaultCore` 增加一个小型泛型 `UpdateReadyReplyGate<Choice>`，负责保存和恰好一次地解析 Sparkle ready reply：

- `hold` 保存待处理 reply；
- `hasPendingReply` 暴露是否存在待处理 reply；
- `resolve(choice)` 先清空保存值，再调用 reply，重复解析返回 `false` 且不再次调用。

`MacUpdateCoordinator` 使用该 gate 取代裸 `readyReply` 闭包。所有完成、推迟、失败和放弃路径都必须解析或明确结束待处理 reply，不再只把闭包设为 `nil`。

### 安装准备失败

以下失败路径统一执行更新会话清理：

- NAS 写入未能在 5 秒内安全停稳；
- `pendingVersion` 状态保存失败；
- Sparkle 自身报告失败或更新流程被放弃。

清理动作：

1. 以 `.dismiss` 解析待处理 ready reply；
2. 清除 `installRequested`、`installWhenReady`、`deferredReady`；
3. 如果此前已经停稳 NAS，则恢复备份；
4. 保留面向员工的失败提示。

该清理只结束更新会话，不删除会话、备份或正式安装包。

### 防止重复请求

`beginDownload()` 在 `installRequested` 已为 `true` 或存在待处理 ready reply 时直接返回，不再次显示原生确认窗口，也不重复调用 Sparkle。

当更新会话成功结束或失败清理后，门禁重新开放，员工可以再次执行“检查更新 → 立即更新”。

## 测试

- `UpdateReadyReplyGate`：
  - reply 只解析一次；
  - 解析后不再处于 pending；
  - 清理后可以保存并解析下一次 reply。
- 更新同意策略原有测试继续证明：没有两次确认就不能下载或安装。
- macOS 打包测试继续验证 Sparkle framework 和 `LC_RPATH`。
- 人工验收：
  1. 工具栏显示“检查更新”；
  2. 检查后出现 1.1.0；
  3. 确认下载后进入下载状态；
  4. NAS 忙时安装被安全取消且 Sparkle helper 退出；
  5. 再次检查可以重新下载；
  6. 内存保持有界，会话数量不减少。

## 发布边界

先构建新的 testing 版 1.0.99 和 1.1.0，仅替换隔离的 `testing` 候选。完成纯手动更新验收后，再单独决定是否更新 `stable`。

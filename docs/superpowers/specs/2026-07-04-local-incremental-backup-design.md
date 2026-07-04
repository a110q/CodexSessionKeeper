# Codex 本地增量备份设计

## 背景

当前 `codex_会话管理` 已经支持本机快照、快照恢复、单会话恢复、删除前保护点和打开时自动找回。现有机制偏向“用户手动创建或操作前创建恢复点”，快照内容通常是全量或按会话选择后的完整拷贝。

公司内部希望让员工使用 Codex 桌面端时，新增对话和后续消息能够自动备份。第一阶段先不接 NAS，只在本机可靠保存增量备份；第二阶段再把本机备份同步到公司 NAS。

第一阶段目标是：员工正常使用 Codex 桌面端时，不需要手动点击“创建快照”，新增会话和会话新增行会被后台自动备份到本机。

## 目标

- 自动发现 Codex 会话 `.jsonl` 文件。
- 只备份 `.jsonl` 新增完整行，不做全量快照。
- 保存最小会话索引，方便查看、排查、恢复和后续上传 NAS。
- 后台常驻运行，支持开机自启，提供菜单栏或托盘状态。
- macOS 和 Windows 都支持同一套目录结构、manifest 语义和恢复包格式。
- 权限、监听、写入失败时不静默失效，必须有状态和日志。
- 第一阶段可从本地增量备份生成文件型恢复包，并复用现有恢复流程。

## 非目标

- 第一阶段不上传 NAS。
- 第一阶段不做公司级中心监控后台。
- 第一阶段不加密本地备份内容。
- 第一阶段不强行重建完整 `state_5.sqlite`。
- 第一阶段不替代现有手动快照功能；手动快照继续作为完整恢复点存在。

## 架构边界

新增独立 `BackupAgent` 模块，不把增量备份逻辑继续塞进现有快照恢复主流程。

`BackupAgent` 负责：

- 启动时扫描 Codex 会话目录。
- 运行时监听 `.jsonl` 文件变化。
- 按 byte offset 读取新增内容。
- 只追加完整 JSONL 行到本地备份文件。
- 更新 cursor 和 manifest。
- 写入本机状态文件和滚动日志。
- 在监听失败时切换到轮询模式。

现有快照恢复模块继续负责：

- 创建手动快照。
- 恢复快照。
- 删除前保护点。
- 恢复前保护点。
- 合并会话目录、`session_index.jsonl` 和可用的 SQLite 数据库。

主 UI 只消费 `BackupAgent` 的状态，不直接承担备份逻辑。

## 本地目录结构

第一阶段本地备份根目录固定为：

```text
~/.codex-session-vault/incremental-backups/
```

目录结构：

```text
incremental-backups/
  manifest.json
  cursors.sqlite
  status.json
  sessions/
    YYYY/
      MM/
        DD/
          <session-id>.jsonl
  logs/
    backup-agent.log
```

命名规则：

- 日期目录使用 session 第一次发现日期。
- 备份文件名只使用 `<session-id>.jsonl`。
- 同一个 session 永远追加到同一个备份文件。
- 跨天继续对话时，不按新日期切分文件。
- 恢复不依赖日期目录，恢复入口以 manifest 的 `sessionId -> backupPath` 映射为准。

## Manifest

`manifest.json` 面向人、恢复流程和后续 NAS 上传。它保存较小的索引信息，不保存对话正文。

示例：

```json
{
  "version": 1,
  "codexRoot": "/Users/alice/.codex",
  "backupRoot": "/Users/alice/.codex-session-vault/incremental-backups",
  "createdAt": "2026-07-04T10:00:00Z",
  "updatedAt": "2026-07-04T10:12:00Z",
  "sessions": {
    "0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab": {
      "sessionId": "0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab",
      "sourcePath": "/Users/alice/.codex/sessions/2026/07/04/0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab.jsonl",
      "backupPath": "sessions/2026/07/04/0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab.jsonl",
      "title": "从首条用户消息提取的短标题",
      "firstSeenAt": "2026-07-04T10:00:00Z",
      "lastBackedUpAt": "2026-07-04T10:12:00Z",
      "lineCount": 37,
      "bytesBackedUp": 18422,
      "status": "active"
    }
  }
}
```

Manifest 的作用：

- 让备份文件可查找、可解释、可恢复。
- 支持 UI 展示已备份会话列表。
- 支持后续 NAS 上传时快速判断本机备份内容。
- 避免用标题或日期作为恢复依据。

## Cursor Store

`cursors.sqlite` 面向程序精确恢复状态。它保存每个源文件的读取游标和异常状态。

每个源文件至少记录：

- `sessionId`
- `sourcePath`
- `backupPath`
- `lastByteOffset`
- `lastSourceSize`
- `lastSourceModifiedAt`
- `lineCount`
- `pendingPartialLine`
- `status`
- `lastError`
- `updatedAt`

写入顺序必须保守：

1. 读取源文件新增 bytes。
2. 只取完整换行结尾的 JSONL 行。
3. 追加写入备份文件。
4. 更新 manifest。
5. 更新 cursor offset。

如果备份写入失败，不更新 cursor，避免误判已经备份。

## 监听和增量读取

启动流程：

- 创建备份根目录、日志目录和数据库。
- 加载 manifest 和 cursors。
- 扫描 `~/.codex/sessions` 与 `~/.codex/archived_sessions`。
- 对新增源文件创建 session 记录。
- 第一次运行时从文件开头备份已有完整行。

运行流程：

- 文件监听只负责标记“可能变化”。
- 对变化文件做 1 到 3 秒 debounce。
- 按 cursor 中的 `lastByteOffset` 读取新增 bytes。
- 单次读取限制在固定块大小内，例如 256KB 到 1MB。
- 只追加完整行。
- 如果最后一行没有换行，作为半行等待下一次补全。
- 对同一文件重复事件去重排队。

异常处理：

- 源文件暂时不可读时，记录错误并重试，不影响其他文件。
- 源文件变小表示可能截断或重写，标记 `truncated`，从 0 重新扫描并保守追加未见过内容。
- 监听失败时切换轮询模式。
- 轮询模式每 10 到 30 秒扫描文件大小和修改时间，仍按 offset 增量读取。

## 权限、自检和运行保障

第一阶段不要求管理员权限。

macOS：

- 不走 App Sandbox。
- 默认只访问用户 Home 下的 `.codex` 和 `.codex-session-vault`。
- 通常不要求 Full Disk Access。
- 开机自启使用 Login Item 或 LaunchAgent。
- 如果系统策略阻止访问，状态显示无权限读取 Codex 数据目录。

Windows：

- 只访问 `%USERPROFILE%\.codex` 和 `%USERPROFILE%\.codex-session-vault`。
- 开机自启使用用户级启动项，例如 Electron `app.setLoginItemSettings` 或 HKCU Run。
- 不写 HKLM，不要求管理员权限。
- 如果杀软或 EDR 拦截，记录日志并在托盘状态显示。

启动自检项目：

- Codex 数据目录是否存在。
- 会话目录是否存在。
- Codex 目录是否可读。
- 本地备份目录是否可创建、可写。
- `manifest.json` 是否可读写。
- `cursors.sqlite` 是否可打开、建表、写入。
- 文件监听是否能启动。
- 开机自启是否已启用。

状态必须可见：

- 备份运行中。
- 等待 Codex 会话目录出现。
- 无权限读取 Codex 数据目录。
- 无法写入本地备份目录。
- 监听失败，已切换轮询模式。
- 开机自启未启用。
- 最近备份时间。

## 本机状态和诊断

第一阶段新增：

```text
~/.codex-session-vault/incremental-backups/status.json
```

示例字段：

```json
{
  "agentVersion": "1.1.0",
  "enabled": true,
  "status": "running",
  "mode": "watching",
  "codexRoot": "/Users/alice/.codex",
  "backupRoot": "/Users/alice/.codex-session-vault/incremental-backups",
  "firstRunAt": "2026-07-04T10:00:00Z",
  "lastStartedAt": "2026-07-04T10:00:00Z",
  "lastHeartbeatAt": "2026-07-04T10:12:00Z",
  "lastBackupAt": "2026-07-04T10:12:00Z",
  "sessionCount": 123,
  "lineCount": 4567,
  "bytesBackedUp": 9876543,
  "autoStartEnabled": true,
  "lastError": null
}
```

UI、菜单栏或托盘提供：

- 查看当前备份状态。
- 复制诊断信息。
- 打开日志目录。
- 打开备份目录。
- 查看最近错误。

第二阶段接 NAS 时，把 `status.json` 同步到：

```text
NAS/codex-backups/{employeeId}/{hostname}/status.json
```

IT 可以直接扫描 NAS 上的 `status.json` 做安装率和健康状态统计。

## 日志

滚动日志路径：

```text
~/.codex-session-vault/incremental-backups/logs/backup-agent.log
```

日志记录：

- agent 启动和停止。
- 自检结果。
- 新 session 发现。
- 每次追加备份的行数和字节数。
- 半行等待。
- 文件截断。
- 权限错误。
- 监听失败和轮询降级。
- manifest 或 cursor 写入失败。

日志大小限制为固定上限，例如 `5MB x 3`。

## 恢复策略

第一阶段恢复目标是：从本地增量备份生成文件型恢复包，并复用现有恢复逻辑。

用户选择一个或多个已备份 session 后，恢复模块生成临时恢复包：

```text
~/.codex-session-vault/incremental-restore-staging/<timestamp>/
  snapshot.json
  data/
    sessions/
      recovered/
        <session-id>.jsonl
    session_index.jsonl
```

恢复包生成规则：

- 从 manifest 定位 backupPath。
- 复制对应 `<session-id>.jsonl` 到 staging 的 `data/sessions/recovered/`。
- 根据 manifest 和 `.jsonl` 内容生成最小 `session_index.jsonl`。
- 写入 `snapshot.json`，标记这是增量备份生成的文件型快照。

恢复执行规则：

- 尽量复用现有“恢复单个会话”“批量恢复会话”“只恢复对话”路径。
- 恢复前仍创建保护点。
- 恢复后提示用户重启 Codex。
- 第一阶段不强行生成或合并 `state_5.sqlite`。

如果某些 Codex 版本仍依赖 SQLite 才能在桌面端列表显示，第一阶段至少保证 `.jsonl` 内容恢复到 Codex 数据目录；SQLite 最小线程记录生成放入后续阶段。

## macOS 接入

新增 Swift 模块文件：

```text
Sources/CodexSessionVault/Backup/
  BackupAgent.swift
  BackupManifest.swift
  BackupCursorStore.swift
  SessionTailer.swift
  BackupStatus.swift
  BackupRecoveryBuilder.swift
```

macOS 端职责：

- 在 App 启动时启动 BackupAgent。
- 使用 FSEvents、DispatchSource 或等效机制监听文件变化。
- 监听失败时切换轮询。
- 在主窗口或菜单栏显示备份状态。
- 使用 Login Item 或 LaunchAgent 支持开机自启。
- 复用现有 Swift 恢复逻辑处理恢复包。

## Windows 接入

新增 Electron/Node 模块：

```text
windows/codex_session_manager_electron/src/backup/
  backup-agent.js
  backup-manifest.js
  cursor-store.js
  session-tailer.js
  backup-status.js
  recovery-builder.js
```

Windows 端职责：

- 在 Electron 主进程启动时启动 BackupAgent。
- 使用 Node 文件监听，失败时切换轮询。
- 在托盘或窗口显示备份状态。
- 使用用户级开机自启。
- 复用现有 Electron 恢复逻辑处理恢复包。

## UI 状态

第一阶段 UI 保持克制，只展示必要信息：

```text
本地增量备份：运行中
最近备份：2026-07-04 10:12:30
已备份会话：123
模式：监听
错误：无
```

异常状态示例：

```text
无法读取 Codex 会话目录
无法写入本地备份目录
监听失败，已切换轮询
开机自启未启用
```

## 测试和验收

基础备份：

- 新建 Codex 对话后，本地备份目录自动出现对应 `<session-id>.jsonl`。
- 继续发送多条消息后，备份文件只追加新增行。
- 备份内容和源 `.jsonl` 新增行一致。
- `manifest.json` 更新 session 记录、行数、最近备份时间。
- `cursors.sqlite` 记录正确 offset。

重启恢复：

- 关闭 BackupAgent 后再启动，不重复备份旧行。
- 重启后继续发送消息，能从上次 offset 继续追加。
- 机器重启后开机自启能恢复备份。

半行和写入中：

- 模拟源文件半行写入，BackupAgent 不备份半行。
- 半行补全后正常备份。
- 防抖期间多次写入不重复追加。

异常场景：

- 源 `.jsonl` 临时不可读，记录错误并稍后重试。
- 备份目录不可写，不更新 cursor，并显示错误。
- 文件监听失败后切换轮询模式。
- 源文件截断或重写时，不覆盖已有备份，记录状态并保守处理。
- manifest 或 cursor 写失败时有日志和状态提示。

恢复测试：

- 选择一个已备份 session，能生成临时文件型恢复包。
- 恢复包能被现有恢复逻辑识别。
- 恢复后 `.jsonl` 文件回到 Codex 数据目录。
- 恢复后提示重启 Codex。
- 如果 Codex 列表不显示，也能打开恢复后的原始会话文件确认内容存在。

性能测试：

- 100、500、1000 个历史 session 扫描时不明显卡 UI。
- 大会话文件只按块读取，不一次性读入内存。
- 正常空闲时 CPU 接近 0。
- 日志不会无限增长。
- 备份状态刷新不会频繁触发 UI 重绘。

第一阶段完成标准：

- 新增对话自动备份，无需手动创建快照。
- 继续发送消息会自动追加备份。
- 重启后不会重复备份。
- 本地备份可生成恢复包。
- 权限、监听、写入错误不会静默失败。
- macOS 和 Windows 都按同一目录、manifest 和 cursor 语义工作。

## 推广安装

第一阶段推广目标是低门槛本地备份。

macOS：

- 提供 `.app` 或 `.pkg`。
- 首次打开后启用本地增量备份。
- 配置 Login Item 或 LaunchAgent。
- 菜单栏或主窗口展示备份状态。

Windows：

- 提供 `.exe` 安装包或便携包。
- 首次启动后启用本地增量备份。
- 使用用户级开机自启，不要求管理员权限。
- 托盘显示备份状态。

员工体验：

1. 安装。
2. 打开一次。
3. 看到“本地增量备份运行中”。
4. 正常使用 Codex。

IT 排查入口：

- 打开本地备份目录。
- 打开日志目录。
- 复制诊断信息。
- 查看最近一次备份时间。
- 查看已备份会话数量。
- 查看是否开机自启。

## 后续阶段

第二阶段：NAS 上传。

- 读取本地增量备份和 status。
- 上传到 `NAS/codex-backups/{employeeId}/{hostname}/`。
- NAS 不可用时本地继续排队。
- 上传 `status.json` 供 IT 汇总。

第三阶段：中心化监控。

- 安装率统计。
- 备份健康状态。
- 异常机器列表。
- 版本分布。
- 告警通知。

## 设计决策摘要

- 选择 `.jsonl` 新增行 + 最小 manifest，而不是全量快照。
- 日期放目录，session id 做文件名。
- 恢复依赖 manifest，不依赖目录日期。
- 先写备份，再更新 cursor。
- 监听失败自动轮询。
- 第一阶段不碰 NAS、不做中心后台、不重建完整 SQLite。
- 本地诊断和 `status.json` 进入第一阶段。

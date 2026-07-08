# 本地增量备份一键恢复设计

## 背景

当前项目已经实现本地增量备份：Codex 会话 `.jsonl` 文件新增完整行后，后台 tailer 会把新增内容追加到 `~/.codex-session-vault/incremental-backups`。这个能力解决了“对话持续备份”的问题，但当用户原始 Codex 会话丢失时，还需要一个低门槛入口把备份恢复回 Codex，让会话重新出现在 Codex 桌面端。

恢复的主要场景是：员工的 Codex 会话列表或会话文件丢失，需要用户主动点击恢复。这个功能不做静默自动恢复，避免误把旧备份写回当前仍正常使用的 Codex 数据目录。

## 目标

- 在现有“快照恢复”区域增加“备份恢复”入口。
- 从本地增量备份中列出可恢复会话。
- 默认只恢复当前 Codex 中缺失的会话。
- 已存在的会话不覆盖、不重复恢复。
- 恢复前创建保护点，方便回滚恢复动作本身。
- macOS 和 Windows 使用同一套恢复语义。
- 第一阶段只支持本机增量备份恢复，不依赖 NAS。

## 非目标

- 不做静默自动恢复。
- 不恢复账号、登录态、配置文件、API key 或其他非会话数据。
- 不覆盖当前 Codex 中已经存在的会话。
- 不做“回到某条消息时间点”的细粒度回滚。
- 不在第一阶段实现 NAS 远程恢复。
- 不把增量备份恢复设计成新的完整快照系统；它应复用现有恢复能力。

## 缺失会话定义

恢复入口只把“缺失会话”作为默认可操作对象。

会话视为缺失的情况：

- 备份 manifest 中存在该 `sessionId`，但当前 Codex 会话目录中找不到对应可读 `.jsonl`。
- 当前 `.jsonl` 存在或备份存在，但当前会话索引没有暴露该会话，导致 Codex 列表不可见。
- 当前会话文件被移动、删除或损坏，无法作为一个有效 Codex 会话读取。

会话视为已存在的情况：

- 当前 Codex 会话列表已经能看到该 `sessionId`。
- 当前 Codex 会话目录中已经有同一 `sessionId` 的可读 `.jsonl`，并且索引可以指向它。

第一阶段的判断来源：

- 当前 app 已扫描出的会话列表。
- `~/.codex/sessions`、`~/.codex/archived_sessions` 和 `~/.codex/sessions/recovered` 中的会话文件。
- `session_index.jsonl` 可读时的索引记录。
- `state_5.sqlite` 可读时的 threads 记录。
- 增量备份 `manifest.json` 和备份 `.jsonl` 文件。

## UI 设计

在“快照恢复”页面增加来源切换：

```text
[ 快照 ] [ 备份恢复 ]
```

“备份恢复”页顶部展示摘要：

- 备份目录路径。
- 最近备份时间。
- 已备份会话数量。
- 当前缺失会话数量。
- 备份异常数量。
- 最近错误信息。

列表默认只显示缺失会话，提供：

- 搜索标题、模型、目录、session id。
- “只看缺失”开关，默认开启。
- “显示已存在”开关，用于排查。

每个会话显示：

- 标题。
- session id 短值。
- 模型供应商和模型。
- 工作目录。
- 首次备份时间。
- 最近备份时间。
- 备份文件大小。
- 状态：`可恢复`、`已存在`、`备份文件缺失`、`备份异常`、`索引缺失`。

可操作按钮：

- 恢复当前选中缺失会话。
- 批量恢复勾选的缺失会话。
- 一键恢复全部缺失会话。

已存在会话的恢复按钮禁用，并显示“已存在，不会覆盖”。

## 恢复流程

恢复动作由用户手动触发。

流程：

```text
读取增量备份 manifest
校验 backupPath 是否仍位于 backupRoot 内
读取备份 .jsonl 并提取元数据
扫描当前 Codex 会话文件、session_index.jsonl 和 state_5.sqlite
把备份会话分类为缺失、已存在、异常
用户选择恢复一个或多个缺失会话
提示关闭 Codex 桌面端或确认继续
创建恢复前保护点
把增量备份构造成虚拟恢复包
写入 ~/.codex/sessions/recovered/<session-id>.jsonl
合并或生成 session_index.jsonl 记录
尽力写入 state_5.sqlite threads 记录
刷新当前 app 列表
提示重启 Codex 桌面端后查看恢复结果
```

恢复文件默认写入：

```text
~/.codex/sessions/recovered/<session-id>.jsonl
```

这样可以避免重建原始日期目录时误碰仍存在的文件，也能让恢复来源和原始 Codex 会话文件分开。恢复后的索引应指向 recovered 路径。

## 架构设计

### 共享语义

两端需要保持这些概念一致：

- `IncrementalBackupCatalog`：读取 manifest、status 和备份文件，形成可展示目录。
- `IncrementalRestoreCandidate`：单个可恢复候选会话。
- `IncrementalRestoreStatus`：`missing`、`existing`、`invalidBackup`、`indexMissing`、`restoreFailed`、`restored`。
- `RestoreSelection`：用户选择的一组缺失会话。
- `RestoreReport`：恢复结果、跳过数量、失败详情、保护点路径。

### macOS

macOS 端优先复用现有 Swift 恢复能力：

- 扩展 `BackupRecoveryBuilder`，支持从增量备份 manifest 构建虚拟恢复包。
- 复用现有快照恢复的保护点和写入流程。
- 新增“备份恢复” UI 数据源。
- 新增恢复动作，例如 `restoreIncrementalBackupSessions(sessionIDs:)`。
- 不修改现有手动快照恢复入口的语义。

### Windows

Windows 端实现 JS 等价能力：

- 新增增量备份 catalog 读取模块。
- 新增增量备份恢复包 builder。
- 通过 IPC 暴露：
  - `load-incremental-backup-sessions`
  - `restore-incremental-backup-sessions`
- Renderer 在“快照恢复”里增加“备份恢复”来源。
- 恢复路径使用 `%USERPROFILE%\.codex\sessions\recovered\<session-id>.jsonl`。

Windows 和 macOS 的恢复结果字段保持一致，方便后续文档、测试和 NAS 阶段复用。

## 索引和 SQLite 策略

只恢复 `.jsonl` 文件通常不够。Codex 是否能在列表中显示会话，还可能依赖 `session_index.jsonl` 和 `state_5.sqlite`。

恢复时按三层处理：

1. 必须恢复 `.jsonl`。
2. 必须合并或生成 `session_index.jsonl` 记录。
3. 尽力写入 `state_5.sqlite` 的 threads 记录。

SQLite 写入策略：

- 运行前检测 `state_5.sqlite` 是否存在、可打开、threads 表是否存在。
- 用当前数据库 schema 做列探测，不硬编码只适配单一版本。
- 对已存在 `sessionId` 的 row 不覆盖。
- 对缺失 row 尽力填充已知字段：
  - `id`
  - `rollout_path`
  - `created_at`
  - `updated_at`
  - `source`
  - `model_provider`
  - `model`
  - `cwd`
  - `title`
  - `preview`
  - `first_user_message`
  - `archived`
  - `recency_at`
- 对未知或 nullable 字段使用数据库默认值。
- 如果 SQLite 被锁定或 schema 不兼容，不让整个恢复失败；保留 `.jsonl` 和 `session_index.jsonl` 恢复结果，并在 UI 显示“SQLite 索引未写入，可能需要重启或重新扫描”。

## 安全设计

- 恢复前必须创建保护点。
- 默认只恢复缺失会话。
- 已存在会话不会覆盖。
- 每个 `backupPath` 必须做路径归一化校验，禁止跳出 backup root。
- 恢复失败只影响当前会话，不中断其他会话恢复。
- Codex 正在运行时提示风险；第一阶段建议用户关闭 Codex 后恢复。
- 不恢复 auth、config、credentials。
- 不删除增量备份。
- 不修改增量备份 cursor。

恢复后，后台备份 agent 可能会发现 `sessions/recovered` 下的新文件。由于 session id 相同，manifest 可以在后续扫描中把 sourcePath 更新为 recovered 路径，但不能产生重复备份记录。

## 错误处理

需要明确显示的错误：

- 找不到增量备份根目录。
- `manifest.json` 不存在或无法解析。
- manifest 中记录的备份文件缺失。
- 备份 `.jsonl` 无法读取。
- 备份 `.jsonl` 不是有效 JSONL。
- 会话已经存在，已跳过。
- 保护点创建失败。
- 恢复文件写入失败。
- `session_index.jsonl` 合并失败。
- `state_5.sqlite` 写入失败。

其中 `.jsonl` 写入失败和保护点创建失败是阻断错误；SQLite 写入失败是可恢复警告。

## 测试计划

macOS Swift tests：

- 读取增量备份 manifest 并正确列出候选会话。
- 当前会话存在时分类为 `existing`，恢复按钮不可用。
- 当前会话缺失时分类为 `missing`。
- `backupPath` 跳出 backup root 时分类为 `invalidBackup`。
- 从备份 `.jsonl` 构造虚拟恢复包。
- 恢复缺失会话后生成 recovered `.jsonl` 和索引记录。
- SQLite 可写时插入 threads row。
- SQLite 不可写时恢复文件成功，并返回 warning。

Windows Node tests：

- 与 macOS 等价的 manifest 读取和分类。
- recovered 路径使用 `%USERPROFILE%\.codex\sessions\recovered`。
- IPC 返回稳定的 `RestoreReport`。
- 已存在会话不覆盖。
- 备份文件缺失时只标记错误，不影响其他会话。

手动验收：

- 创建一条 Codex 会话并确认增量备份存在。
- 暂时移走原始 `.jsonl` 和相关索引记录。
- 打开 app 的“快照恢复 -> 备份恢复”。
- 确认可看到 1 条缺失会话。
- 点击恢复该会话。
- 确认恢复前保护点创建成功。
- 确认 `~/.codex/sessions/recovered/<session-id>.jsonl` 存在。
- 重启 Codex 桌面端，确认会话重新出现在列表中。
- 对一个已存在会话执行同样检查，确认 UI 显示已存在并禁止恢复。

## 上线验收标准

- 用户不需要理解文件路径，也能从“备份恢复”恢复丢失对话。
- 默认不会覆盖当前仍存在的会话。
- 恢复前一定有保护点。
- macOS 和 Windows 都能恢复同一结构的本地增量备份。
- 如果恢复不能完全完成，UI 明确告诉用户失败在哪一层。
- 恢复功能不改变现有自动增量备份、手动快照和快照恢复的行为。

# 增量备份恢复补写 SQLite 列表索引设计

## 背景

本地增量备份恢复已经能从 `~/.codex-session-vault/incremental-backups` 生成恢复包，并把缺失会话的 `.jsonl` 写入：

```text
~/.codex/sessions/recovered/<session-id>.jsonl
```

当前实现也会合并 `session_index.jsonl`，并且恢复前会创建保护快照，不覆盖当前已经存在的会话。

问题在于新版 Codex 桌面端主要依赖 `~/.codex/state_5.sqlite` 的 `threads` 表展示会话列表。当前增量恢复包没有 `state_5.sqlite`，恢复流程也只把 `session_index.jsonl` 和 `sessions` 交给 `restoreConversationsOnly`。结果是：文件已经恢复，但会话可能不会出现在新版 Codex 的会话列表里。

这个设计补上恢复后的最小 SQLite 列表索引写入，目标是让恢复出来的会话能稳定出现在新版 Codex 列表中。

## 目标

- 增量备份恢复后，缺失会话能出现在新版 Codex 会话列表中。
- macOS 和 Windows 使用同一语义。
- 只补 `state_5.sqlite.threads` 的最小可靠记录。
- 不覆盖当前已经存在的 `threads` 记录。
- 不把增量备份恢复升级成完整 SQLite 关系恢复。
- SQLite 写入失败时明确提示风险，但不回滚已经成功恢复的 `.jsonl` 和 `session_index.jsonl`。

## 非目标

- 不重建完整 `state_5.sqlite`。
- 不恢复 `thread_spawn_edges`、`agent_jobs`、`agent_job_items`、`thread_dynamic_tools` 等关联表。
- 不恢复账号、登录态、配置、API key 或凭据。
- 不覆盖已有会话文件或已有 `threads` 行。
- 不依赖 Codex 自身 backfill 机制重新扫描恢复文件。

## 选择的方案

采用“恢复后补 `threads` 行”的方案。

流程是在现有增量恢复完成文件写入后，基于本次恢复的 `restorableIDs`、增量备份 manifest、生成的恢复包 `session_index.jsonl` 和恢复 `.jsonl` 内容，向当前 Codex 的 `state_5.sqlite.threads` 插入缺失记录。

不选择“构造临时 `state_5.sqlite` 再走现有 mergeStateDatabase”的原因是：临时数据库需要复制当前 schema，容易受 Codex 版本变化影响，且实现更绕。

不选择“重置 backfill_state 让 Codex 自己重扫”的原因是：当前 `backfill_state` 可能已经是 `complete`，而 Codex 是否会扫描 `sessions/recovered` 不稳定，不能作为企业恢复链路的保证。

## 数据来源

每个恢复会话的 SQLite 行从这些来源组合：

- `BackupSessionRecord`
  - `sessionId`
  - `title`
  - `sourcePath`
  - `firstSeenAt`
  - `lastBackedUpAt`
  - `lineCount`
  - `bytesBackedUp`
- 恢复包 `session_index.jsonl`
  - `id`
  - `title`
  - `thread_name`
  - `rollout_path`
  - `updated_at`
- 恢复后的 `.jsonl`
  - 第一条用户消息，用于 `title`、`first_user_message`、`preview`
  - 时间戳，用于 `created_at`、`updated_at`
  - 可能存在的模型、供应商、工作目录、sandbox、approval 信息
- 当前 `state_5.sqlite` schema
  - 用 `PRAGMA table_info(threads)` 发现列和默认值
  - 只写入当前表存在的列

## threads 最小字段策略

必须优先填充这些字段：

- `id`
- `rollout_path`
- `created_at`
- `updated_at`
- `source`
- `model_provider`
- `cwd`
- `title`
- `sandbox_policy`
- `approval_mode`
- `tokens_used`
- `has_user_event`
- `archived`
- `first_user_message`
- `model`
- `preview`
- `recency_at`

如果当前 schema 存在这些字段，也尽量写入：

- `created_at_ms`
- `updated_at_ms`
- `recency_at_ms`
- `thread_source`
- `reasoning_effort`
- `cli_version`
- `memory_mode`
- `git_sha`
- `git_branch`
- `git_origin_url`
- `agent_nickname`
- `agent_role`
- `agent_path`

字段默认值：

- `source`: 优先 JSONL 或 manifest 可解析来源；否则 `recovered`
- `model_provider`: 优先 JSONL；否则 `unknown`
- `model`: 优先 JSONL；否则 `unknown`
- `cwd`: 优先 JSONL；否则空字符串
- `title`: manifest title；否则第一条用户消息；否则 session id
- `preview`: 第一条用户消息的短文本；否则空字符串
- `first_user_message`: 第一条用户消息；否则空字符串
- `sandbox_policy`: JSONL 可解析时使用解析值；否则空字符串
- `approval_mode`: JSONL 可解析时使用解析值；否则空字符串
- `tokens_used`: 0
- `has_user_event`: 找到用户消息为 1，否则 0
- `archived`: 0
- `archived_at`: NULL
- `cli_version`: 空字符串
- `memory_mode`: `enabled`

时间字段：

- 优先使用 JSONL 中第一条有效时间作为 `created_at`。
- 优先使用 JSONL 中最后一条有效时间或 manifest `lastBackedUpAt` 作为 `updated_at`。
- 秒级字段写 Unix seconds。
- 毫秒字段写 Unix milliseconds。
- `recency_at` 和 `recency_at_ms` 与 `updated_at` 对齐。

## 写入策略

恢复流程新增一个明确步骤：

```text
恢复 .jsonl 到 sessions/recovered
合并 session_index.jsonl
补写 state_5.sqlite.threads 缺失行
刷新管理 app 会话列表
提示用户重启 Codex
```

写入规则：

- 如果 `state_5.sqlite` 不存在，不阻塞恢复，返回“SQLite 索引未写入：数据库不存在”。
- 如果 `threads` 表不存在，不阻塞恢复，返回“SQLite 索引未写入：threads 表不存在”。
- 如果目标 `id` 已存在，不更新、不覆盖。
- 如果目标 `id` 不存在，执行 `INSERT`。
- 插入前用 schema 过滤列，只写当前存在的列。
- 对 NOT NULL 且无默认值的列，必须提供安全值。
- 每次恢复可用一个事务批量插入本轮缺失会话。

## macOS 设计

新增 Swift 内部能力：

- `RecoveredThreadIndexEntry`
  - 表示可插入 `threads` 的最小索引记录。
- `IncrementalRecoveredThreadMetadataExtractor`
  - 从 `BackupSessionRecord`、恢复路径和 JSONL 行提取字段。
- `ensureRecoveredThreadsInStateDatabase(...)`
  - 打开当前 `state_5.sqlite`。
  - 检查 `threads` schema。
  - 只插入缺失的 `id`。
  - 返回插入数量、跳过数量和 warning。

接入点：

- 在 `.restoreIncrementalBackupSessions` 中，`restoreConversationsOnly` 成功后调用。
- 恢复消息从“请重启 Codex 后查看”改为包含 SQLite 结果：
  - 成功：`已补写列表索引`
  - 降级：`文件已恢复，但 SQLite 列表索引未写入：<原因>`

## Windows 设计

新增 Electron main 端能力：

- `extractRecoveredThreadMetadata(record, recoveredPath, jsonlText)`
- `ensureRecoveredThreadsInStateDatabase(databasePath, entries)`

实现方式沿用现有 `sql.js` 数据库读写工具：

- 打开 `%USERPROFILE%\.codex\state_5.sqlite`
- 检查 `threads` 表和列
- `SELECT id FROM threads WHERE id = ?`
- 缺失时按当前 schema 生成 `INSERT`
- 写回数据库文件

接入点：

- 在 `restore-incremental-backup-sessions` handler 中，`restoreConversationsOnly` 后调用。
- 返回 message 中包含 SQLite 补写结果。

## 错误处理

恢复结果分为三层：

1. 文件恢复失败：本轮恢复失败，显示错误。
2. `session_index.jsonl` 合并失败：本轮恢复失败，显示错误。
3. `state_5.sqlite.threads` 补写失败：文件恢复保留，恢复结果显示 warning。

SQLite warning 必须用户可见，不允许静默吞掉。

典型 warning：

- `SQLite 索引未写入：state_5.sqlite 不存在`
- `SQLite 索引未写入：threads 表不存在`
- `SQLite 索引未写入：数据库被占用，请关闭 Codex 后重试`
- `SQLite 索引未写入：threads schema 不兼容`

## 安全和兼容

- 继续要求恢复前创建保护点。
- 继续默认只恢复缺失会话。
- 不覆盖已有会话。
- 不覆盖已有 `threads` 行。
- 不修改增量备份 manifest、cursor 或备份 JSONL。
- 不要求 Codex 必须关闭，但 UI 文案继续建议先关闭 Codex；如果 SQLite 被锁定，降级为 warning。
- 兼容 schema 增加字段：未知字段忽略，NOT NULL 无默认字段用安全值或返回 schema warning。
- 兼容 schema 删除字段：只写当前存在字段。

## 测试计划

macOS Swift tests：

- 恢复缺失会话后，`threads` 表新增对应 `id`。
- 已有 `threads.id` 不被覆盖。
- `state_5.sqlite` 不存在时，文件恢复结果保留并返回 warning。
- `threads` 表不存在时，返回 warning。
- 当前 schema 包含新增 nullable 字段时仍可插入。
- 当前 schema 缺少可选字段时仍可插入。
- `swift test` 全量通过。

Windows Node tests：

- 恢复缺失会话后，`threads` 表新增对应 `id`。
- 已有 `threads.id` 不被覆盖。
- `state_5.sqlite` 不存在时，返回 warning。
- `threads` 表不存在时，返回 warning。
- schema 增减可选字段时仍可插入。
- `npm test` 全量通过。

构建验证：

- `./scripts/build_app.sh`
- `npm run package:win`

手工验收：

- 准备一个当前 Codex 中不存在、但增量备份 manifest 中存在的测试会话。
- 执行“快照恢复 -> 备份恢复”。
- 确认 `~/.codex/sessions/recovered/<session-id>.jsonl` 存在。
- 确认 `~/.codex/session_index.jsonl` 有对应行。
- 确认 `~/.codex/state_5.sqlite` 的 `threads` 表有对应行。
- 重启 Codex 后确认该会话出现在列表中，并能打开查看原始对话内容。

## 上线判断

这个修复属于上线前必要项。原因是企业恢复场景的核心预期不是“文件在磁盘上存在”，而是“员工能在 Codex 桌面端列表里找回并打开会话”。如果只恢复 JSONL 和 `session_index.jsonl`，新版 Codex 可能仍然不可见，恢复体验会被认为失败。

完成本设计后，本地增量备份恢复才满足第一阶段上线口径：

- 自动增量备份可用。
- 手动从本地备份恢复缺失会话可用。
- 新版 Codex 列表显示恢复会话可用。
- 不覆盖现有会话。
- 失败和降级状态可见。

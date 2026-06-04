# codex_会话管理

`codex_会话管理` 是给 Codex 用户准备的本地会话管理、备份和恢复工具。它用来保护 `~/.codex` 里的会话、历史索引和线程状态，尤其适合频繁切换 Codex 账号、模型供应商或本地配置的人。

工具只读写本机文件，不上传会话、账号或配置数据。

## 当前版本状态

| 位置 | 状态 |
| --- | --- |
| GitHub `main` | 已包含 Codex 新版 SQLite 表结构兼容修复，以及前一版 UI 改造。 |
| GitHub Releases | 最新公开包为 `v1.0.13`，修复 Codex 更新后创建快照、恢复快照、删除会话等操作失败的问题。 |
| 最新安装包 | 请优先下载 `v1.0.13` 的 macOS 或 Windows zip。 |

下载稳定版：

[GitHub Releases](https://github.com/a110q/CodexSessionKeeper/releases)

- macOS：下载 `codex_session_keeper_macos_v1.0.13.zip`，解压后运行 `codex_会话管理.app`。
- Windows：下载 `codex_session_keeper_windows_v1.0.13.zip`，解压整个文件夹后运行 `codex_session_manager.exe`。

Windows 版本是免安装便携版。不要只拷贝单独的 exe 文件，Electron 运行时需要同目录下的 `resources`、`locales` 和 `.dll` 文件。

## 适用场景

- 切换 Codex 账号或模型供应商前，想保留当前会话。
- 切换配置后发现历史会话消失，需要从快照找回。
- 想查看、搜索、清理或归档本地 Codex 会话。
- 想从某个快照里只恢复一条或一批对话，而不覆盖当前登录态。

## 核心功能

- 会话管理：扫描当前 `~/.codex` 下的活跃会话、归档会话、模型、工作目录、更新时间、文件大小和文件状态。
- 会话搜索：按标题、目录、模型、来源、ID 或会话文件路径快速过滤。
- 会话预览：选中会话后在详情页预览前 20 条消息，双击或点击按钮可查看完整对话。
- 对话查看：支持查看用户/助手消息、打开原始会话文件、在文件夹中定位文件。
- 创建快照：备份 Codex 关键数据，包括会话文件、历史索引、状态库和必要配置。
- 快照恢复：支持只恢复对话、完整恢复、单个会话恢复、批量恢复选中会话。
- 归档恢复：快照内的归档会话也可以被识别和恢复。
- 删除保护：删除会话前自动创建轻量保护快照，再清理会话文件、历史索引和 SQLite 线程记录。
- 批量操作：支持批量删除会话、批量删除快照、批量恢复快照内会话。
- 自动找回：默认关闭，用户手动开启后，启动时才检测是否需要从最新保护点找回会话。
- 进度提示：恢复、删除、创建快照等慢操作会显示居中进度、原因说明和取消入口。

## 界面改进

`main` 分支已完成一轮 UI 改造：

- Windows 端恢复左侧品牌栏和“当前 Codex 状态”卡片，可看到 provider、model、account 和会话数量。
- “打开时自动找回”从顶部工具栏移动到侧栏设置区，降低主操作区噪音。
- macOS 与 Windows 统一为浅渐变、半透明卡片、16px 圆角、系统蓝主按钮和更清晰的危险按钮。
- Windows 端支持 `prefers-color-scheme: dark` 暗色模式。
- 会话列表改为“状态点 + 标题 + 相对时间 + 文件大小/来源”的信息层级，缺文件会以红点和标签提示。
- 详情面板默认展示会话预览，减少频繁打开弹窗的中断。
- 完整对话窗口使用用户靠右、助手靠左的消息布局，更适合扫读长对话。

## 数据位置

默认 Codex 数据目录：

```text
~/.codex
```

默认快照库目录：

```text
~/.codex-session-vault/snapshots
```

Windows 使用当前用户目录下的等效路径：

```text
%USERPROFILE%\.codex
%USERPROFILE%\.codex-session-vault\snapshots
```

## 推荐使用方式

切换账号、模型供应商或配置前，先创建一个手动快照。

恢复时优先使用“只恢复对话”。这个模式会合并恢复会话文件、历史记录和线程索引，不覆盖当前 `auth.json`、`config.toml`、账号登录态或模型供应商配置。

只有你明确想把账号、登录态和 `config.toml` 一起回滚到快照状态时，才使用“完整恢复”。

恢复或删除会话前，建议先退出 Codex 客户端。恢复完成后如果 Codex 已经打开，请重启 Codex 再查看恢复结果。

## 快照说明

快照一般会同时保存会话文件、历史索引和 SQLite 线程索引。

Codex 更新后，`state_5.sqlite` 里的线程相关表可能会变化。`v1.0.13` 起，工具会先检测表是否存在，再清洗或合并 SQLite 索引；如果新版 Codex 已移除 `thread_goals`、`stage1_outputs` 等旧表，不会再导致创建快照、恢复快照或删除会话整体失败。

如果 Windows 环境下 Codex 正在写入 `state_5.sqlite`，或者这个数据库临时不可读，工具会自动降级创建“文件型快照”。文件型快照仍包含 `history.jsonl`、`session_index.jsonl`、`sessions` 和 `archived_sessions`，可以继续恢复会话文件；只是会跳过 SQLite 索引清洗。看到“已降级创建文件型快照”不是创建失败。

如果你想创建包含完整 SQLite 索引的快照，先退出 Codex 客户端，再重新点击“创建快照”。

## 从源码构建

macOS App：

```bash
./scripts/build_app.sh
```

生成：

```text
dist/codex_会话管理.app
```

Windows Electron 免安装版：

```bash
./scripts/build_windows_exe.sh
```

生成：

```text
~/Downloads/codex_session_manager_win10_portable
~/Downloads/codex_session_manager_win10_portable.zip
```

首次构建 Windows 版本会自动安装 Electron 依赖并下载运行时，耗时取决于网络。

## 发布新版本

发布源码：

```bash
git status
git add README.md <changed-files>
git commit -m "Update documentation"
git push origin main
```

发布安装包：

1. 构建 macOS 与 Windows 产物。
2. 为新版本创建 tag，例如 `v1.0.13`。
3. 在 GitHub Releases 创建对应 release。
4. 上传 macOS zip 和 Windows zip。
5. 确认 Releases 侧栏的 `Latest` 指向新版本。

仅 `git push` 会更新源码，不会自动把本地 zip 上传到 GitHub Releases。上传 release assets 需要 GitHub 网页登录、GitHub CLI 登录，或有 `GITHUB_TOKEN` 的 API 权限。

## 常见问题

### Windows 提示 `database disk image is malformed`

这通常说明 Codex 的 `state_5.sqlite` 在当时不可读，可能是 Codex 正在写入、WAL 文件还没合并，或者数据库文件已经损坏。

`v1.0.10` 起不会因此中断创建快照，会自动降级为文件型快照。建议先退出 Codex 后再创建一次快照，如果仍反复出现，可以先使用文件型快照恢复重要会话。

### Windows 提示 `EPERM: operation not permitted, lstat`

这通常是某个会话 jsonl 文件被 Codex、杀毒软件、同步盘或权限策略临时锁住。`v1.0.11` 起创建快照会跳过单个不可访问文件，继续备份其他可读会话，并在成功提示里列出被跳过的文件。

### 快照里没有 `state_5.sqlite` 还能恢复吗

可以。只要快照里有 `sessions` 或 `archived_sessions` 下的 jsonl 会话文件，工具会从这些文件识别并恢复会话。恢复后建议重启 Codex。

### Codex 更新后所有快照功能都失败

如果错误里包含 `no such table: thread_goals` 或 `no such table: stage1_outputs`，说明 Codex 升级后本地 `state_5.sqlite` 表结构已经变化。请升级到 `v1.0.13` 或更新后的安装包；新版会跳过不存在的旧表，并继续处理仍存在的 `threads`、`thread_dynamic_tools`、`thread_spawn_edges` 和 `agent_job_items` 等线程索引。

### Windows 打开 exe 没反应

请确认解压了整个文件夹，不要只拷贝 `codex_session_manager.exe`。Electron 便携版必须和 `resources`、`locales`、`.dll` 等文件放在同一个目录。

### 为什么 GitHub 代码更新了，但 Releases 还是旧包

GitHub 的源码提交和 Releases 附件是两套流程。`git push origin main` 只会更新仓库源码；安装包 zip 需要另外在 GitHub Releases 上传。如果 Releases 仍显示旧版本，说明最新源码已推送，但最新包还没有发布成 release asset。

## 技术结构

- macOS：SwiftUI + Swift Package Manager。
- Windows：Electron + `sql.js`，无需用户安装 `sqlite3.exe`。
- SQLite 恢复：合并 `state_5.sqlite` 中的线程记录，并修复会话文件路径和归档状态。
- 快照策略：手动快照和系统自动保护点分开标记，系统快照有保留数量限制，避免无限增长。

## 文档

- [操作手册](docs/操作手册.md)
- [发布说明](docs/发布说明.md)
- [UI 与功能改进建议](lqf/UI_功能改进建议.md)

## 注意

这个工具直接操作 Codex 本地数据目录。虽然删除和恢复前会自动创建保护快照，但仍建议在操作前退出 Codex，避免 Codex 正在写入同一批文件。

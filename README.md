# codex_会话管理

给 Codex 用户的会话备份与恢复工具。

如果你经常切换 Codex 的模型供应商、账号或本地配置，可能遇到过一个很麻烦的问题：之前的对话突然找不到了，历史会话断掉，重要上下文丢失。

`codex_会话管理` 就是为了解决这个问题做的本地工具。它可以帮你管理、备份、恢复和清理 Codex 会话，让你在频繁切换账号、模型供应商或环境配置时，也能把重要对话稳稳保留下来。

## 下载

请到 GitHub Releases 下载对应系统的安装包：

- macOS：下载 `codex_session_keeper_macos_v1.0.10.zip`，解压后运行 `codex_会话管理.app`。
- Windows：下载 `codex_session_keeper_windows_v1.0.10.zip`，解压整个文件夹后运行 `codex_session_manager.exe`。

Windows 版本是免安装便携版。不要只拷贝单独的 exe 文件，Electron 运行时需要同目录下的 `resources`、`locales` 和 `.dll` 文件。

## 核心功能

- 会话管理：扫描并展示当前 `~/.codex` 下的会话、归档会话、模型、工作目录、更新时间和文件状态。
- 会话搜索：按标题、目录、模型、来源、ID 或会话文件路径快速过滤。
- 对话查看：双击会话可直接查看对话内容，也可以打开或定位原始会话文件。
- 创建快照：备份 Codex 关键数据，包括会话文件、历史索引、状态库和必要配置。
- 快照恢复：支持只恢复对话、完整恢复、单个会话恢复、批量恢复选中会话。
- 归档恢复：快照内的归档会话也可以被识别和恢复。
- 删除会话：删除前自动创建轻量保护快照，并清理会话文件、历史索引和 SQLite 线程记录。
- 批量操作：支持批量删除会话、批量删除快照、批量恢复快照内会话。
- 自动找回：默认关闭，用户手动开启后，启动时才检测是否需要从快照找回会话。
- 进度提示：恢复、删除、创建快照等慢操作会在屏幕中间显示进度条和原因说明。

## 数据位置

工具只读写本机文件，不上传会话或账号数据。

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

## 从源码构建

macOS App：

```bash
./scripts/build_app.sh
```

生成：

```text
dist/codex_会话管理.app
```

Windows 免安装 exe：

```bash
./scripts/build_windows_exe.sh
```

生成：

```text
~/Downloads/codex_session_manager_win10_portable
~/Downloads/codex_session_manager_win10_portable.zip
```

首次构建 Windows 版本会自动安装 Electron 依赖并下载运行时，耗时取决于网络。

## 技术结构

- macOS：SwiftUI + Swift Package Manager。
- Windows：Electron + `sql.js`，无需用户安装 `sqlite3.exe`。
- SQLite 恢复：合并 `state_5.sqlite` 中的线程记录，并修复会话文件路径和归档状态。
- 快照策略：手动快照和系统自动保护点分开标记，系统快照有保留数量限制，避免无限增长。

## 文档

- [操作手册](docs/操作手册.md)
- [发布说明](docs/发布说明.md)

## 注意

这个工具直接操作 Codex 本地数据目录。虽然删除和恢复前会自动创建保护快照，但仍建议在操作前退出 Codex，避免 Codex 正在写入同一批文件。

# codex_会话管理

`codex_会话管理` 是公司内部使用的本地 Codex 会话管理、增量备份和恢复工具。它保护当前用户目录中的会话、历史索引和线程状态，适合切换 Codex 账号、模型供应商或本地配置前后使用。

会话、快照和账号配置不会上传。应用只在公司内网检查签名更新元数据，并在员工确认后下载安装包。

## 版本状态

`1.1.0 (10100)` 已完成自动更新代码和本机自动化验证，但目前仍是上线候选，不是员工正式下载版。以下发布门槛尚未全部完成：

- Windows x64 NSIS 安装包构建和标准用户演练。
- macOS、Windows 各一次 `1.0.99 → 1.1.0` 真实设备演练。
- 更新私钥的外置加密备份。
- 经单独批准后在绿联 NAS 部署只读更新服务。

所有门槛完成前，不得把 `1.1.0` 放入员工下载目录，也不得把 `1.0.99` 放入正式更新目录。

## 员工安装和更新

首次安装：从公司 NAS 的员工下载目录安装 `1.1.0`。不要从聊天记录、个人网盘或未知链接下载安装包。

发现新版后的操作：

- 选择“稍后提醒”不会下载安装包，可以继续工作。
- 选择“立即更新”才开始下载，并显示进度。
- 下载完成后选择“稍后重启”可以继续工作。
- 选择“重启并更新”会先安全停止本地增量备份，确认没有备份写入后再安装并重启。
- 不在公司内网时，定时检查会静默跳过，不影响会话管理、备份或恢复。

当前公司内部版本没有 Apple/Windows 商业签名证书。首次安装如出现系统来源警告，只按公司管理员提供的安装说明确认；来源或文件名不一致时不要继续。

## 核心功能

- 扫描、搜索和预览活跃/归档 Codex 会话。
- 打开完整对话、原始会话文件或文件所在目录。
- 手动创建包含会话、历史和必要索引的快照。
- 后台增量备份 `.jsonl` 中新增的完整行。
- 从快照或本地增量备份恢复单条、批量或全部会话。
- 默认使用“只恢复对话”，不覆盖当前 `auth.json`、`config.toml` 或登录态。
- 删除会话前自动创建轻量保护快照。
- 自动找回默认关闭，只在员工主动开启后运行。
- macOS 和 Windows 均支持签名内网更新，更新不会强制安装。

## 数据位置

macOS/Linux 风格路径：

```text
~/.codex
~/.codex-session-vault/snapshots
~/.codex-session-vault/incremental-backups
```

Windows：

```text
%USERPROFILE%\.codex
%USERPROFILE%\.codex-session-vault\snapshots
%USERPROFILE%\.codex-session-vault\incremental-backups
```

更新状态只记录最近检查时间和待完成版本，保存在本地快照库根目录的 `update-state.json`。

## 推荐恢复方式

切换账号、模型供应商或配置前，先创建手动快照。恢复时优先使用“只恢复对话”；只有明确要回滚登录态和 `config.toml` 时才选择“完整恢复”。

恢复或删除会话前建议退出 Codex。恢复完成后如果 Codex 已打开，请重启 Codex 再查看结果。

如果 `state_5.sqlite` 正在写入、损坏或结构已经变化，工具会尽量降级为文件型快照。只要快照中仍有 `sessions` 或 `archived_sessions` 下的 `.jsonl`，会话文件仍可恢复；SQLite 索引失败会作为警告显示，不会删除已恢复文件。

## 从源码构建和测试

macOS：

```bash
swift test
APP_VERSION=1.1.0 APP_BUILD=10100 scripts/build_app.sh
```

输出：

```text
dist/codex_会话管理.app
dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip
```

Windows 安装包必须在 Windows x64 机器构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.1.0 -Build 10100
```

输出：

```text
dist\windows\CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
dist\windows\latest.yml
```

旧便携版构建已经停用，`scripts/build_windows_exe.sh` 会直接退出，防止生成无法自动更新的员工包。

发布工具测试：

```bash
node --test scripts/update/*.test.mjs
cd windows/codex_session_manager_electron && npm test
```

## 管理员发布

管理员必须使用签名清单和原子发布脚本，不得手工替换 `release.json`：

1. 构建 macOS ZIP、Windows Setup EXE 和 `latest.yml`。
2. 使用 `scripts/update/build-release-manifest.mjs` 组装候选目录。
3. 使用 `scripts/update/verify-release-directory.mjs` 独立验证签名、版本、大小和 SHA-256。
4. 完成两平台真实设备演练。
5. 经单独批准后使用 `scripts/update/publish-release.sh` 发布到固定内网 IP 为 `192.168.10.54` 的 Mac mini；该脚本最后才替换 `release.json`。

详细步骤见 [Mac mini 内网更新部署与发布](docs/Mac-mini内网更新部署与发布.md) 和 [操作手册](docs/操作手册.md)。

## 历史包应急恢复

旧安装包只用于管理员在隔离测试机上读取历史快照或导出会话，不再作为员工安装源，也不得放入自动更新目录。Windows 历史便携包必须完整解压整个文件夹，不能单独复制 EXE；恢复出重要会话后，应改用正式 NSIS 安装版。

## 注意

这个工具会直接操作 Codex 本地数据目录。虽然删除和恢复前会创建保护快照，仍应避免在 Codex 正写入同一批文件时执行高风险恢复操作。任何来源不明、签名验证失败或版本号异常的更新都不要安装。

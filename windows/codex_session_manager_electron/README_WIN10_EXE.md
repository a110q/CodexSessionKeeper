# codex_会话管理 Windows 安装版

Windows 正式版本使用当前用户范围的 NSIS 安装包：

```text
CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
```

安装不应请求管理员权限。安装完成后可从桌面或开始菜单启动 `codex_会话管理`，并可在 Windows“应用和功能”中卸载。

## 员工更新

- 应用在公司内网定期检查签名版本信息。
- “稍后提醒”不会下载；“立即更新”才开始下载。
- 下载后可选“稍后重启”继续工作。
- “重启并更新”会先等待本地增量备份停止写入，再启动安装。
- 不在内网时检查会静默跳过，不影响现有功能。
- 安装包大小或 SHA-256 与签名清单不一致时，临时安装包会被删除，不会显示“重启并更新”。

当前内部版本没有 Windows 商业代码签名证书。首次安装出现系统来源提示时，只按公司管理员提供的说明确认；文件名、来源或版本不一致时不要继续。

## 功能与数据

- 管理、预览、恢复和删除当前/归档会话。
- 创建手动快照和删除/恢复前保护点。
- 从快照或本地增量备份恢复缺失会话。
- SQLite 写入使用事务，索引不可用时保留已恢复的 JSONL 文件并显示警告。
- “打开时自动找回”默认关闭，由员工自行开启。

数据位于：

```text
%USERPROFILE%\.codex
%USERPROFILE%\.codex-session-vault\snapshots
%USERPROFILE%\.codex-session-vault\incremental-backups
```

恢复完成后如果 Codex 已打开，请重启 Codex 再查看结果。

## 管理员构建

只能在 Windows x64 机器运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.1.0 -Build 10100
```

必须同时保留 Setup EXE 和 Electron Builder 生成的 `latest.yml`，并交给发布 Mac 组装签名发布目录。不得手工编辑 `latest.yml`。

## 历史便携包

历史便携包只用于管理员应急读取旧快照，不再分发给员工，也不能进入自动更新目录。确需使用时必须完整解压，不能单独运行或复制其中的 EXE；恢复出重要会话后立即迁移到正式安装版。

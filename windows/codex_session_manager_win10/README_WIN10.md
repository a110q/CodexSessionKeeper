# codex_session_manager_win10

这是 `codex_会话管理` 的 Windows 10 便携版。双击 `Start-CodexSessionManager.cmd` 即可启动，不需要安装 Python 或 Node。

## 功能

- 自动定位 `%USERPROFILE%\.codex`。
- 列出 Codex 会话，支持搜索。
- 双击会话查看用户和助手对话记录。
- 右键会话可从最近快照恢复该会话。
- 删除会话前自动创建保护快照。
- 手动创建快照，默认保存到 `%USERPROFILE%\.codex-session-vault\snapshots`。

## sqlite3.exe

Windows 10 默认不带 `sqlite3.exe`。如果你希望恢复/删除时同步更新 Codex 的 `state_5.sqlite` 线程索引，请把 Windows 版 `sqlite3.exe` 放到：

```text
tools\sqlite3.exe
```

或者把 `sqlite3.exe` 加到系统 `PATH`。

没有 `sqlite3.exe` 时，应用仍可运行，会通过 JSONL 文件扫描会话并恢复会话文件，但 SQLite 索引合并会跳过。此时恢复后如果 Codex 列表没有立刻出现该会话，需要补装 `sqlite3.exe` 后再恢复一次。

## 使用建议

恢复或删除会话前建议先退出 Codex，避免正在写入的文件被覆盖。所有恢复/删除操作都会先创建保护快照。

这个工具只读写本机 `%USERPROFILE%\.codex` 和 `%USERPROFILE%\.codex-session-vault`，不联网、不上传数据。

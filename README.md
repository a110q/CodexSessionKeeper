# codex_会话管理

`codex_会话管理` 是给 Codex 用户准备的会话管理、备份和恢复工具。它在本机管理 `~/.codex`，并把会话 JSONL 增量备份到公司固定 NAS，重点防止员工误删、换机或本机故障造成会话内容丢失。

手动快照和恢复前保护点仍保存在本机；公司 NAS 只保存会话 JSONL、manifest 和状态信息，不上传 `auth.json`、`config.toml`、`state_5.sqlite` 或账号凭据。

## 版本状态

| 位置 | 状态 |
| --- | --- |
| 当前源码 | `v1.0.14`，包含公司 NAS 会话增量备份、校验恢复、后台常驻和空闲降载。 |
| GitHub Releases | 最新公开包为 `v1.0.13`，修复 Codex 更新后创建快照、恢复快照、删除会话等操作失败的问题。 |
| 本地构建 | 可生成 macOS DMG、Windows 每用户 NSIS 安装包和 Windows 免安装目录；当前安装包未签名，只用于公司内部测试。 |

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

- 会话管理：扫描当前 `~/.codex` 下的活跃会话、归档会话、模型、工作目录、更新时间、文件大小和文件状态。
- 会话搜索：按标题、目录、模型、来源、ID 或会话文件路径快速过滤。
- 会话预览：选中会话后在详情页预览前 20 条消息，双击或点击按钮可查看完整对话。
- 对话查看：支持查看用户/助手消息、打开原始会话文件、在文件夹中定位文件。
- 创建快照：备份 Codex 关键数据，包括会话文件、历史索引、状态库和必要配置。
- 公司 NAS 会话备份：后台扫描 Codex 会话 `.jsonl`，把新增完整行同步到固定公司 NAS，不需要员工手动选择文件夹。
- 首次配置：检测固定服务器 `192.168.10.99` 和“文件中转站”，员工只从实时目录中选择部门和姓名。
- 备份状态：页面显示未配置、NAS 不可用、首次备份、正常、待补传和错误状态；审计结果与修复次数记录在备份状态文件中。
- 旧设备恢复：可选择当前设备或同一员工名下的旧设备备份，只恢复当前缺失的会话。
- 快照恢复：支持只恢复对话、完整恢复、单个会话恢复、批量恢复选中会话。
- 归档恢复：快照内的归档会话也可以被识别和恢复。
- 删除保护：删除会话前自动创建轻量保护快照，再清理会话文件、历史索引和 SQLite 线程记录。
- 批量操作：支持批量删除会话、批量删除快照、批量恢复快照内会话。
- 自动找回：默认关闭，用户手动开启后，启动时才检测是否需要从最新保护点找回会话。
- 进度提示：恢复、删除、创建快照等慢操作会显示居中进度、原因说明和取消入口。
- 后台常驻：完成 NAS 配置后自动申请开机启动；Windows 关闭窗口后进入托盘，macOS 登录启动时不主动弹窗。

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

### 公司 NAS 会话备份

首次启动时必须完成配置。软件只连接以下固定位置：

```text
192.168.10.99 / 文件中转站 / codex会话备份
```

部门和姓名来自 NAS 的直接子目录，不能手工输入任意路径。配置后，每台电脑使用独立设备目录：

```text
codex会话备份/<部门>/<姓名>/devices/<设备>/incremental-backups/
  sessions/
  archived_sessions/
  manifest.json
  status.json
```

正常情况下，新增的完整会话记录会在 30 秒内被发现。无变化时这一步只比较内存快照和本地文件元数据，不读取游标数据库或 NAS；每 5 分钟执行一次只读 NAS 健康检查，每 30 分钟最多写一次状态心跳。完整写入探针只在首次配置、软件启动、重连或手动重试时执行。软件启动、首次激活、电脑唤醒以及确认 NAS 恢复连接后会立即补扫。每台设备每 24 小时错峰执行一次完整性审计。发现 NAS 会话与本机已验证的完整会话内容不一致时，软件只使用本机已验证内容自动修复；被替换的 NAS 内容先保存在应用自有的 `repair-quarantine/`，保留 30 天，并且每个会话最多保留 3 份。

NAS 只接收会话 JSONL、manifest 和备份状态。账号凭据、账号状态或登录态、本机快照、Codex 配置以及正在使用的 `state_5.sqlite` 数据库都不会上传。本机只保留游标、待补传元数据和错误状态，不保留另一份会话内容作为离线缓存。NAS 断开时，源会话仍留在 `~/.codex`，重新连接后会继续补传；如果 NAS 离线期间源会话也被删除，本工具无法凭空恢复该段尚未上传的内容，这是当前明确接受的限制。

状态页会显示 NAS 可用性和常规备份状态。最近一次成功审计时间、审计结果及累计修复次数写入本机和 NAS 的 `status.json`，当前页面不单独展示正在审计、正在修复或审计中断等瞬时状态。自动化测试只能验证这些流程的代码行为；macOS 和 Windows 10 实机验收及 24 小时资源测量是独立的 Task 10 发布门槛，完成前不能据此认定已通过正式发布验收。

公司共享盘当前使用共享身份 `171`。这能满足统一备份，但不能隔离员工之间的读取权限：任何拥有该共享身份和目录权限的人，都可能读取其他员工的明文会话。需要保密隔离时，必须由 NAS 管理员改为个人账号和按员工授权，不能依赖本软件界面实现权限隔离。

本机快照位置保持不变：

```text
~/.codex-session-vault/snapshots
```

快照用于恢复前回退和完整状态恢复，与 NAS 会话增量备份是两套互补机制。

切换账号、模型供应商或配置前，先创建手动快照。恢复时优先使用“只恢复对话”；只有明确要回滚登录态和 `config.toml` 时才选择“完整恢复”。

恢复或删除会话前建议退出 Codex。恢复完成后如果 Codex 已打开，请重启 Codex 再查看结果。

如果 `state_5.sqlite` 正在写入、损坏或结构已经变化，工具会尽量降级为文件型快照。只要快照中仍有 `sessions` 或 `archived_sessions` 下的 `.jsonl`，会话文件仍可恢复；SQLite 索引失败会作为警告显示，不会删除已恢复文件。

## 从源码构建和测试

macOS：

```bash
./scripts/build_app.sh
./scripts/build_macos_dmg.sh
```

输出：

```text
dist/codex_会话管理.app
dist/codex_session_keeper_macos_v1.0.14_internal-test-unsigned.dmg
```

Windows 每用户安装包（不要求管理员权限）：

```bash
cd windows/codex_session_manager_electron
npm ci
npm run dist:win
```

生成到 `dist/win10-installer/`，文件名含 `internal-test-unsigned`。卸载时会清理本软件创建的开机启动项。

Windows Electron 免安装版仍可构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.1.0 -Build 10100
```

输出：

```text
dist\windows\CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
dist\windows\latest.yml
```

旧便携版构建已经停用，`scripts/build_windows_exe.sh` 会直接退出，防止生成无法自动更新的员工包。

内部 P0 验收：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\acceptance\run_p0_windows.ps1
```

```bash
./scripts/acceptance/run_p0_macos.sh
```

Windows 验收只会在选中员工的 `devices/p0-acceptance-<UUID>/` 下创建隔离数据，清理前必须核对自有 marker。输出固定为 `p0-acceptance-report.json`、`resource-samples.csv` 和中文 `summary.txt`，不会记录会话正文。自动化结果不能替代双端开机启动、后台常驻、真实 NAS 重连和 24 小时资源验收；这些门槛未全部记录为通过前，不得标记为正式发布就绪。

## 发布新版本

发布源码：

```bash
node --test scripts/update/*.test.mjs
cd windows/codex_session_manager_electron && npm test
```

## 管理员发布

1. 构建 macOS 与 Windows 产物。
2. 为新版本创建 tag，例如 `v1.0.14`。
3. 在 GitHub Releases 创建对应 release。
4. 上传 macOS zip 和 Windows zip。
5. 确认 Releases 侧栏的 `Latest` 指向新版本。

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

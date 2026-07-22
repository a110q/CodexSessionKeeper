# Windows Electron 离线校验构建设计

**日期：** 2026-07-22

**状态：** 已确认，待实施计划

**适用分支：** `codex/nas-auto-update`

## 1. 背景

Windows 测试电脑已经成功运行全部 `109/109` 项 Node 测试，但 Electron Builder 26.15.3 在打包 `1.0.99` 时连接 `github.com:443` 超时。失败发生在 Electron 43.1.0 的 Windows x64 ZIP 已命中本机缓存之后。

调用链调查确认：`@electron/get` 即使命中缓存，默认仍会在线读取 Electron 官方发布中的 `SHASUMS256.txt`，再用该清单校验缓存 ZIP。网络请求失败后，Electron Builder 返回非零退出码，构建门禁正确停止。失败还暴露出另一个问题：构建脚本在写入临时版本 `1.0.99 / 10099` 后没有还原 `package.json` 和 `package-lock.json`，导致失败现场留下两个已修改的跟踪文件。

本设计同时解决：

- 保留 Electron ZIP 的 SHA-256 完整性校验，但移除每次构建对在线 `SHASUMS256.txt` 的依赖。
- 无论构建成功或失败，始终逐字节还原两个临时版本文件。
- 不改变应用运行时、更新协议、NAS 配置或员工安装行为。

## 2. 已确认的构建输入

- Electron：`43.1.0`
- Windows 目标：`win32-x64`
- 缓存文件名：`electron-v43.1.0-win32-x64.zip`
- Electron 官方 SHA-256：

```text
a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0
```

- 官方清单来源：

```text
https://github.com/electron/electron/releases/download/v43.1.0/SHASUMS256.txt
```

缓存中的 Electron ZIP、NSIS、NSIS resources 和 7zip 均已存在。方案不能关闭校验，也不能信任一个未经哈希验证的缓存文件。

## 3. 方案比较

### 方案 A：固定官方 Electron 校验值（采用）

在 Electron Builder 配置的 `electronDownload` 中设置官方 checksums 映射，并显式保持 `unsafelyDisableChecksums = false`。`@electron/get` 使用本地生成的校验清单验证缓存 ZIP，不再下载远端 `SHASUMS256.txt`。

优点：仍有严格完整性校验；构建可以使用现有缓存；改动小且可自动测试。

代价：升级 Electron 时必须同步更新文件名和官方 SHA-256。

### 方案 B：继续网络重试（不采用）

保持配置不变，等待 GitHub 请求偶然成功。

优点：无需代码改动。

缺点：Electron Builder 内部已经对 `ETIMEDOUT` 做过多次重试；结果仍受外网质量影响，不适合作为公司的可重复发布流程。

### 方案 C：搭建 Electron 构建镜像（暂不采用）

在 NAS 或其他内网服务托管 Electron 和 Electron Builder 工具包。

优点：可以实现完整离线构建。

缺点：需要镜像同步、哈希清单、访问控制和维护流程；当前只有一个已缓存的固定 Electron 版本，复杂度不必要。

## 4. 构建配置

`windows/codex_session_manager_electron/package.json` 的 `build` 配置增加：

```json
"electronDownload": {
  "unsafelyDisableChecksums": false,
  "checksums": {
    "electron-v43.1.0-win32-x64.zip": "a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0"
  }
}
```

`unsafelyDisableChecksums: false` 除了明确禁止绕过校验，还确保 Electron Builder 26.15.3 将该对象作为 `ElectronGetOptions` 处理，从而把 `checksums` 传给 `@electron/get`。

数据流：

```text
package.json 固定 SHA-256
  → Electron Builder 传给 @electron/get
  → 命中本机 Electron ZIP 缓存
  → 用固定 SHA-256 校验缓存字节
  → 校验通过后解压到 win-unpacked
  → NSIS 继续生成 Setup EXE
```

如果缓存 ZIP 被破坏，校验必须失败。构建不得因“离线”而跳过或降低完整性检查。

## 5. 临时版本文件事务

`scripts/build_windows_installer.ps1` 在修改版本前读取以下两个文件的原始字节：

- `windows/codex_session_manager_electron/package.json`
- `windows/codex_session_manager_electron/package-lock.json`

构建仍按现有顺序执行依赖安装、SQLite 准备、版本写入、测试和 Electron Builder 打包。最外层 `finally` 必须：

1. 恢复 PowerShell 工作目录。
2. 用保存的原始字节还原两个文件。

逐字节保存和还原可以保留编码、换行符和文件末尾格式。任何测试失败、下载失败、打包失败或产物验证失败都不得让临时版本留在工作区。

还原动作不能吞掉原始构建异常。还原自身失败也必须让构建失败，并明确指出无法恢复哪个文件。

## 6. 测试设计

新增或扩展 Windows 构建契约测试：

- 锁文件解析出的 Electron 版本必须是 `43.1.0`。
- `electronDownload.unsafelyDisableChecksums` 必须严格等于 `false`。
- checksums 必须且只能包含当前 Windows x64 Electron ZIP 的官方 SHA-256。
- 构建脚本必须在临时版本写入前保存两个文件的原始字节。
- 构建脚本必须在 `finally` 中还原两个文件。
- 现有“原生命令非零退出码立即失败”和“测试前准备 SQLite”契约继续保留。

执行遵循红—绿循环：先加入会在当前配置上失败的测试，确认失败原因是 checksum/恢复契约缺失，再做最小配置和脚本修改。

## 7. Windows 现场恢复与重建

新提交推送到 Windows 测试仓库后，测试电脑按以下顺序处理：

1. 确认现有 diff 只包含构建生成的 `1.0.99 / 10099` 版本变化。
2. 仅还原 `package.json` 和 `package-lock.json`，不触碰其他文件。
3. fast-forward 同步新提交并确认工作区干净。
4. 将失败构建留下的 `win-unpacked`、blockmap 和 builder debug 文件移动到独立隔离目录，不删除历史 `previous-b6bb94b`。
5. 验证缓存 ZIP 的 SHA-256 与固定官方值一致。
6. 重新构建 `1.0.99`；要求测试全通过、打包退出码为零、工作区自动恢复干净。
7. 构建 `1.1.0`；再次要求测试、产物、哈希、`latest.yml` 和工作区状态全部通过。

如果缓存 ZIP 哈希不匹配，立即停止，不使用该缓存，也不关闭校验。此时再单独设计可信下载或镜像补充流程。

## 8. 验收标准

- 完整 Node 测试全部通过。
- 构建配置固定 Electron 43.1.0 Windows x64 官方 SHA-256，且未关闭校验。
- 使用有效缓存构建时，不需要在线获取 Electron `SHASUMS256.txt`。
- `1.0.99` 和 `1.1.0` 均能生成新的 NSIS Setup EXE。
- `latest.yml` 指向 `1.1.0`，记录大小与实际安装包一致。
- 每次构建完成或失败后，`git status --short` 不包含临时版本修改。
- 不运行 Setup EXE，不访问 NAS，不修改现有 `1.0.14` 安装。

## 9. 非目标

- 不搭建 Electron/NPM 通用内网镜像。
- 不关闭 Electron 下载校验。
- 不把外部构建依赖上传到 NAS。
- 不修改客户端自动更新功能或发布清单协议。
- 不在本阶段处理 Windows 商业代码签名。

# NAS 内网自动更新设计

**日期：** 2026-07-21  
**状态：** 已确认，待实施计划  
**目标版本：** 公司内部首个正式版本 `1.1.0`

## 1. 背景与目标

`CodexSessionKeeper` 当前同时提供 macOS SwiftUI 应用和 Windows Electron 便携包，但没有自动更新能力。公司尚未正式上线该工具，也没有员工安装旧版本，因此不需要设计旧便携版或 `1.0.13` 的迁移路径。

公司现有一台绿联 DXP8800 NAS，运行 UGOS Pro，只要求员工在公司内网接收更新。首个正式内部版本直接包含更新能力：员工首次从 NAS 下载并安装 `1.1.0`，后续版本由应用发现并提示，员工点击“立即更新”后才下载和安装。

目标：

- 只依赖现有 NAS，不引入数据库或独立业务服务器。
- Windows 和 macOS 使用成熟的平台更新组件，不自研文件替换器。
- 更新检查不阻塞应用启动，NAS 不可用时不影响会话管理和备份功能。
- 更新包和清单必须通过密码学签名验证，安全性不依赖内网可信。
- 员工始终主动确认下载和重启，不强制更新。

非目标：

- 不支持公司外网更新。
- 不做强制升级、灰度发布、多更新通道或员工更新统计。
- 不让客户端上传文件到 NAS，也不让员工登录 NAS 管理后台。
- 第一阶段不购买 Apple Developer ID 或 Windows 商业代码签名证书。

## 2. 已确认的基础环境

- NAS：绿联 DXP8800，支持 Docker。
- 更新服务地址：`http://192.168.10.99:18080/codex-session-keeper/stable/`。
- 初始平台：macOS arm64 和 Windows x64，与当前构建目标一致。
- 当前 macOS 构建由 Swift Package Manager 和 `scripts/build_app.sh` 生成。
- 当前 Windows 构建由 Electron Packager 生成免安装目录；正式内部版本改为 Electron Builder 的 NSIS 每用户安装包。

## 3. 总体架构

```text
发布 Mac
  │ 构建、测试、签名、生成更新清单
  ▼
绿联 DXP8800
  └── Nginx Docker（静态文件、只读挂载、仅内网）
        │
        ├── release.json + release.json.sig
        ├── macos/appcast.xml + zip
        └── windows/latest.yml + NSIS.exe
                    ▲
                    │ 启动后检查，员工确认后下载
        ┌───────────┴───────────┐
        │                       │
  macOS Sparkle 2       Windows electron-updater
```

组件边界：

1. **NAS 更新服务**只提供静态文件。它没有写接口，不保存应用数据，不读取 Codex 会话。
2. **发布脚本**负责构建、测试、签名、生成元数据和原子发布。签名私钥不存放在 NAS。
3. **客户端更新协调层**负责检查时机、版本比较、提示、下载进度、备份任务停机协调和错误展示。
4. **平台更新组件**只负责平台相关的下载安装：macOS 使用 Sparkle 2，Windows 使用 `electron-updater` 的 NSIS 更新器。

## 4. NAS 部署

在 UGOS Pro 应用中心安装 Docker，并创建专用共享目录：

```text
codex-updates/
└── codex-session-keeper/
    └── stable/
        ├── release.json
        ├── release.json.sig
        ├── macos/
        │   ├── appcast.xml
        │   ├── appcast.xml.sig
        │   └── CodexSessionKeeper-1.1.0-macos-arm64.zip
        └── windows/
            ├── latest.yml
            └── CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
```

运行 `nginx:alpine` 容器：

- 映射 `NAS 18080` 到容器 `80`。
- 将 `codex-updates` 以只读方式挂载到 `/usr/share/nginx/html`。
- 设置容器随 NAS 自动启动。
- 禁止目录列表，只有知道完整路径的文件可以下载。
- 关闭 Nginx access log，避免为此功能额外保存员工 IP 和 User-Agent；保留有限且轮转的 error log 用于排障。
- 由公司路由器或 NAS 防火墙限制端口只在内网可访问。
- 对清单设置 `Cache-Control: no-cache`；带版本号的安装包可长期缓存。

客户端不使用 WebDAV、SMB 或 NAS 用户凭据。未来具备可信内网域名和证书后，只需把更新基址改为 HTTPS，不改变目录结构或客户端流程。

## 5. 发布元数据与签名

通用清单使用 UTF-8 JSON，签名使用独立文件，避免 JSON 字段顺序影响验证：

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "version": "1.1.0",
  "build": 10100,
  "publishedAt": "2026-07-21T00:00:00Z",
  "required": false,
  "notes": ["新增公司内网更新功能"],
  "platforms": {
    "macos-arm64": {
      "url": "macos/CodexSessionKeeper-1.1.0-macos-arm64.zip",
      "size": 12345678,
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "windows-x64": {
      "url": "windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe",
      "size": 87654321,
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
}
```

上面的大小和哈希是格式示例；发布脚本必须用实际产物的字节数和 64 位小写十六进制 SHA-256 替换它们。

- `release.json.sig` 是对 `release.json` 原始字节的 Ed25519 签名。
- 客户端内置公钥，发布私钥保存在发布 Mac 的钥匙串中，并保留一份加密离线备份。
- macOS 更新包额外使用 Sparkle EdDSA 签名；启用 `SUVerifyUpdateBeforeExtraction` 和 `SURequireSignedFeed`，对归档和 appcast 都进行验证。
- Windows 客户端先验证 `release.json.sig`，下载完成后再将安装包大小和 SHA-256 与签名清单对比；只有验证成功才允许 `quitAndInstall`。
- `latest.yml` 仍由 Electron Builder 生成，供 `electron-updater` 使用，但不能单独作为信任来源。
- 没有商业代码签名证书时，首次安装可能触发 macOS Gatekeeper 或 Windows SmartScreen 提示。应用内更新的真实性由 Ed25519 签名保证；以后增加平台证书不需要改变更新协议。

私钥丢失时不得生成新钥匙并直接覆盖公钥。由于第一阶段没有 Developer ID 提供安全换钥路径，应暂停发布，恢复离线备份，或重新进行一次全员可信安装。

## 6. 平台实现

### 6.1 macOS

- 通过 Swift Package Manager 集成 Sparkle 2。
- `Info.plist` 增加 `SUFeedURL`、`SUPublicEDKey`、签名 feed 配置和本地网络访问声明。
- `CFBundleShortVersionString` 使用对外版本，`CFBundleVersion` 使用严格递增的整数构建号。
- 更新包为保留权限和符号链接的 app zip，由 Sparkle 工具生成 appcast 和 EdDSA 签名。
- 更新重启前由应用协调停止增量备份监听并等待未完成的 manifest 写入。

### 6.2 Windows

- 从 `@electron/packager` 迁移到 Electron Builder。
- 构建目标为 x64 NSIS，每用户安装，不要求管理员权限。
- 引入 `electron-updater`，配置 generic provider 指向 NAS 的 Windows 目录。
- 设置 `autoDownload = false` 和 `autoInstallOnAppQuit = false`，下载和安装只响应员工操作。
- 主进程处理检查、下载、校验和安装；渲染进程只显示状态，通过受限 IPC 调用，不能传入任意下载 URL 或文件路径。
- 下载完成事件中再次验证签名清单所声明的安装包哈希，验证成功后才向界面暴露“重启并更新”。

## 7. 客户端交互与状态流

1. 主窗口稳定显示 5 秒后，在后台检查一次更新。
2. 应用持续运行时，每 8 小时最多检查一次；本地记录 `lastCheckAt`，不上传检查记录。
3. 连接或总请求超过 5 秒即视为本次不可用，静默结束，不影响其他功能。
4. 客户端获取 `release.json` 和签名，先验签，再进行平台和版本比较。
5. 有新版时，每次应用启动最多显示一次更新提示，包含版本号和更新说明。
6. 员工可选择“稍后提醒”或“立即更新”。稍后提醒延迟到下次启动或 8 小时后，不永久忽略版本。
7. 点击“立即更新”后才下载，界面显示进度、已下载大小和总大小。
8. 下载和验证完成后显示“稍后重启”和“重启并更新”。应用不会在员工未确认时突然退出。
9. 点击“重启并更新”后：
   - 停止增量备份监听；
   - 等待正在进行的备份 manifest 写入，最长 5 秒；
   - 保存窗口与必要的界面状态；
   - 调用平台更新组件退出、安装并重启。
10. 新版本首次启动读取本地更新完成标记，显示一次“已更新到 X.Y.Z”，随后清除标记。

`required` 字段第一阶段固定为 `false`。字段保留是为了协议前向兼容，但客户端第一阶段不得据此阻止用户使用应用。

## 8. 错误处理与回退

- NAS 不可达、清单不存在、超时或 DNS/路由失败：静默跳过，记录本地诊断日志。
- 清单签名失败、字段无效、版本倒退：拒绝更新，并显示“更新信息验证失败，请联系管理员”。
- 下载中断：保留平台组件支持的临时文件；允许员工稍后重新尝试，不无限自动重试。
- 包大小、哈希或更新签名不匹配：删除临时包，不执行安装。
- 增量备份无法在 5 秒内安全停止：取消本次重启更新，应用继续运行并提示稍后重试。
- 安装前发生错误：保持旧版本运行。
- 平台组件开始替换后的失败由 Sparkle/NSIS 报告；应用保留本地更新日志，管理员可使用 NAS 上保留的安装包人工恢复。
- NAS 保留最近三个稳定版本。需要业务回退时，将旧代码重新构建为更高版本和构建号后正常发布，不发布版本号倒退的清单。

不承诺跨平台自动回滚。Sparkle 和 NSIS 的替换行为不同，第一阶段采用“安装前不破坏旧版本 + 保留历史安装包 + 人工恢复”的可验证策略。

## 9. 发布流程

公司内部首次正式发布直接使用 `1.1.0`：

1. 完成客户端更新功能和 NAS 静态服务。
2. 构建 macOS arm64 zip 和 Windows x64 NSIS 安装包。
3. 运行全部单元测试和更新专项测试。
4. 生成哈希、Ed25519 签名、Sparkle appcast 和 Electron `latest.yml`。
5. 上传到 NAS 的候选目录。
6. 先构建只用于内部演练的 `1.0.99` 测试包，在一台 macOS 和一台 Windows 普通用户电脑上完整更新到 `1.1.0` 候选版；`1.0.99` 不进入员工下载目录。
7. 将版本化安装包复制到 `stable`。
8. 最后以同一文件系统内的重命名操作替换 `release.json`、签名和平台 feed，保证发布原子性。
9. 验证两端读取到新版本后，保留本次产物和最近两个历史版本。

版本使用语义版本号；构建号严格递增且不可复用。第一阶段只有 `stable`，不提供 beta/candidate 客户端通道；候选目录只供发布测试时使用明确的测试配置访问。

## 10. 测试与验收

自动化测试：

- 版本比较：升级、相同版本、版本倒退和非法版本。
- 清单解析：缺失字段、未知 schema、错误平台和超大字段。
- 签名与哈希：正确签名、清单篡改、安装包篡改和错误公钥。
- 状态机：检查、提示、延后、下载、验证、等待重启、安装和失败状态。
- 更新协调：正在写入备份时的安全停止、超时取消和正常恢复。
- Electron IPC：只允许固定更新动作，拒绝任意 URL 和路径。

集成测试：

- NAS 正常、离线、端口关闭、下载中断和慢速响应。
- macOS 应用位于 `/Applications` 和用户可写目录。
- Windows 普通用户首次安装、升级和卸载；验证不请求管理员权限。
- 从内部测试包 `1.0.99` 更新到候选 `1.1.0`，确认会话、快照、增量备份游标和设置均保持不变。
- 下载完成后选择“稍后重启”，继续使用应用，再主动完成更新。
- 更新失败后旧版本仍可启动，历史安装包可以人工恢复。

验收标准：

- 员工在内网启动应用后能在 10 秒内看到可用更新提示。
- 未点击“立即更新”时不下载安装包。
- 任意字节被篡改的清单或安装包都不能执行。
- NAS 离线时应用启动、会话管理和增量备份不受影响。
- 更新过程不丢失或覆盖员工的 Codex 会话、快照和备份状态。
- 首次正式发布前，在真实 macOS 和 Windows 设备上完成至少一次跨版本更新演练。

## 11. 参考资料

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle Publishing an Update](https://sparkle-project.org/documentation/publishing/)
- [electron-builder Auto Update](https://www.electron.build/docs/features/auto-update/)
- [electron-builder Target Selection Guide](https://www.electron.build/docs/targets/)
- [Apple NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [Apple Gatekeeper Support](https://support.apple.com/102445)
- [Microsoft SmartScreen Reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)

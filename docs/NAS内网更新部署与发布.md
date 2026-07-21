# 绿联 NAS 内网更新部署与发布

本方案为 `codex_会话管理` 提供公司内网更新下载服务。服务只接受 `GET` 和 `HEAD`，发布目录以只读方式挂载到 Nginx，不提供上传、登录、目录列表或应用 API。

正式地址：

```text
http://192.168.10.99:18080/codex-session-keeper/stable/
```

## 当前边界

仓库中的配置可以在本机检查，但下列步骤会改变 NAS 状态：创建目录、复制文件、创建 Docker 项目、开放端口、启动容器和发布版本。执行这些操作前必须再次取得用户明确批准。不得因为 NAS 管理页已经登录就直接部署。

私钥只保存在发布 Mac 的钥匙串和经批准的离线加密备份中。不得将私钥、密钥备份或 `1.0.99` 演练包放到 NAS 正式目录。

## 一、部署前准备

1. 在绿联 UGOS Pro 的“文件管理”中创建一个专用目录，例如共享文件夹中的 `docker/codex-update-server`。不要使用现有员工资料目录。
2. 将仓库 `deploy/nas/` 下的 `docker-compose.yml`、`nginx.conf` 和空目录 `codex-updates/` 复制到该专用目录，保持相对位置不变。
3. 在 `codex-updates/` 下创建运行时安全标记，内容必须完全一致：

   ```bash
   printf '%s\n' 'codex-session-keeper-update-root-v1' > codex-updates/.codex-update-root
   ```

   仓库中的 `.gitkeep` 不是安全标记，不能替代该文件。
4. 创建正式目录，但先不要放员工安装包：

   ```text
   codex-updates/
   ├── .codex-update-root
   └── codex-session-keeper/
       └── stable/
           ├── macos/
           └── windows/
   ```

## 二、在 UGOS Pro 创建只读更新服务

1. 打开 UGOS Pro 的 Docker 应用，进入“项目/Compose 项目”（不同 UGOS Pro 版本可能显示为“项目”）。
2. 选择“创建项目”，项目名填写 `codex-update-server`，项目路径选择上一步的专用目录。
3. 让 Docker 应用读取该目录中的 `docker-compose.yml`，检查端口映射为 `18080:80`。
4. 检查两个卷均为只读：

   ```text
   ./codex-updates -> /usr/share/nginx/html:ro
   ./nginx.conf     -> /etc/nginx/nginx.conf:ro
   ```
5. 确认容器根文件系统为只读，并启用了三个临时内存目录 `/var/cache/nginx`、`/var/run`、`/tmp`。
6. 创建并启动项目，确认 `codex-update-server` 状态为“运行中”，重启策略为 `unless-stopped`。

不要在路由器设置公网端口转发。NAS 防火墙只允许公司内网访问 TCP `18080`；如公司有多个 VLAN，只放行员工电脑所在网段。该 Nginx 没有登录页，安全边界依赖内网访问控制和只读挂载。

## 三、发布前组装和验证

Windows 安装包必须在 Windows 10/11 x64 标准用户测试机上构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 1.1.0 -Build 10100
```

在发布 Mac 构建 macOS 包，并准备只含字符串数组的版本说明文件：

```bash
APP_VERSION=1.1.0 APP_BUILD=10100 scripts/build_app.sh
```

将 Windows 生成的 Setup EXE 和 `latest.yml` 通过公司受控传输路径复制到发布 Mac，然后组装候选目录：

```bash
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip" \
  --windows-exe "$PWD/dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "$PWD/dist/windows/latest.yml" \
  --notes-file "$PWD/release-notes.json" \
  --output "$PWD/.release-staging/1.1.0"
```

再次独立验证：

```bash
node scripts/update/verify-release-directory.mjs \
  --root "$PWD/.release-staging/1.1.0/codex-session-keeper/stable"
```

成功时最后一行必须为：

```json
{"verified":true,"version":"1.1.0","build":10100}
```

## 四、原子发布

`publish-release.sh` 要求候选目录和正式目录位于同一文件系统。建议将已验证的候选目录复制到 `codex-updates/` 同一 NAS 卷中的临时发布区，再从发布 Mac 通过公司 NAS 挂载路径执行。脚本会重新验证候选内容；版本化 ZIP/EXE 已存在时，只有 SHA-256 完全相同才允许继续。

```bash
scripts/update/publish-release.sh \
  /Volumes/CompanyNAS/codex-updates/.verified-staging/1.1.0/codex-session-keeper/stable \
  /Volumes/CompanyNAS/codex-updates/codex-session-keeper/stable
```

发布顺序固定为：版本化安装包、`macos/appcast.xml`、`windows/latest.yml`、`release.json.sig`，最后才是 `release.json`。脚本不会自动删除旧版，只打印可供管理员手工检查的版本文件。保留当前版本及之前两个稳定版本。

## 五、部署和首次发布后的检查

首次正式发布后，在公司内网电脑执行：

```bash
curl -fsS http://192.168.10.99:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.99:18080/codex-session-keeper/stable/release.json
curl -X POST -i http://192.168.10.99:18080/codex-session-keeper/stable/release.json
curl -i http://192.168.10.99:18080/codex-session-keeper/stable/
```

验收结果：

- `GET` 返回签名清单，`HEAD` 包含 `Cache-Control: no-cache`。
- `POST` 返回 `405`。
- 目录地址不列出文件，通常返回 `403` 或 `404`。
- 版本化 `.zip`/`.exe` 返回 `Cache-Control: public, max-age=31536000, immutable`。
- NAS 重启后容器自动恢复运行。
- 公司内网之外无法访问 `192.168.10.99:18080`。

不要在双平台 `1.0.99 → 1.1.0` 标准用户演练全部通过前，把 `1.1.0` 放入员工下载目录。

## 六、故障与回滚

- 更新服务不可用时，客户端会跳过定时检查，现有备份、恢复和会话管理继续工作。
- 不要把 `release.json` 回退成较低版本。需要回滚代码时，将最后一个已知正常版本重新构建为更高语义版本和构建号，例如 `1.1.1 (10101)`，重新签名后发布。
- 发现清单、appcast、`latest.yml` 或安装包被意外修改时，立即停止容器并保留现场；不要用未验证文件覆盖。
- 删除旧版本属于单独的保留策略操作，发布脚本不会自动执行删除。

# Mac mini 内网更新部署与发布

正式发布根地址：

`http://192.168.10.54:18080/codex-session-keeper/stable/`

## 安全边界

- 仅允许 RFC 1918 私有地址访问，禁止公网端口转发。
- 员工和 Nginx worker 只有读取权限；管理员通过本机文件系统发布。
- 私钥只保存在发布 Mac 钥匙串和经批准的离线加密备份中。
- 安装 Nginx、LaunchDaemon 或发布版本前必须再次取得明确批准。

## 首次部署

1. 在目标 Mac mini 上确认 `ifconfig` 包含 `192.168.10.54`。
2. 确认 Mac mini 不会在工作时间自动休眠。
3. 从干净仓库运行 `deploy/mac-mini/install-static-update-server.sh`。
4. 验证 `sudo launchctl print system/com.company.codex-update-server`。
5. 验证 `NGINX_BIN="$("$(command -v brew)" --prefix nginx)/bin/nginx" && sudo "$NGINX_BIN" -t -c /usr/local/etc/codex-update-nginx.conf`。

## 构建与候选组装

使用现有 macOS 和 Windows 构建命令生成同版本、同构建号产物。然后运行：

```bash
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip" \
  --windows-exe "$PWD/dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "$PWD/dist/windows/latest.yml" \
  --notes-file "$PWD/release-notes/1.1.0.json" \
  --output "$PWD/.release-staging/1.1.0"

node scripts/update/verify-release-directory.mjs \
  --root "$PWD/.release-staging/1.1.0/codex-session-keeper/stable"
```

## 原子发布

先把候选复制到 Mac mini 站点所在文件系统，再发布：

```bash
sudo install -d -o root -g admin -m 0775 \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0

rsync -a --delete \
  "$PWD/.release-staging/1.1.0/" \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0/

scripts/update/publish-release.sh \
  /Users/Shared/codex-update-site/.verified-staging/1.1.0/codex-session-keeper/stable \
  /Users/Shared/codex-update-site/codex-session-keeper/stable
```

发布顺序为版本化产物、appcast、`latest.yml`、`release.json.sig`、`release.json`，最后生成并替换员工下载页 `index.html`。

## 发布后验证

```bash
curl -fsS http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -I http://192.168.10.54:18080/codex-session-keeper/stable/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
curl -fsS -r 0-1023 -D - -o /dev/null http://192.168.10.54:18080/codex-session-keeper/stable/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe
curl -X POST -i http://192.168.10.54:18080/codex-session-keeper/stable/release.json
curl -fsS http://192.168.10.54:18080/codex-session-keeper/
```

要求：清单 `no-cache`，版本化安装包 `immutable`，Range 请求返回 `206 Partial Content`，POST 返回 `405`，目录不列文件，下载页只链接已签名正式版本。

## 故障处理

- 服务停止：`sudo launchctl kickstart -k system/com.company.codex-update-server`。
- 配置异常：先运行 Nginx `-t`，通过后再重启 LaunchDaemon。
- 版本缺陷：修复后发布更高版本，不降低 `release.json` 版本。
- 文件疑似被修改：停止发布并保留现场，不使用未经验证的文件覆盖。
- 版本化安装包默认保留当前版本和前两个稳定版本；删除是单独审批操作。

param(
  [string]$TrustedRoot = "\\192.168.10.99\文件中转站\codex会话备份",
  [string]$Department = "",
  [string]$Employee = "",
  [string]$RuntimePath = "",
  [string]$OutputRoot = "",
  [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw "此验收脚本只能在 Windows 10/11 上运行。"
}
if (-not (Test-Path -LiteralPath $TrustedRoot -PathType Container)) {
  throw "公司 NAS 备份根目录不可用：$TrustedRoot"
}
if ([string]::IsNullOrWhiteSpace($Department)) {
  $Department = Read-Host "请输入管理员预建的部门目录名"
}
if ([string]::IsNullOrWhiteSpace($Employee)) {
  $Employee = Read-Host "请输入管理员预建的员工目录名"
}

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Runner = Join-Path $PSScriptRoot "p0-windows-runner.js"
if (-not (Test-Path -LiteralPath $Runner -PathType Leaf)) {
  throw "找不到 P0 验收执行器：$Runner"
}

if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
  $Candidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\codex_会话管理\codex_session_manager.exe"),
    (Join-Path $RepositoryRoot "dist\win10-exe\codex_session_manager-win32-x64\codex_session_manager.exe")
  )
  $RuntimePath = $Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($RuntimePath) -or -not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) {
  throw "找不到已安装或已打包的 codex_session_manager.exe；请用 -RuntimePath 指定完整路径。"
}
$PackagedAppRoot = Join-Path (Split-Path -Parent $RuntimePath) "resources\app"
if (-not (Test-Path -LiteralPath $PackagedAppRoot -PathType Container)) {
  throw "所选运行时不包含可验收的 resources\app：$PackagedAppRoot"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $OutputRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "CodexSessionKeeper-P0-$Timestamp"
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$Arguments = @(
  $Runner,
  "--trusted-root", $TrustedRoot,
  "--department", $Department,
  "--employee", $Employee,
  "--output", $OutputRoot
)
if ($Cleanup) { $Arguments += "--cleanup" }

$PreviousRunAsNode = $env:ELECTRON_RUN_AS_NODE
$PreviousAppRoot = $env:CODEX_P0_APP_ROOT
try {
  $env:ELECTRON_RUN_AS_NODE = "1"
  $env:CODEX_P0_APP_ROOT = $PackagedAppRoot
  & $RuntimePath @Arguments
  $ExitCode = $LASTEXITCODE
} finally {
  $env:ELECTRON_RUN_AS_NODE = $PreviousRunAsNode
  $env:CODEX_P0_APP_ROOT = $PreviousAppRoot
}

Write-Host ""
Write-Host "自动化报告：$(Join-Path $OutputRoot 'p0-acceptance-report.json')"
Write-Host "资源样本：$(Join-Path $OutputRoot 'resource-samples.csv')"
Write-Host ""
Write-Host "自动化完成后仍须人工记录：开机静默启动、托盘重新打开、明确退出、唤醒补传、真实 NAS 断开重连、24 小时资源曲线。"
exit $ExitCode

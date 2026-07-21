param(
  [string]$Version = "1.1.0",
  [int]$Build = 10100
)

$ErrorActionPreference = "Stop"

if (-not [Environment]::Is64BitOperatingSystem -or $env:OS -ne "Windows_NT") {
  throw "Windows x64 is required"
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must be X.Y.Z"
}
if ($Build -le 0) {
  throw "Build must be a positive integer"
}

$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root "windows\codex_session_manager_electron"
$Dist = Join-Path $Root "dist\windows"

Push-Location $App
try {
  npm ci
  $env:CODEX_RELEASE_VERSION = $Version
  $env:CODEX_RELEASE_BUILD = "$Build"
  node -e "const fs=require('fs');const p=require('./package.json');p.version=process.env.CODEX_RELEASE_VERSION;p.updateBuild=Number(process.env.CODEX_RELEASE_BUILD);fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n')"
  npm install --package-lock-only --ignore-scripts
  npm test
  npm run package:win
} finally {
  Pop-Location
}

$InstallerName = "CodexSessionKeeper-$Version-windows-x64-Setup.exe"
$Installers = @(Get-ChildItem -LiteralPath $Dist -Filter $InstallerName -File)
if ($Installers.Count -ne 1) {
  throw "Expected exactly one installer named $InstallerName"
}

$LatestYml = Join-Path $Dist "latest.yml"
if (-not (Test-Path -LiteralPath $LatestYml -PathType Leaf)) {
  throw "Missing latest.yml"
}
$LatestText = Get-Content -LiteralPath $LatestYml -Raw
if ($LatestText -notmatch [regex]::Escape($InstallerName) -or $LatestText -notmatch [regex]::Escape("version: $Version")) {
  throw "latest.yml does not reference the requested release"
}

Get-FileHash -Algorithm SHA256 -LiteralPath $Installers[0].FullName
Get-FileHash -Algorithm SHA256 -LiteralPath $LatestYml

# Windows Offline Electron Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows NSIS builds validate the cached Electron 43.1.0 archive against its pinned official SHA-256 without fetching `SHASUMS256.txt`, and always restore temporary package version edits after success or failure.

**Architecture:** Electron Builder receives a fixed checksum through `build.electronDownload`, so `@electron/get` generates its checksum input locally while retaining strict archive validation. The PowerShell build script snapshots `package.json` and `package-lock.json` as raw bytes, runs the existing build and artifact gates, restores both files in a finalizer, and then propagates any build or restoration error.

**Tech Stack:** Node.js 24 test runner, Electron 43.1.0, Electron Builder 26.15.3, Windows PowerShell 5.1, npm 11.

## Global Constraints

- Pin `electron-v43.1.0-win32-x64.zip` to SHA-256 `a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0` from Electron's official `v43.1.0/SHASUMS256.txt`.
- Keep `electronDownload.unsafelyDisableChecksums` strictly `false`; never bypass archive integrity validation.
- Preserve the existing native-command exit-code gate and Windows PowerShell 5.1 stderr handling.
- Restore `package.json` and `package-lock.json` byte-for-byte after every build outcome.
- Do not change application runtime behavior, update protocol, NAS configuration, installed `1.0.14`, or any Setup EXE.
- Push only to the `windows-test` remote branch `codex/nas-auto-update`; do not push to formal `origin`.

## File Structure

- Modify `windows/codex_session_manager_electron/package.json`: declare the pinned Electron archive checksum used by Electron Builder.
- Modify `windows/codex_session_manager_electron/test/build/windows-installer-script.test.js`: enforce the checksum/version coupling and transactional PowerShell contract.
- Modify `scripts/build_windows_installer.ps1`: snapshot and restore temporary release metadata without hiding build failures.
- No runtime source files or new dependencies are required.

---

### Task 1: Pin and test the official Electron archive checksum

**Files:**
- Modify: `windows/codex_session_manager_electron/package.json`
- Test: `windows/codex_session_manager_electron/test/build/windows-installer-script.test.js`

**Interfaces:**
- Consumes: `package-lock.json` entry `packages["node_modules/electron"].version`.
- Produces: `build.electronDownload: { unsafelyDisableChecksums: false, checksums: Record<string, string> }` for Electron Builder 26.15.3.

- [ ] **Step 1: Write the failing checksum contract test**

Add these constants after `buildScriptPath` in `test/build/windows-installer-script.test.js`:

```javascript
const appRoot = path.join(__dirname, '..', '..');
const packageJsonPath = path.join(appRoot, 'package.json');
const packageLockPath = path.join(appRoot, 'package-lock.json');
const electronWindowsX64Sha256 = 'a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0';
```

Add this test before the PowerShell source-contract tests:

```javascript
test('Windows build validates cached Electron against its pinned official checksum', () => {
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  const packageLock = JSON.parse(fs.readFileSync(packageLockPath, 'utf8'));
  const electronVersion = packageLock.packages['node_modules/electron'].version;
  const artifactName = `electron-v${electronVersion}-win32-x64.zip`;

  assert.equal(electronVersion, '43.1.0');
  assert.equal(packageJson.build.electronDownload.unsafelyDisableChecksums, false);
  assert.deepEqual(packageJson.build.electronDownload.checksums, {
    [artifactName]: electronWindowsX64Sha256,
  });
});
```

- [ ] **Step 2: Run the targeted test and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/build/windows-installer-script.test.js
```

Expected: one failure with `TypeError` because `packageJson.build.electronDownload` is currently undefined; the two existing build-script tests still pass.

- [ ] **Step 3: Add the minimal Electron Builder configuration**

Add this object immediately after `"appId"` inside `package.json`'s `build` object:

```json
"electronDownload": {
  "unsafelyDisableChecksums": false,
  "checksums": {
    "electron-v43.1.0-win32-x64.zip": "a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0"
  }
},
```

Do not add `isVerifyChecksum: false`, mirrors, download overrides, or new dependencies.

- [ ] **Step 4: Run the targeted test and verify GREEN**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/build/windows-installer-script.test.js
```

Expected: `3` tests, `3` passed, `0` failed.

- [ ] **Step 5: Commit the checksum contract**

Run from the repository root:

```bash
git add windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/test/build/windows-installer-script.test.js
git diff --cached --check
git commit -m "fix: pin Windows Electron archive checksum"
```

Expected: one commit containing only the package configuration and its test.

---

### Task 2: Restore temporary release metadata transactionally

**Files:**
- Modify: `scripts/build_windows_installer.ps1`
- Test: `windows/codex_session_manager_electron/test/build/windows-installer-script.test.js`

**Interfaces:**
- Consumes: existing `$App`, `$Dist`, `Invoke-CheckedNative`, `$Version`, and `$Build` values.
- Produces: byte-for-byte metadata restoration plus propagated `$BuildFailure` and `$RestoreFailures` errors.

- [ ] **Step 1: Write the failing restoration contract test**

Append this test to `test/build/windows-installer-script.test.js`:

```javascript
test('Windows installer build restores temporary release metadata after every outcome', () => {
  const source = fs.readFileSync(buildScriptPath, 'utf8');
  const snapshotIndex = source.indexOf('[System.IO.File]::ReadAllBytes($PackageJsonPath)');
  const lockSnapshotIndex = source.indexOf('[System.IO.File]::ReadAllBytes($PackageLockPath)');
  const mutationIndex = source.indexOf('set release metadata');
  const buildFailureIndex = source.indexOf('$BuildFailure = $_', mutationIndex);
  const finalizerIndex = source.indexOf('} finally {', buildFailureIndex);
  const packageJsonRestoreIndex = source.indexOf(
    '[System.IO.File]::WriteAllBytes($PackageJsonPath, $OriginalPackageJsonBytes)',
    finalizerIndex
  );
  const packageLockRestoreIndex = source.indexOf(
    '[System.IO.File]::WriteAllBytes($PackageLockPath, $OriginalPackageLockBytes)',
    finalizerIndex
  );

  assert.notEqual(snapshotIndex, -1);
  assert.notEqual(lockSnapshotIndex, -1);
  assert.ok(snapshotIndex < mutationIndex);
  assert.ok(lockSnapshotIndex < mutationIndex);
  assert.ok(mutationIndex < buildFailureIndex);
  assert.ok(buildFailureIndex < finalizerIndex);
  assert.ok(finalizerIndex < packageJsonRestoreIndex);
  assert.ok(finalizerIndex < packageLockRestoreIndex);
  assert.match(source, /catch \{\s*\$BuildFailure = \$_/);
  assert.match(source, /if \(\$BuildFailure -ne \$null\)[\s\S]*throw \$BuildFailure/);
  assert.match(source, /Failed to restore release metadata/);
});
```

- [ ] **Step 2: Run the targeted test and verify RED**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/build/windows-installer-script.test.js
```

Expected: the new restoration test fails at `assert.notEqual(snapshotIndex, -1)`; the three earlier tests pass.

- [ ] **Step 3: Snapshot both metadata files as bytes**

In `scripts/build_windows_installer.ps1`, add these variables after `$Dist`:

```powershell
$PackageJsonPath = Join-Path $App "package.json"
$PackageLockPath = Join-Path $App "package-lock.json"
$OriginalPackageJsonBytes = [System.IO.File]::ReadAllBytes($PackageJsonPath)
$OriginalPackageLockBytes = [System.IO.File]::ReadAllBytes($PackageLockPath)
$BuildFailure = $null
$RestoreFailures = @()
```

- [ ] **Step 4: Wrap the full build and artifact validation in a transaction**

Replace the script body from `Push-Location $App` through the two `Get-FileHash` calls with this complete block:

```powershell
try {
  Push-Location $App
  try {
    Invoke-CheckedNative "npm ci" { npm ci }
    Invoke-CheckedNative "prepare Windows SQLite" { npm run prepare:sqlite-win }
    $env:CODEX_RELEASE_VERSION = $Version
    $env:CODEX_RELEASE_BUILD = "$Build"
    Invoke-CheckedNative "set release metadata" { node -e "const fs=require('fs');const p=require('./package.json');p.version=process.env.CODEX_RELEASE_VERSION;p.updateBuild=Number(process.env.CODEX_RELEASE_BUILD);fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n')" }
    Invoke-CheckedNative "update package lock" { npm install --package-lock-only --ignore-scripts }
    Invoke-CheckedNative "npm test" { npm test }
    Invoke-CheckedNative "package Windows installer" { npm run package:win }
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
} catch {
  $BuildFailure = $_
} finally {
  try {
    [System.IO.File]::WriteAllBytes($PackageJsonPath, $OriginalPackageJsonBytes)
  } catch {
    $RestoreFailures += "${PackageJsonPath}: $($_.Exception.Message)"
  }
  try {
    [System.IO.File]::WriteAllBytes($PackageLockPath, $OriginalPackageLockBytes)
  } catch {
    $RestoreFailures += "${PackageLockPath}: $($_.Exception.Message)"
  }
}

if ($BuildFailure -ne $null) {
  if ($RestoreFailures.Count -gt 0) {
    throw "$($BuildFailure.Exception.Message)`nFailed to restore release metadata: $($RestoreFailures -join '; ')"
  }
  throw $BuildFailure
}
if ($RestoreFailures.Count -gt 0) {
  throw "Failed to restore release metadata: $($RestoreFailures -join '; ')"
}
```

The artifact checks remain inside the outer `try` so a missing or mismatched output still reaches the restoration finalizer.

- [ ] **Step 5: Run the targeted test and verify GREEN**

Run:

```bash
cd windows/codex_session_manager_electron
node --test test/build/windows-installer-script.test.js
```

Expected: `4` tests, `4` passed, `0` failed.

- [ ] **Step 6: Commit transactional restoration**

Run from the repository root:

```bash
git add scripts/build_windows_installer.ps1 windows/codex_session_manager_electron/test/build/windows-installer-script.test.js
git diff --cached --check
git commit -m "fix: restore Windows build metadata"
```

Expected: one commit containing only the PowerShell transaction and its source-contract test.

---

### Task 3: Verify and publish the implementation to the Windows test remote

**Files:**
- Verify: `windows/codex_session_manager_electron/package.json`
- Verify: `windows/codex_session_manager_electron/package-lock.json`
- Verify: `windows/codex_session_manager_electron/test/build/windows-installer-script.test.js`
- Verify: `scripts/build_windows_installer.ps1`

**Interfaces:**
- Consumes: Task 1 and Task 2 commits.
- Produces: a clean `codex/nas-auto-update` branch whose remote head can be fast-forwarded by the Windows test computer.

- [ ] **Step 1: Reconfirm the official checksum source**

Run:

```bash
curl -fsSL --retry 3 https://github.com/electron/electron/releases/download/v43.1.0/SHASUMS256.txt | rg 'electron-v43\.1\.0-win32-x64\.zip$'
```

Expected:

```text
a07dc1e3d5e589593d37e3b19d1b373e02bb58270e2eb0d6633eee0198ad09f0 *electron-v43.1.0-win32-x64.zip
```

- [ ] **Step 2: Run the full Windows Node test suite**

Run:

```bash
cd windows/codex_session_manager_electron
npm test
```

Expected: `111` tests, `111` passed, `0` failed.

- [ ] **Step 3: Run dependency and diff checks**

Run from `windows/codex_session_manager_electron`:

```bash
npm audit --audit-level=high
```

Expected: exit code `0` and no high-or-critical vulnerabilities.

Run from the repository root:

```bash
git diff --check
git status -sb
```

Expected: no whitespace errors and a clean branch ahead of `windows-test/codex/nas-auto-update` only by the reviewed commits.

- [ ] **Step 4: Push only to the Windows test remote**

Run:

```bash
git push windows-test codex/nas-auto-update
git ls-remote windows-test refs/heads/codex/nas-auto-update
git rev-parse HEAD
```

Expected: the `ls-remote` hash exactly equals local `HEAD`. Do not push `origin` and do not create a PR against the formal repository.

---

### Task 4: Recover the Windows worktree and rebuild both candidates

**Files:**
- Restore generated changes only: `windows/codex_session_manager_electron/package.json`
- Restore generated changes only: `windows/codex_session_manager_electron/package-lock.json`
- Preserve: `dist/windows/previous-b6bb94b/**`
- Quarantine: failed `win-unpacked`, blockmaps, and builder diagnostics
- Produce: `dist/windows/CodexSessionKeeper-1.0.99-windows-x64-Setup.exe`
- Produce: `dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe`
- Produce: `dist/windows/latest.yml`

**Interfaces:**
- Consumes: the remote branch published by Task 3 and the existing official Electron ZIP cache.
- Produces: two verified NSIS candidates and a clean Windows Git worktree; it does not install or publish them.

- [ ] **Step 1: Prove the only dirty files are generated release metadata**

Run on the Windows test computer from the repository root:

```powershell
git status --short
git diff -- windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/package-lock.json
```

Expected: exactly those two files, with only `1.1.0 / 10100` changed to `1.0.99 / 10099`. Stop if any other change exists.

- [ ] **Step 2: Restore only the two generated metadata files and fast-forward**

Run:

```powershell
git restore -- windows/codex_session_manager_electron/package.json windows/codex_session_manager_electron/package-lock.json
git status --short
git pull --ff-only origin codex/nas-auto-update
$LocalHead = git rev-parse HEAD
$RemoteHead = (git ls-remote origin refs/heads/codex/nas-auto-update).Split()[0]
if ($LocalHead -ne $RemoteHead) { throw "Local HEAD does not match remote test branch" }
git status --short
```

Expected: both status checks after restoration/sync are empty, and local/remote hashes match.

- [ ] **Step 3: Quarantine only the failed build outputs**

Run:

```powershell
$Quarantine = ".\dist\windows\previous-failed-49fe9ed"
New-Item -ItemType Directory -Path $Quarantine -Force | Out-Null
foreach ($Name in @(
    "win-unpacked",
    "builder-debug.yml",
    "CodexSessionKeeper-1.0.99-windows-x64-Setup.exe.blockmap",
    "CodexSessionKeeper-1.1.0-windows-x64-Setup.exe.blockmap"
)) {
    $Source = Join-Path ".\dist\windows" $Name
    if (Test-Path -LiteralPath $Source) {
        Move-Item -LiteralPath $Source -Destination $Quarantine
    }
}
```

Expected: `previous-b6bb94b` remains untouched; only the listed failed outputs move.

- [ ] **Step 4: Verify every cached Electron ZIP before building**

Run:

```powershell
$ExpectedElectronHash = "A07DC1E3D5E589593D37E3B19D1B373E02BB58270E2EB0D6633EEE0198AD09F0"
$ElectronZips = @(Get-ChildItem "$env:LOCALAPPDATA\electron\Cache" -Recurse -File -Filter "electron-v43.1.0-win32-x64.zip")
if ($ElectronZips.Count -eq 0) { throw "Electron 43.1.0 Windows x64 cache is missing" }
foreach ($Zip in $ElectronZips) {
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip.FullName).Hash
    [PSCustomObject]@{ Path = $Zip.FullName; Length = $Zip.Length; SHA256 = $Hash }
    if ($Hash -ne $ExpectedElectronHash) { throw "Electron cache checksum mismatch: $($Zip.FullName)" }
}
```

Expected: every discovered cache entry matches the official hash. Stop on any mismatch; never disable checksum validation.

- [ ] **Step 5: Prepare the already-validated tool PATH without system changes**

Run:

```powershell
$PythonWrapper = Join-Path $env:TEMP "codex-python3-wrapper-421b4b2"
if (-not (Test-Path -LiteralPath (Join-Path $PythonWrapper "python3"))) {
    throw "Validated python3 wrapper is missing"
}
$env:PATH = "$PythonWrapper;D:\git\Git\bin;D:\git\Git\usr\bin;D:\git\Git\mingw64\bin;$env:PATH"
bash --version
curl --version
unzip -v
bash -c 'command -v python3 && python3 --version'
```

Expected: all four commands return exit code `0`, and Python reports `3.14.6`.

- [ ] **Step 6: Build and verify `1.0.99` without output stream merging**

Run exactly, without `Tee-Object`, `2>&1`, or `*>&1`:

```powershell
$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\scripts\build_windows_installer.ps1" -Version "1.0.99" -Build 10099
    $Build1099Exit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousPreference
}
if ($Build1099Exit -ne 0) { throw "1.0.99 build failed with exit code $Build1099Exit" }
git status --short
```

Expected: build exit `0`, Node tests `111/111`, the `1.0.99` Setup EXE exists, and `git status --short` is empty because metadata was restored automatically.

- [ ] **Step 7: Build and verify `1.1.0`**

Run exactly, with the same output restrictions:

```powershell
$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\scripts\build_windows_installer.ps1" -Version "1.1.0" -Build 10100
    $Build110Exit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousPreference
}
if ($Build110Exit -ne 0) { throw "1.1.0 build failed with exit code $Build110Exit" }
git status --short
```

Expected: build exit `0`, Node tests `111/111`, the `1.1.0` Setup EXE and `latest.yml` exist, and Git status is empty.

- [ ] **Step 8: Verify final artifacts and manifest**

Run:

```powershell
$Artifacts = @(
    ".\dist\windows\CodexSessionKeeper-1.0.99-windows-x64-Setup.exe",
    ".\dist\windows\CodexSessionKeeper-1.1.0-windows-x64-Setup.exe",
    ".\dist\windows\latest.yml"
)
foreach ($Artifact in $Artifacts) {
    $Item = Get-Item -LiteralPath $Artifact
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Artifact).Hash
    [PSCustomObject]@{
        Path = $Item.FullName
        Length = $Item.Length
        LastWriteTime = $Item.LastWriteTime
        SHA256 = $Hash
    }
}
Get-Content -LiteralPath ".\dist\windows\latest.yml" -Raw
```

Expected: `latest.yml` has version `1.1.0`, both URL fields name the `1.1.0` Setup EXE, and its recorded size equals the actual byte length.

- [ ] **Step 9: Run final tests and safety checks**

Run:

```powershell
Push-Location ".\windows\codex_session_manager_electron"
try {
    npm test
    $FinalTestExit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($FinalTestExit -ne 0) { throw "Final npm test failed with exit code $FinalTestExit" }
git status --short
```

Expected: `111/111` tests pass and Git status is empty. Confirm separately that no Setup EXE ran, existing `1.0.14` was not started/removed/overwritten, NAS was not accessed, and no release script ran.

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot "session-data-security.ps1")

$script:AppVersion = "0.1.0"
$script:CodexRoot = Join-Path $env:USERPROFILE ".codex"
$script:VaultRoot = Join-Path $env:USERPROFILE ".codex-session-vault"
$script:SnapshotRoot = Join-Path $script:VaultRoot "snapshots"
$script:Sessions = @()
$script:Snapshots = @()

function Join-ChildPath {
    param([string]$Root, [string]$Child)
    return [System.IO.Path]::Combine($Root, $Child)
}

function Get-SqliteExe {
    $local = Join-ChildPath (Split-Path -Parent $PSScriptRoot) "tools\sqlite3.exe"
    if (Test-Path $local) { return $local }

    $cmd = Get-Command "sqlite3.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Convert-ToSqlLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Convert-ToSqlIdentifier {
    param([string]$Value)
    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-Sqlite {
    param([string]$Database, [string]$Sql, [switch]$Json)
    $sqlite = Get-SqliteExe
    if (-not $sqlite) { throw "sqlite3.exe not found" }

    $args = @("-cmd", ".bail on", "-cmd", ".timeout 5000")
    if ($Json) { $args += "-json" }
    $args += $Database
    $args += $Sql

    $output = & $sqlite @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join "`n")
    }
    return ($output -join "`n")
}

function Get-FileSize {
    param([string]$Path)
    if (Test-Path $Path) { return (Get-Item $Path).Length }
    return 0
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $sum = 0
    Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sum += $_.Length
    }
    return $sum
}

function Convert-DbSecondsToDate {
    param($Value)
    try { return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$Value)).LocalDateTime } catch { return Get-Date }
}

function Convert-UnixMsToDate {
    param($Value)
    try { return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value)).LocalDateTime } catch { return Get-Date }
}

function Convert-IsoToDate {
    param([string]$Value)
    try { return ([DateTimeOffset]::Parse($Value)).LocalDateTime } catch { return Get-Date }
}

function Get-JsonLineObject {
    param([string]$Line)
    try { return $Line | ConvertFrom-Json } catch { return $null }
}

function New-SessionObject {
    param(
        [string]$Id,
        [string]$Title,
        [string]$RolloutPath,
        [string]$Cwd,
        [string]$Provider,
        [string]$Model,
        [string]$Source,
        [DateTime]$CreatedAt,
        [DateTime]$UpdatedAt,
        [bool]$Archived
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = $Id }

    return [pscustomobject]@{
        Id = $Id
        Title = $Title.Trim()
        RolloutPath = $RolloutPath
        Cwd = $Cwd
        Provider = $Provider
        Model = $Model
        Source = $Source
        CreatedAt = $CreatedAt
        UpdatedAt = $UpdatedAt
        Archived = $Archived
        ExistsOnDisk = (Test-Path $RolloutPath)
        SizeBytes = Get-FileSize $RolloutPath
    }
}

function Load-SessionsFromSqlite {
    $database = Join-ChildPath $script:CodexRoot "state_5.sqlite"
    if (-not (Test-Path $database)) { return @() }
    if (-not (Get-SqliteExe)) { return @() }

    $sql = @"
SELECT
  id,
  title,
  cwd,
  model_provider AS modelProvider,
  COALESCE(model, 'unknown') AS model,
  source,
  created_at AS createdAt,
  updated_at AS updatedAt,
  archived
FROM threads
ORDER BY updated_at DESC, created_at DESC;
"@
    $json = Invoke-Sqlite -Database $database -Sql $sql -Json
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }

    $rows = @($json | ConvertFrom-Json)
    $trustedFiles = @(Get-TrustedSessionFileIndex -CodexRoot $script:CodexRoot)
    $result = @()
    foreach ($row in $rows) {
        $sessionId = Normalize-SessionIdentity $row.id
        if ($null -eq $sessionId) { continue }
        $trusted = @($trustedFiles | Where-Object { $_.SessionId -ceq $sessionId } | Select-Object -First 1)
        $rolloutPath = if ($trusted.Count -gt 0) { $trusted[0].Path } else { "" }
        $result += New-SessionObject `
            -Id $sessionId `
            -Title ([string]$row.title) `
            -RolloutPath $rolloutPath `
            -Cwd ([string]$row.cwd) `
            -Provider ([string]$row.modelProvider) `
            -Model ([string]$row.model) `
            -Source ([string]$row.source) `
            -CreatedAt (Convert-DbSecondsToDate $row.createdAt) `
            -UpdatedAt (Convert-DbSecondsToDate $row.updatedAt) `
            -Archived ([int]$row.archived -eq 1)
    }
    return $result
}

function Load-TitleMaps {
    $titles = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    $archived = [System.Collections.Generic.Dictionary[string,bool]]::new([System.StringComparer]::Ordinal)

    $history = Join-ChildPath $script:CodexRoot "history.jsonl"
    if (Test-Path $history) {
        $document = Read-SessionJsonlFile -Path $history -Kind "history"
        foreach ($record in $document.Records) {
            if ($record.Object.first_text) { $titles[$record.SessionId] = [string]$record.Object.first_text }
            if ($record.Object.is_archived -ne $null) { $archived[$record.SessionId] = [bool]$record.Object.is_archived }
        }
    }

    $index = Join-ChildPath $script:CodexRoot "session_index.jsonl"
    if (Test-Path $index) {
        $document = Read-SessionJsonlFile -Path $index -Kind "sessionIndex"
        foreach ($record in $document.Records) {
            if ($record.Object.thread_name) { $titles[$record.SessionId] = [string]$record.Object.thread_name }
        }
    }

    return [pscustomobject]@{ Titles = $titles; Archived = $archived }
}

function Load-SessionsFromFiles {
    $maps = Load-TitleMaps
    $result = @()
    foreach ($file in @(Get-TrustedSessionFileIndex -CodexRoot $script:CodexRoot)) {
        $id = $file.SessionId
        $meta = $file.Meta
        $title = $meta.title
        if ($maps.Titles.ContainsKey($id)) { $title = $maps.Titles[$id] }
        $isArchived = $file.Path.IndexOf(([System.IO.Path]::DirectorySeparatorChar + "archived_sessions" + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($maps.Archived.ContainsKey($id)) { $isArchived = [bool]$maps.Archived[$id] }

        $item = Get-Item -LiteralPath $file.Path

        $result += New-SessionObject `
            -Id $id `
            -Title $title `
            -RolloutPath $file.Path `
            -Cwd $meta.cwd `
            -Provider $meta.provider `
            -Model $meta.model `
            -Source $meta.source `
            -CreatedAt $item.CreationTime `
            -UpdatedAt $item.LastWriteTime `
            -Archived $isArchived
    }

    return @($result | Sort-Object UpdatedAt -Descending)
}

function Load-Sessions {
    if (-not (Test-Path $script:CodexRoot)) { return @() }
    try {
        $fromDb = @(Load-SessionsFromSqlite)
        if ($fromDb.Count -gt 0) { return $fromDb }
    } catch {
    }
    return @(Load-SessionsFromFiles)
}

function Load-Snapshots {
    if (-not (Test-Path $script:SnapshotRoot)) { return @() }
    $items = @()
    Get-ChildItem -Path $script:SnapshotRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $metaPath = Join-ChildPath $_.FullName "snapshot.json"
        if (Test-Path $metaPath) {
            try {
                $meta = Get-Content -Path $metaPath -Raw | ConvertFrom-Json
                $items += [pscustomobject]@{
                    Id = [string]$meta.id
                    Name = [string]$meta.name
                    CreatedAt = Convert-IsoToDate ([string]$meta.createdAt)
                    Path = $_.FullName
                    DataPath = Join-ChildPath $_.FullName "data"
                    Meta = $meta
                }
            } catch {
            }
        }
    }
    return @($items | Sort-Object CreatedAt -Descending)
}

function Get-BackupCandidates {
    return @(
        "config.toml",
        "auth.json",
        ".codex-global-state.json",
        ".codex-global-state.json.bak",
        "history.jsonl",
        "history.jsonl.bak",
        "session_index.jsonl",
        "sessions",
        "archived_sessions",
        "state_5.sqlite",
        "state_5.sqlite-shm",
        "state_5.sqlite-wal",
        "logs_2.sqlite",
        "logs_2.sqlite-shm",
        "logs_2.sqlite-wal",
        "sqlite",
        "shell_snapshots",
        "ambient-suggestions"
    )
}

function Get-ConversationBackupCandidates {
    return @(
        "history.jsonl",
        "history.jsonl.bak",
        "session_index.jsonl",
        "sessions",
        "archived_sessions",
        "state_5.sqlite",
        "shell_snapshots",
        "ambient-suggestions"
    )
}

function Copy-PathIntoSnapshot {
    param([string]$RelativePath, [string]$DataPath)
    $source = Join-ChildPath $script:CodexRoot $RelativePath
    if (-not (Test-Path $source)) { return }

    $dest = Join-ChildPath $DataPath $RelativePath
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -Path $source -Destination $dest -Recurse -Force
}

function New-CodexSnapshot {
    param([string]$Name, [string]$Reason, [string[]]$Candidates)
    if (-not (Test-Path $script:CodexRoot)) { throw "Codex root not found: $script:CodexRoot" }
    if (-not (Test-Path $script:SnapshotRoot)) { New-Item -ItemType Directory -Path $script:SnapshotRoot -Force | Out-Null }

    $id = (Get-Date).ToString("yyyyMMdd-HHmmss") + "-" + $Reason
    $snapshotPath = Join-ChildPath $script:SnapshotRoot $id
    $dataPath = Join-ChildPath $snapshotPath "data"
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null

    foreach ($candidate in $Candidates) {
        Copy-PathIntoSnapshot -RelativePath $candidate -DataPath $dataPath
    }

    $sessionsDir = Join-ChildPath $script:CodexRoot "sessions"
    $archivedDir = Join-ChildPath $script:CodexRoot "archived_sessions"
    $sessionCount = 0
    $archivedCount = 0
    if (Test-Path $sessionsDir) { $sessionCount = @(Get-ChildItem -Path $sessionsDir -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue).Count }
    if (Test-Path $archivedDir) { $archivedCount = @(Get-ChildItem -Path $archivedDir -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue).Count }

    $meta = [ordered]@{
        id = $id
        name = $Name
        createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        codexRoot = $script:CodexRoot
        modelProvider = "unknown"
        model = "unknown"
        accountFingerprint = "none"
        sessionCount = $sessionCount
        archivedSessionCount = $archivedCount
        sizeBytes = Get-DirectorySize $dataPath
        includedPaths = @($Candidates | Where-Object { Test-Path (Join-ChildPath $script:CodexRoot $_) })
        appVersion = "win10-$script:AppVersion"
    }
    ($meta | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-ChildPath $snapshotPath "snapshot.json") -Encoding UTF8
    return $snapshotPath
}

function New-SessionProtectionSnapshot {
    param([string]$Name, [string]$Reason, $Plan)
    Assert-SessionProtectionPlanFresh -Plan $Plan -Phase "protection preflight"

    if (-not (Test-Path $script:SnapshotRoot)) { New-Item -ItemType Directory -Path $script:SnapshotRoot -Force | Out-Null }
    $id = (Get-Date).ToString("yyyyMMdd-HHmmss-fff") + "-" + $Reason + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $snapshotPath = Join-ChildPath $script:SnapshotRoot $id
    $dataPath = Join-ChildPath $snapshotPath "data"
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null

    $staged = @()
    $includedPaths = @()
    try {
        foreach ($file in $Plan.TrustedFiles) {
            $relative = Get-RelativeTrustedPath -Root $script:CodexRoot -Path $file.Path
            $destination = Join-ChildPath $dataPath $relative
            $staged += Copy-SessionStagedFile -SourcePath $file.Path -DestinationPath $destination -ExpectedDigest $file.Fingerprint.Digest
            $includedPaths += $relative
        }
        foreach ($output in $Plan.JsonlPlan.Outputs) {
            $namePart = Split-Path -Leaf $output.DestinationPath
            $staged += Write-SessionStagedText -DestinationPath (Join-ChildPath $dataPath $namePart) -Data $output.Data
            $includedPaths += $namePart
        }

        Assert-SessionProtectionPlanFresh -Plan $Plan -Phase "protection commit"
        Publish-SessionStagedFiles -Staged $staged

        $archivedCount = @($Plan.TrustedFiles | Where-Object {
            $_.Path.IndexOf(([System.IO.Path]::DirectorySeparatorChar + "archived_sessions" + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count
        $meta = [ordered]@{
            id = $id
            name = $Name
            createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            codexRoot = $script:CodexRoot
            modelProvider = "unknown"
            model = "unknown"
            accountFingerprint = "none"
            sessionCount = $Plan.SessionIds.Count
            archivedSessionCount = $archivedCount
            sizeBytes = Get-DirectorySize $dataPath
            includedPaths = @($includedPaths)
            appVersion = "win10-$script:AppVersion"
        }
        $metaData = ($meta | ConvertTo-Json -Depth 6) + "`n"
        $metaStage = Write-SessionStagedText -DestinationPath (Join-ChildPath $snapshotPath "snapshot.json") -Data $metaData
        Publish-SessionStagedFiles -Staged @($metaStage)
        return $snapshotPath
    } catch {
        foreach ($entry in $staged) { Remove-Item -LiteralPath $entry.TemporaryPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $snapshotPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Find-LatestSnapshotRollout {
    param([string]$SessionId)
    $snapshots = @(Load-Snapshots)
    foreach ($snapshot in $snapshots) {
        $data = $snapshot.DataPath
        if (-not (Test-Path $data)) { continue }
        $trusted = Resolve-TrustedSessionFiles -SessionIds @($SessionId) -CodexRoot $data
        if ($trusted.Files.Count -gt 0) {
            return [pscustomobject]@{ Snapshot = $snapshot; Rollout = $trusted.Files[0].Path }
        }
    }
    return $null
}

function Get-SqliteColumns {
    param([string]$Database, [string]$Table)
    $sql = "PRAGMA table_info($(Convert-ToSqlIdentifier $Table));"
    $out = Invoke-Sqlite -Database $Database -Sql $sql
    $cols = @()
    foreach ($line in ($out -split "`n")) {
        $parts = $line -split "\|"
        if ($parts.Count -gt 1) { $cols += $parts[1] }
    }
    return $cols
}

function Test-SqliteTable {
    param([string]$Database, [string]$Table)
    try {
        $sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=$(Convert-ToSqlLiteral $Table);"
        $out = Invoke-Sqlite -Database $Database -Sql $sql
        return -not [string]::IsNullOrWhiteSpace($out)
    } catch { return $false }
}

function Merge-SingleSessionStateDb {
    param([string]$SnapshotDb, [string]$DestDb, [string]$SessionId, [string]$RolloutPath = "")
    if (-not (Get-SqliteExe)) { return "sqlite3.exe missing; SQLite merge skipped." }
    if (-not (Test-Path $SnapshotDb) -or -not (Test-Path $DestDb)) { return "SQLite database missing; SQLite merge skipped." }

    $tableRules = @(
        @{ Table = "threads"; Where = "id = $(Convert-ToSqlLiteral $SessionId)" },
        @{ Table = "thread_goals"; Where = "thread_id = $(Convert-ToSqlLiteral $SessionId)" },
        @{ Table = "thread_dynamic_tools"; Where = "thread_id = $(Convert-ToSqlLiteral $SessionId)" },
        @{ Table = "stage1_outputs"; Where = "thread_id = $(Convert-ToSqlLiteral $SessionId)" },
        @{ Table = "thread_spawn_edges"; Where = "parent_thread_id = $(Convert-ToSqlLiteral $SessionId) OR child_thread_id = $(Convert-ToSqlLiteral $SessionId)" },
        @{ Table = "agent_job_items"; Where = "assigned_thread_id = $(Convert-ToSqlLiteral $SessionId)" }
    )

    $deletes = @()
    $inserts = @()
    foreach ($rule in $tableRules) {
        if (-not (Test-SqliteTable -Database $SnapshotDb -Table $rule.Table)) { continue }
        if (-not (Test-SqliteTable -Database $DestDb -Table $rule.Table)) { continue }
        $srcCols = @(Get-SqliteColumns -Database $SnapshotDb -Table $rule.Table)
        $dstCols = @(Get-SqliteColumns -Database $DestDb -Table $rule.Table)
        $common = @($dstCols | Where-Object { $srcCols -contains $_ })
        if ($common.Count -eq 0) { continue }
        $cols = ($common | ForEach-Object { Convert-ToSqlIdentifier $_ }) -join ", "
        $table = Convert-ToSqlIdentifier $rule.Table
        $deletes += "DELETE FROM $table WHERE $($rule.Where);"
        $inserts += "INSERT INTO $table ($cols) SELECT $cols FROM snapshot.$table WHERE $($rule.Where);"
    }

    if ($inserts.Count -eq 0) { return "No SQLite rows merged." }

    $rolloutUpdate = ""
    $threadColumns = @(Get-SqliteColumns -Database $DestDb -Table "threads")
    if (-not [string]::IsNullOrWhiteSpace($RolloutPath) -and
        $threadColumns -contains "id" -and
        $threadColumns -contains "rollout_path") {
        $archivedUpdate = ""
        if ($threadColumns -contains "archived") {
            $separator = [System.IO.Path]::DirectorySeparatorChar
            $isArchived = $RolloutPath.IndexOf(($separator + "archived_sessions" + $separator), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            $archiveValue = if ($isArchived) { "1" } else { "0" }
            $archivedUpdate = ", archived = " + $archiveValue
        }
        $rolloutUpdate = "UPDATE threads SET rollout_path = $(Convert-ToSqlLiteral $RolloutPath)$archivedUpdate WHERE id = $(Convert-ToSqlLiteral $SessionId);"
    }

    $sql = @"
PRAGMA foreign_keys = OFF;
PRAGMA busy_timeout = 5000;
ATTACH DATABASE $(Convert-ToSqlLiteral $SnapshotDb) AS snapshot;
BEGIN IMMEDIATE;
$($deletes -join "`n")
$($inserts -join "`n")
$rolloutUpdate
COMMIT;
DETACH DATABASE snapshot;
PRAGMA foreign_keys = ON;
"@
    try {
        Invoke-Sqlite -Database $DestDb -Sql $sql | Out-Null
    } catch {
        if ($_.Exception.Message -match 'constraint|primary key|unique') {
            $conflict = New-Object System.IO.InvalidDataException("SQLITE_RESTORE_CONFLICT: selected session conflicts with an unselected SQLite row")
            $conflict.Data['Code'] = 'SQLITE_RESTORE_CONFLICT'
            throw $conflict
        }
        throw
    }
    return "SQLite index merged."
}

function Delete-SingleSessionStateDb {
    param([string]$DestDb, [string]$SessionId)
    if (-not (Get-SqliteExe)) { return "sqlite3.exe missing; SQLite delete skipped." }
    if (-not (Test-Path $DestDb)) { return "SQLite database missing; SQLite delete skipped." }
    $sid = Convert-ToSqlLiteral $SessionId
    $rules = @(
        @{ Table = "thread_dynamic_tools"; Where = "thread_id = $sid" },
        @{ Table = "thread_goals"; Where = "thread_id = $sid" },
        @{ Table = "thread_spawn_edges"; Where = "parent_thread_id = $sid OR child_thread_id = $sid" },
        @{ Table = "stage1_outputs"; Where = "thread_id = $sid" },
        @{ Table = "agent_job_items"; Where = "assigned_thread_id = $sid" },
        @{ Table = "threads"; Where = "id = $sid" }
    )
    $deletes = @()
    foreach ($rule in $rules) {
        if (Test-SqliteTable -Database $DestDb -Table $rule.Table) {
            $deletes += "DELETE FROM $(Convert-ToSqlIdentifier $rule.Table) WHERE $($rule.Where);"
        }
    }
    $sql = @"
PRAGMA foreign_keys = OFF;
PRAGMA busy_timeout = 5000;
BEGIN IMMEDIATE;
$($deletes -join "`n")
COMMIT;
PRAGMA foreign_keys = ON;
"@
    Invoke-Sqlite -Database $DestDb -Sql $sql | Out-Null
    return "SQLite index rows deleted."
}

function Restore-SessionFromLatestSnapshot {
    param($Session)
    $match = Find-LatestSnapshotRollout -SessionId $Session.Id
    if (-not $match) {
        [System.Windows.Forms.MessageBox]::Show("No snapshot contains this session.", "Restore", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $question = "Restore this session from snapshot:`r`n$($match.Snapshot.Name)`r`n`r`n$($Session.Title)"
    $answer = [System.Windows.Forms.MessageBox]::Show($question, "Restore session", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $restorePlan = New-SessionRestorePlan -SessionIds @($Session.Id) -SourceRoot $match.Snapshot.DataPath -DestinationRoot $script:CodexRoot
    $protectionPlan = New-SessionProtectionPlan -SessionIds @($Session.Id) -CodexRoot $script:CodexRoot
    New-SessionProtectionSnapshot -Name "Pre-Single-Session Restore Backup" -Reason "pre-single-session-restore" -Plan $protectionPlan | Out-Null
    Invoke-SessionRestorePlan -Plan $restorePlan

    $restoredRollout = @($restorePlan.Rollouts | Where-Object {
        $_.SessionId -ceq (Normalize-SessionIdentity $Session.Id)
    } | Select-Object -First 1)
    $restoredRolloutPath = if ($restoredRollout.Count -gt 0) { $restoredRollout[0].DestinationPath } else { "" }
    $sqliteMsg = Merge-SingleSessionStateDb `
        -SnapshotDb (Join-ChildPath $match.Snapshot.DataPath "state_5.sqlite") `
        -DestDb (Join-ChildPath $script:CodexRoot "state_5.sqlite") `
        -SessionId $Session.Id `
        -RolloutPath $restoredRolloutPath

    Refresh-App
    [System.Windows.Forms.MessageBox]::Show("Restore finished.`r`n$sqliteMsg", "Restore", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Delete-SelectedSession {
    param($Session)
    $answer = [System.Windows.Forms.MessageBox]::Show("Delete session after creating backup?`r`n`r`n$($Session.Title)", "Delete session", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $deletionPlan = New-SessionDeletionPlan -SessionIds @($Session.Id) -CodexRoot $script:CodexRoot
    $protectionPlan = New-SessionProtectionPlan -SessionIds @($Session.Id) -CodexRoot $script:CodexRoot
    New-SessionProtectionSnapshot -Name "Pre-Delete Session Backup" -Reason "pre-delete-session" -Plan $protectionPlan | Out-Null
    $warning = Invoke-SessionDeletionPlan -Plan $deletionPlan
    $sqliteMsg = Delete-SingleSessionStateDb -DestDb (Join-ChildPath $script:CodexRoot "state_5.sqlite") -SessionId $Session.Id
    Refresh-App
    $warningText = if ([string]::IsNullOrWhiteSpace($warning)) { "" } else { "`r`n$warning" }
    [System.Windows.Forms.MessageBox]::Show("Delete finished.`r`n$sqliteMsg$warningText", "Delete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Extract-ConversationText {
    param($Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Array]) {
        $parts = @()
        foreach ($item in $Value) {
            $t = Extract-ConversationText $item
            if (-not [string]::IsNullOrWhiteSpace($t)) { $parts += $t }
        }
        return ($parts -join "`r`n")
    }
    foreach ($key in @("text", "message", "content", "input", "output")) {
        try {
            if ($Value.PSObject.Properties.Name -contains $key) {
                $t = Extract-ConversationText $Value.$key
                if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
            }
        } catch {
        }
    }
    return ""
}

function Load-ConversationMessages {
    param([string]$RolloutPath)
    if (-not (Test-Path $RolloutPath)) { throw "Rollout file not found: $RolloutPath" }
    $events = New-Object "System.Collections.Generic.List[object]"
    $responses = New-Object "System.Collections.Generic.List[object]"
    $lineNo = 0

    Get-Content -Path $RolloutPath -ReadCount 500 -ErrorAction Stop | ForEach-Object {
        foreach ($line in $_) {
            $lineNo++
            if ($line -like '*"event_msg"*' -and ($line -like '*"user_message"*' -or $line -like '*"agent_message"*')) {
                $obj = Get-JsonLineObject $line
                if ($obj -and $obj.payload) {
                    $role = $null
                    if ($obj.payload.type -eq "user_message") { $role = "User" }
                    if ($obj.payload.type -eq "agent_message") { $role = "Assistant" }
                    if ($role) {
                        $text = [string]$obj.payload.message
                        if ([string]::IsNullOrWhiteSpace($text)) { $text = Extract-ConversationText $obj.payload.content }
                        if (-not [string]::IsNullOrWhiteSpace($text)) {
                            $events.Add([pscustomobject]@{
                                Role = $role
                                Time = Convert-IsoToDate ([string]$obj.timestamp)
                                Phase = [string]$obj.payload.phase
                                Text = $text.Trim()
                            }) | Out-Null
                        }
                    }
                }
                continue
            }

            if ($events.Count -eq 0 -and $line -like '*"response_item"*' -and $line -like '*"message"*') {
                $obj = Get-JsonLineObject $line
                if ($obj -and $obj.payload -and $obj.payload.type -eq "message" -and ($obj.payload.role -eq "user" -or $obj.payload.role -eq "assistant")) {
                    $text = Extract-ConversationText $obj.payload.content
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $responses.Add([pscustomobject]@{
                            Role = if ($obj.payload.role -eq "user") { "User" } else { "Assistant" }
                            Time = Convert-IsoToDate ([string]$obj.timestamp)
                            Phase = [string]$obj.payload.phase
                            Text = $text.Trim()
                        }) | Out-Null
                    }
                }
            }
        }
    }

    if ($events.Count -gt 0) { return @($events) }
    return @($responses)
}

function Show-Conversation {
    param($Session)
    if (-not $Session -or -not (Test-Path $Session.RolloutPath)) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Conversation - Codex Session Manager"
    $form.Size = New-Object System.Drawing.Size(1050, 720)
    $form.StartPosition = "CenterParent"

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = "Fill"
    $split.SplitterDistance = 420
    $form.Controls.Add($split)

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = "Fill"
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.GridLines = $true
    [void]$list.Columns.Add("Role", 80)
    [void]$list.Columns.Add("Time", 140)
    [void]$list.Columns.Add("Preview", 180)
    $split.Panel1.Controls.Add($list)

    $text = New-Object System.Windows.Forms.TextBox
    $text.Dock = "Fill"
    $text.Multiline = $true
    $text.ScrollBars = "Both"
    $text.ReadOnly = $true
    $text.Font = New-Object System.Drawing.Font("Consolas", 10)
    $split.Panel2.Controls.Add($text)

    $list.Add_SelectedIndexChanged({
        if ($list.SelectedItems.Count -eq 0) { return }
        $msg = $list.SelectedItems[0].Tag
        $value = [string]$msg.Text
        if ($value.Length -gt 120000) {
            $value = $value.Substring(0, 120000) + "`r`n`r`n... message clipped in viewer. Open the raw file for the full text."
        }
        $text.Text = $value
    })

    $form.Add_Shown({
        $text.Text = "Loading conversation..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $messages = @(Load-ConversationMessages -RolloutPath $Session.RolloutPath)
            $form.Text = "Conversation - $($messages.Count) messages"
            foreach ($msg in $messages) {
                $preview = ([string]$msg.Text) -replace "\s+", " "
                if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
                $item = New-Object System.Windows.Forms.ListViewItem($msg.Role)
                [void]$item.SubItems.Add($msg.Time.ToString("yyyy-MM-dd HH:mm:ss"))
                [void]$item.SubItems.Add($preview)
                $item.Tag = $msg
                [void]$list.Items.Add($item)
            }
            if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
            else { $text.Text = "No user or assistant messages found." }
        } catch {
            $text.Text = $_.Exception.Message
        }
    })

    [void]$form.ShowDialog($script:MainForm)
}

function Open-Path {
    param([string]$Path)
    if (Test-Path $Path) { Start-Process $Path }
}

function Reveal-Path {
    param([string]$Path)
    if (Test-Path $Path) { Start-Process "explorer.exe" "/select,`"$Path`"" }
}

function Get-SelectedSession {
    if ($script:SessionList.SelectedItems.Count -eq 0) { return $null }
    return $script:SessionList.SelectedItems[0].Tag
}

function Update-Details {
    $session = Get-SelectedSession
    if (-not $session) {
        $script:DetailTitle.Text = "No session selected"
        $script:DetailBody.Text = ""
        return
    }
    $script:DetailTitle.Text = $session.Title
    $script:DetailBody.Text = @"
ID: $($session.Id)
Provider/Model: $($session.Provider) / $($session.Model)
Source: $($session.Source)
State: $(if ($session.Archived) { "Archived" } else { "Active" })
Exists: $($session.ExistsOnDisk)
Updated: $($session.UpdatedAt)
CWD: $($session.Cwd)
Rollout: $($session.RolloutPath)
"@
}

function Populate-SessionList {
    $query = $script:SearchBox.Text.ToLowerInvariant()
    $script:SessionList.BeginUpdate()
    $script:SessionList.Items.Clear()
    foreach ($session in $script:Sessions) {
        $haystack = (($session.Id, $session.Title, $session.Cwd, $session.Provider, $session.Model, $session.Source, $session.RolloutPath) -join " ").ToLowerInvariant()
        if ($query -and -not $haystack.Contains($query)) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($session.Title)
        [void]$item.SubItems.Add("$($session.Provider) / $($session.Model)")
        [void]$item.SubItems.Add($session.UpdatedAt.ToString("yyyy-MM-dd HH:mm"))
        [void]$item.SubItems.Add($(if ($session.Archived) { "Archived" } else { "Active" }))
        [void]$item.SubItems.Add($(if ($session.ExistsOnDisk) { "OK" } else { "Missing" }))
        $item.Tag = $session
        [void]$script:SessionList.Items.Add($item)
    }
    $script:SessionList.EndUpdate()
    if ($script:SessionList.Items.Count -gt 0) { $script:SessionList.Items[0].Selected = $true }
    Update-Details
}

function Refresh-App {
    if (-not (Test-Path $script:CodexRoot)) {
        [System.Windows.Forms.MessageBox]::Show("Codex root not found: $script:CodexRoot", "Codex Session Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if (-not (Test-Path $script:SnapshotRoot)) { New-Item -ItemType Directory -Path $script:SnapshotRoot -Force | Out-Null }
    $script:Sessions = @(Load-Sessions)
    $script:Snapshots = @(Load-Snapshots)
    Populate-SessionList
    $sqliteStatus = if (Get-SqliteExe) { "sqlite3: OK" } else { "sqlite3: missing" }
    $script:StatusLabel.Text = "$($script:Sessions.Count) sessions, $($script:Snapshots.Count) snapshots, $sqliteStatus"
}

$script:MainForm = New-Object System.Windows.Forms.Form
$script:MainForm.Text = "Codex Session Manager Win10"
$script:MainForm.Size = New-Object System.Drawing.Size(1180, 760)
$script:MainForm.StartPosition = "CenterScreen"

$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 52
$script:MainForm.Controls.Add($top)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(12, 12)
$btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$top.Controls.Add($btnRefresh)

$btnSnapshot = New-Object System.Windows.Forms.Button
$btnSnapshot.Text = "Create Snapshot"
$btnSnapshot.Location = New-Object System.Drawing.Point(110, 12)
$btnSnapshot.Size = New-Object System.Drawing.Size(125, 28)
$top.Controls.Add($btnSnapshot)

$btnOpenCodex = New-Object System.Windows.Forms.Button
$btnOpenCodex.Text = "Open .codex"
$btnOpenCodex.Location = New-Object System.Drawing.Point(245, 12)
$btnOpenCodex.Size = New-Object System.Drawing.Size(110, 28)
$top.Controls.Add($btnOpenCodex)

$btnOpenVault = New-Object System.Windows.Forms.Button
$btnOpenVault.Text = "Open Vault"
$btnOpenVault.Location = New-Object System.Drawing.Point(365, 12)
$btnOpenVault.Size = New-Object System.Drawing.Size(105, 28)
$top.Controls.Add($btnOpenVault)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.AutoSize = $true
$script:StatusLabel.Location = New-Object System.Drawing.Point(490, 17)
$script:StatusLabel.Text = "Ready"
$top.Controls.Add($script:StatusLabel)

$main = New-Object System.Windows.Forms.SplitContainer
$main.Dock = "Fill"
$main.SplitterDistance = 620
$script:MainForm.Controls.Add($main)

$leftTop = New-Object System.Windows.Forms.Panel
$leftTop.Dock = "Top"
$leftTop.Height = 42
$main.Panel1.Controls.Add($leftTop)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "Search:"
$searchLabel.AutoSize = $true
$searchLabel.Location = New-Object System.Drawing.Point(8, 13)
$leftTop.Controls.Add($searchLabel)

$script:SearchBox = New-Object System.Windows.Forms.TextBox
$script:SearchBox.Location = New-Object System.Drawing.Point(66, 10)
$script:SearchBox.Size = New-Object System.Drawing.Size(532, 24)
$leftTop.Controls.Add($script:SearchBox)

$script:SessionList = New-Object System.Windows.Forms.ListView
$script:SessionList.Dock = "Fill"
$script:SessionList.View = "Details"
$script:SessionList.FullRowSelect = $true
$script:SessionList.GridLines = $true
[void]$script:SessionList.Columns.Add("Title", 260)
[void]$script:SessionList.Columns.Add("Provider / Model", 135)
[void]$script:SessionList.Columns.Add("Updated", 120)
[void]$script:SessionList.Columns.Add("State", 75)
[void]$script:SessionList.Columns.Add("File", 70)
$main.Panel1.Controls.Add($script:SessionList)
$script:SessionList.BringToFront()

$detailPanel = New-Object System.Windows.Forms.Panel
$detailPanel.Dock = "Fill"
$main.Panel2.Controls.Add($detailPanel)

$script:DetailTitle = New-Object System.Windows.Forms.Label
$script:DetailTitle.Location = New-Object System.Drawing.Point(14, 14)
$script:DetailTitle.Size = New-Object System.Drawing.Size(500, 60)
$script:DetailTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$script:DetailTitle.Text = "No session selected"
$detailPanel.Controls.Add($script:DetailTitle)

$btnView = New-Object System.Windows.Forms.Button
$btnView.Text = "View Conversation"
$btnView.Location = New-Object System.Drawing.Point(18, 86)
$btnView.Size = New-Object System.Drawing.Size(135, 32)
$detailPanel.Controls.Add($btnView)

$btnOpenFile = New-Object System.Windows.Forms.Button
$btnOpenFile.Text = "Open File"
$btnOpenFile.Location = New-Object System.Drawing.Point(165, 86)
$btnOpenFile.Size = New-Object System.Drawing.Size(95, 32)
$detailPanel.Controls.Add($btnOpenFile)

$btnReveal = New-Object System.Windows.Forms.Button
$btnReveal.Text = "Reveal"
$btnReveal.Location = New-Object System.Drawing.Point(272, 86)
$btnReveal.Size = New-Object System.Drawing.Size(85, 32)
$detailPanel.Controls.Add($btnReveal)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = "Restore Latest"
$btnRestore.Location = New-Object System.Drawing.Point(18, 128)
$btnRestore.Size = New-Object System.Drawing.Size(135, 32)
$detailPanel.Controls.Add($btnRestore)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete"
$btnDelete.Location = New-Object System.Drawing.Point(165, 128)
$btnDelete.Size = New-Object System.Drawing.Size(95, 32)
$detailPanel.Controls.Add($btnDelete)

$script:DetailBody = New-Object System.Windows.Forms.TextBox
$script:DetailBody.Location = New-Object System.Drawing.Point(18, 175)
$script:DetailBody.Size = New-Object System.Drawing.Size(500, 500)
$script:DetailBody.Multiline = $true
$script:DetailBody.ScrollBars = "Both"
$script:DetailBody.ReadOnly = $true
$script:DetailBody.Font = New-Object System.Drawing.Font("Consolas", 10)
$detailPanel.Controls.Add($script:DetailBody)

$context = New-Object System.Windows.Forms.ContextMenuStrip
$ctxView = $context.Items.Add("View Conversation")
$ctxRestore = $context.Items.Add("Restore from Latest Snapshot")
$ctxDelete = $context.Items.Add("Delete Session")

$script:SessionList.ContextMenuStrip = $context

$btnRefresh.Add_Click({ Refresh-App })
$btnSnapshot.Add_Click({
    try {
        New-CodexSnapshot -Name "Manual Snapshot" -Reason "manual" -Candidates (Get-BackupCandidates) | Out-Null
        Refresh-App
        [System.Windows.Forms.MessageBox]::Show("Snapshot created.", "Snapshot", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Snapshot failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
$btnOpenCodex.Add_Click({ Open-Path $script:CodexRoot })
$btnOpenVault.Add_Click({ Open-Path $script:VaultRoot })
$script:SearchBox.Add_TextChanged({ Populate-SessionList })
$script:SessionList.Add_SelectedIndexChanged({ Update-Details })
$script:SessionList.Add_DoubleClick({ $s = Get-SelectedSession; if ($s) { Show-Conversation $s } })
$script:SessionList.Add_MouseUp({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $item = $script:SessionList.GetItemAt($eventArgs.X, $eventArgs.Y)
        if ($item) { $item.Selected = $true }
    }
})
$btnView.Add_Click({ $s = Get-SelectedSession; if ($s) { Show-Conversation $s } })
$btnOpenFile.Add_Click({ $s = Get-SelectedSession; if ($s) { Open-Path $s.RolloutPath } })
$btnReveal.Add_Click({ $s = Get-SelectedSession; if ($s) { Reveal-Path $s.RolloutPath } })
$btnRestore.Add_Click({ $s = Get-SelectedSession; if ($s) { Restore-SessionFromLatestSnapshot $s } })
$btnDelete.Add_Click({ $s = Get-SelectedSession; if ($s) { Delete-SelectedSession $s } })
$ctxView.Add_Click({ $s = Get-SelectedSession; if ($s) { Show-Conversation $s } })
$ctxRestore.Add_Click({ $s = Get-SelectedSession; if ($s) { Restore-SessionFromLatestSnapshot $s } })
$ctxDelete.Add_Click({ $s = Get-SelectedSession; if ($s) { Delete-SelectedSession $s } })

$script:MainForm.Add_Shown({ Refresh-App })
[void][System.Windows.Forms.Application]::Run($script:MainForm)

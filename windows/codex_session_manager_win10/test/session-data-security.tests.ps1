$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "app\session-data-security.ps1")

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-ThrowsCode {
    param([scriptblock]$Action, [string]$Code)
    try {
        & $Action
        throw "Expected error code $Code"
    } catch {
        Assert-True ($_.Exception.Data["Code"] -eq $Code) "expected $Code, got $($_.Exception.Data["Code"]): $($_.Exception.Message)"
    }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-session-security-" + [Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $codexRoot = Join-Path $root ".codex"
    $sessions = Join-Path $codexRoot "sessions\2026\07\16"
    New-Item -ItemType Directory -Path $sessions -Force | Out-Null

    $target = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    $other = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    $history = Join-Path $codexRoot "history.jsonl"
    [System.IO.File]::WriteAllText($history, "{`"session_id`":`"$other`",`"text`":`"mentions $target`"}`n{`"session_id`":`"$target`",`"text`":`"exact`"}`n", (New-Object System.Text.UTF8Encoding($false, $true)))
    $document = Read-SessionJsonlFile -Path $history -Kind "history"
    $selected = @(Select-SessionJsonlRecords -Document $document -SessionIds @($target))
    Assert-True ($selected.Count -eq 1) "only the top-level exact identity may match"
    Assert-True ($selected[0].Object.text -eq "exact") "content mention must not match"

    $rollout = Join-Path $sessions "unrelated-name.jsonl"
    [System.IO.File]::WriteAllText($rollout, "{`"type`":`"session_meta`",`"payload`":{`"id`":`"$target`"}}`n{`"type`":`"event_msg`",`"payload`":{`"id`":`"$other`"}}`n", (New-Object System.Text.UTF8Encoding($false, $true)))
    $trusted = Resolve-TrustedSessionFiles -SessionIds @($target) -CodexRoot $codexRoot
    Assert-True ($trusted.Files.Count -eq 1) "rollout identity must come from session_meta, not filename"

    $brokenRollout = Join-Path $sessions "broken.jsonl"
    [System.IO.File]::WriteAllText($brokenRollout, "{`"type`":`"session_meta`",`"payload`":{`"id`":`"$target`"}}`n{bad}`n", (New-Object System.Text.UTF8Encoding($false, $true)))
    Assert-ThrowsCode { Resolve-TrustedSessionFiles -SessionIds @($target) -CodexRoot $codexRoot } "INVALID_SESSION_JSONL"
    Remove-Item -LiteralPath $brokenRollout -Force

    $outside = Join-Path $root "outside.jsonl"
    [System.IO.File]::WriteAllText($outside, "do not delete", (New-Object System.Text.UTF8Encoding($false, $true)))
    $plan = New-SessionDeletionPlan -SessionIds @($other) -CodexRoot $codexRoot
    Invoke-SessionDeletionPlan -Plan $plan | Out-Null
    Assert-True (Test-Path -LiteralPath $outside) "untrusted raw paths must never be touched"

    $invalid = Join-Path $codexRoot "session_index.jsonl"
    [System.IO.File]::WriteAllText($invalid, "{`"id`":`"$target`"}`n`n{bad}`n", (New-Object System.Text.UTF8Encoding($false, $true)))
    Assert-ThrowsCode { New-SessionDeletionPlan -SessionIds @($target) -CodexRoot $codexRoot } "INVALID_SESSION_JSONL"
    Assert-True (Test-Path -LiteralPath $rollout) "invalid JSONL preflight must have zero deletion side effects"

    Remove-Item -LiteralPath $invalid -Force
    $snapshotRoot = Join-Path $root "snapshot"
    $snapshotSessions = Join-Path $snapshotRoot "sessions"
    New-Item -ItemType Directory -Path $snapshotSessions -Force | Out-Null
    $snapshotRollout = Join-Path $snapshotSessions "concurrent.jsonl"
    [System.IO.File]::WriteAllText($snapshotRollout, "{`"type`":`"session_meta`",`"payload`":{`"id`":`"$target`"}}`n", (New-Object System.Text.UTF8Encoding($false, $true)))
    $restorePlan = New-SessionRestorePlan -SessionIds @($target) -SourceRoot $snapshotRoot -DestinationRoot $codexRoot
    $concurrentDestination = Join-Path $sessions "concurrent.jsonl"
    $concurrentText = "{`"type`":`"session_meta`",`"payload`":{`"id`":`"$target`"}}`n{`"type`":`"event_msg`",`"payload`":{`"message`":`"new Codex data`"}}`n"
    [System.IO.File]::WriteAllText($concurrentDestination, $concurrentText, (New-Object System.Text.UTF8Encoding($false, $true)))
    Assert-ThrowsCode { Invoke-SessionRestorePlan -Plan $restorePlan } "INVALID_SESSION_JSONL"
    Assert-True ([System.IO.File]::ReadAllText($concurrentDestination) -ceq $concurrentText) "concurrent rollout must not be overwritten"

    Write-Host "PowerShell session data security regression tests passed."
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
